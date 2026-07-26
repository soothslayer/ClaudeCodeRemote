"""Optional OpenAI Realtime speech bridge.

The long-lived OpenAI API key never leaves the bot process.  The iOS client
continues to connect only to this bot and sends/receives PCM16 audio through
the existing application WebSocket.

Realtime is deliberately used as the speech layer, not as a replacement for
Claude Code:

* server VAD + input transcription turn phone audio into user text
* that text is submitted to the existing persistent ClaudeSession
* streamed Claude sentences are rendered as streaming Realtime audio

No network connection is made unless OPENAI_API_KEY is configured and the
phone explicitly opts in.
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
from collections import deque
from collections.abc import Awaitable, Callable
from typing import Any

from websockets.asyncio.client import connect

logger = logging.getLogger(__name__)

DEFAULT_MODEL = "gpt-realtime-2.1"
DEFAULT_TRANSCRIPTION_MODEL = "gpt-4o-mini-transcribe"
DEFAULT_VOICE = "marin"
SAMPLE_RATE = 24_000

TranscriptHandler = Callable[[str], Awaitable[None]]
EventHandler = Callable[[dict[str, Any]], Awaitable[None]]


def is_configured() -> bool:
    """Return whether the server has a non-empty API key.

    Never return or log the key itself.
    """

    return bool(os.environ.get("OPENAI_API_KEY", "").strip())


class OpenAIRealtimeBridge:
    """One phone client's server-to-server Realtime session."""

    def __init__(
        self,
        *,
        on_transcript: TranscriptHandler,
        on_event: EventHandler,
        api_key: str | None = None,
        model: str | None = None,
        voice: str | None = None,
    ) -> None:
        self._api_key = (api_key or os.environ.get("OPENAI_API_KEY", "")).strip()
        self.model = (model or os.environ.get("OPENAI_REALTIME_MODEL") or DEFAULT_MODEL).strip()
        self.voice = (voice or os.environ.get("OPENAI_REALTIME_VOICE") or DEFAULT_VOICE).strip()
        self.on_transcript = on_transcript
        self.on_event = on_event
        self._ws: Any | None = None
        self._receive_task: asyncio.Task[None] | None = None
        self._send_lock = asyncio.Lock()
        self._response_active = False
        self._text_accumulator = ""
        self._pending_speech: deque[str] = deque()

    @property
    def is_connected(self) -> bool:
        return self._ws is not None

    @property
    def url(self) -> str:
        return f"wss://api.openai.com/v1/realtime?model={self.model}"

    def session_update_event(self) -> dict[str, Any]:
        """Build the GA Realtime session configuration."""

        return {
            "type": "session.update",
            "session": {
                "type": "realtime",
                "output_modalities": ["audio"],
                "instructions": (
                    "You are the speech interface for Claude Code Remote. "
                    "Never answer the user or perform coding work yourself. "
                    "Only speak text supplied in response instructions, preserving "
                    "its meaning and wording while making punctuation sound natural."
                ),
                "audio": {
                    "input": {
                        "format": {"type": "audio/pcm", "rate": SAMPLE_RATE},
                        "transcription": {"model": DEFAULT_TRANSCRIPTION_MODEL},
                        "turn_detection": {
                            "type": "semantic_vad",
                            "create_response": False,
                            "interrupt_response": False,
                        },
                    },
                    "output": {
                        "format": {"type": "audio/pcm", "rate": SAMPLE_RATE},
                        "voice": self.voice,
                    },
                },
            },
        }

    @staticmethod
    def speech_response_event(text: str) -> dict[str, Any]:
        """Build a response that voices Claude's completed answer."""

        return {
            "type": "response.create",
            "response": {
                "output_modalities": ["audio"],
                "instructions": (
                    "Speak the following Claude Code response. Do not answer it, "
                    "comment on it, summarize it, or add an introduction. "
                    "Read it faithfully and naturally:\n\n" + text
                ),
            },
        }

    async def open(self) -> None:
        if not self._api_key:
            raise RuntimeError("OPENAI_API_KEY is not configured")
        if self._ws is not None:
            return

        # Standard credentials are safe here because this connection originates
        # on the trusted bot server, never from the iOS app.
        self._ws = await connect(
            self.url,
            additional_headers={"Authorization": f"Bearer {self._api_key}"},
            open_timeout=15,
            close_timeout=5,
            max_size=16 * 1024 * 1024,
        )
        await self._send(self.session_update_event())
        self._receive_task = asyncio.create_task(
            self._receive_loop(), name="openai-realtime-receive"
        )
        logger.info("OpenAI Realtime connected (model=%s voice=%s)", self.model, self.voice)

    async def close(self) -> None:
        receive_task = self._receive_task
        self._receive_task = None
        if receive_task is not None:
            receive_task.cancel()
        ws = self._ws
        self._ws = None
        if ws is not None:
            await ws.close()
        if receive_task is not None:
            await asyncio.gather(receive_task, return_exceptions=True)
        self._response_active = False
        self._text_accumulator = ""
        self._pending_speech.clear()

    async def append_audio(self, pcm: bytes) -> None:
        if not pcm or self._ws is None:
            return
        await self._send({
            "type": "input_audio_buffer.append",
            "audio": base64.b64encode(pcm).decode("ascii"),
        })

    async def speak_text(self, text: str) -> None:
        """Queue a complete text block for speech."""

        text = text.strip()
        if not text or self._ws is None:
            return
        self._pending_speech.append(text)
        await self._start_next_speech()

    async def add_text_delta(self, delta: str) -> None:
        """Queue complete sentences from Claude's streaming text."""

        if not delta or self._ws is None:
            return
        self._text_accumulator += delta
        self._drain_text_accumulator(force=False)
        await self._start_next_speech()

    async def finish_text(self) -> None:
        """Flush the final partial sentence when Claude finishes its turn."""

        self._drain_text_accumulator(force=True)
        await self._start_next_speech()

    async def _start_next_speech(self) -> None:
        if self._response_active or not self._pending_speech or self._ws is None:
            return
        text = self._pending_speech.popleft()
        self._response_active = True
        await self._send(self.speech_response_event(text))

    async def cancel_response(self, *, clear_queue: bool = True) -> None:
        if self._ws is None:
            return
        if self._response_active:
            await self._send({"type": "response.cancel"})
        self._response_active = False
        if clear_queue:
            self._pending_speech.clear()
            self._text_accumulator = ""
        await self.on_event({"type": "tts_flush"})

    def _drain_text_accumulator(self, *, force: bool) -> None:
        while True:
            boundaries = [
                index + len(separator)
                for separator in (". ", "! ", "? ", "\n")
                if (index := self._text_accumulator.find(separator)) >= 0
            ]
            if not boundaries:
                break
            boundary = min(boundaries)
            sentence = self._text_accumulator[:boundary].strip()
            self._text_accumulator = self._text_accumulator[boundary:]
            if sentence:
                self._pending_speech.append(sentence)

        # Avoid waiting indefinitely on long unpunctuated output.
        if len(self._text_accumulator) > 250:
            self._pending_speech.append(self._text_accumulator.strip())
            self._text_accumulator = ""
        elif force:
            remainder = self._text_accumulator.strip()
            self._text_accumulator = ""
            if remainder:
                self._pending_speech.append(remainder)

    async def _send(self, event: dict[str, Any]) -> None:
        ws = self._ws
        if ws is None:
            return
        async with self._send_lock:
            await ws.send(json.dumps(event))

    async def _receive_loop(self) -> None:
        ws = self._ws
        if ws is None:
            return
        try:
            async for raw in ws:
                event = json.loads(raw)
                await self.handle_server_event(event)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.warning("OpenAI Realtime connection ended: %s", exc)
            await self.on_event({
                "type": "error",
                "message": "OpenAI Realtime voice disconnected; reconnect the call to retry.",
            })
        finally:
            self._response_active = False

    async def handle_server_event(self, event: dict[str, Any]) -> None:
        """Normalize relevant OpenAI server events for the app server."""

        event_type = event.get("type")
        if event_type == "conversation.item.input_audio_transcription.completed":
            transcript = (event.get("transcript") or "").strip()
            if transcript:
                await self.on_transcript(transcript)
        elif event_type == "input_audio_buffer.speech_started":
            # Flush phone playback immediately. Because automatic interruption
            # is disabled, explicitly cancel any speech response we created.
            await self.cancel_response()
        elif event_type == "response.output_audio.delta":
            encoded = event.get("delta") or ""
            try:
                pcm = base64.b64decode(encoded, validate=True)
            except (ValueError, TypeError):
                logger.warning("Dropped malformed OpenAI audio delta")
                return
            if pcm:
                await self.on_event({
                    "type": "audio_frame",
                    "seq": 0,
                    "frame": 0,
                    "sample_rate": SAMPLE_RATE,
                    "pcm": base64.b64encode(pcm).decode("ascii"),
                    "final": False,
                })
        elif event_type == "response.done":
            self._response_active = False
            await self._start_next_speech()
        elif event_type == "error":
            error = event.get("error") or {}
            message = error.get("message") or "OpenAI Realtime error"
            logger.warning("OpenAI Realtime error: %s", message)
            await self.on_event({"type": "error", "message": message})
