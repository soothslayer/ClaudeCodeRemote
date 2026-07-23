"""
tts_pipeline.py — sentence chunker + server-side TTS dispatcher.

Mirrors the iOS-side chunker (VoiceManager.drainAccumulator): newlines flush
a chunk, sentence terminators split within a line, runs > 250 chars flush
unconditionally, triple-backtick fences are announced as "Code block omitted".

Each finished sentence is dispatched sequentially:
  • Kokoro succeeds → a stream of `audio_frame` events (base64 PCM chunks)
  • Kokoro fails    → one `speak_text` event so iOS falls back to on-device TTS

The pipeline lives on the FastAPI event loop. add_delta / finish_turn /
cancel are safe to call from the Claude reader thread via
loop.call_soon_threadsafe(...) — they never block.
"""

import asyncio
import base64
import logging
import re
from collections.abc import Callable

from tts_kokoro import KokoroTTS

logger = logging.getLogger(__name__)


_LINK_RE = re.compile(r"\[([^\]]+)\]\([^\)]+\)")
_LEADING_MARKUP = set("#->*•")


def sanitize_for_speech(text: str) -> str:
    """Strip markdown decoration that reads badly aloud."""
    text = _LINK_RE.sub(r"\1", text)
    text = text.replace("`", "").replace("**", "").replace("##", "")
    stripped = text.strip()
    while stripped and stripped[0] in _LEADING_MARKUP:
        stripped = stripped[1:].lstrip()
    return stripped


class SentencePipeline:
    def __init__(
        self,
        emit: Callable[[dict], None],
        kokoro: KokoroTTS,
    ):
        self._emit = emit
        self._kokoro = kokoro
        self._buffer = ""
        self._in_code_block = False
        self._code_block_announced = False
        self._seq = 0
        self._generation = 0
        self._queue: asyncio.Queue[tuple[int, int, str] | None] = asyncio.Queue()
        self._worker: asyncio.Task | None = None
        self._current: asyncio.Task | None = None

    # ── Public (called from event loop; safe from other threads via
    #    loop.call_soon_threadsafe) ─────────────────────────────────────────

    def start(self) -> None:
        if self._worker is None or self._worker.done():
            self._worker = asyncio.create_task(self._run(), name="tts-pipeline")

    def add_delta(self, delta: str) -> None:
        if not delta:
            return
        self._buffer += delta
        self._drain(force=False)

    def finish_turn(self) -> None:
        self._drain(force=True)

    def cancel(self) -> None:
        """Interrupt: drop pending sentences and abort the in-flight synth."""
        self._generation += 1
        self._buffer = ""
        self._in_code_block = False
        self._code_block_announced = False
        while True:
            try:
                self._queue.get_nowait()
            except asyncio.QueueEmpty:
                break
        if self._current is not None and not self._current.done():
            self._current.cancel()
        self._emit({"type": "tts_flush"})

    async def close(self) -> None:
        self.cancel()
        if self._worker is not None:
            await self._queue.put(None)
            try:
                await asyncio.wait_for(self._worker, timeout=2.0)
            except asyncio.TimeoutError:
                self._worker.cancel()
        await self._kokoro.close()

    # ── Chunker ───────────────────────────────────────────────────────────

    def _drain(self, force: bool) -> None:
        # Newline-terminated lines first (code-fence detection lives here).
        while "\n" in self._buffer:
            line, self._buffer = self._buffer.split("\n", 1)
            self._accept_line(line)

        if not self._in_code_block:
            # Sentence terminators inside a partial line.
            while True:
                hit_idx = -1
                hit_len = 0
                for sep in (". ", "! ", "? "):
                    idx = self._buffer.find(sep)
                    if idx != -1 and (hit_idx == -1 or idx < hit_idx):
                        hit_idx, hit_len = idx, len(sep)
                if hit_idx == -1:
                    break
                end = hit_idx + hit_len
                sentence, self._buffer = self._buffer[:end], self._buffer[end:]
                self._enqueue(sentence)

            # Long unpunctuated clause — flush so we don't stall forever.
            if len(self._buffer) > 250:
                self._enqueue(self._buffer)
                self._buffer = ""

        if force:
            if self._buffer.strip() and not self._in_code_block:
                self._enqueue(self._buffer)
            self._buffer = ""
            self._in_code_block = False
            self._code_block_announced = False

    def _accept_line(self, line: str) -> None:
        trimmed = line.strip()
        if trimmed.startswith("```"):
            self._in_code_block = not self._in_code_block
            if self._in_code_block and not self._code_block_announced:
                self._enqueue("Code block omitted.")
                self._code_block_announced = True
            if not self._in_code_block:
                self._code_block_announced = False
            return
        if self._in_code_block:
            return
        if line.strip():
            self._enqueue(line)

    def _enqueue(self, raw: str) -> None:
        sentence = sanitize_for_speech(raw)
        if not sentence:
            return
        self._seq += 1
        try:
            self._queue.put_nowait((self._generation, self._seq, sentence))
        except asyncio.QueueFull:
            logger.warning("TTS queue full — dropping sentence")

    # ── Worker ────────────────────────────────────────────────────────────

    async def _run(self) -> None:
        while True:
            item = await self._queue.get()
            if item is None:
                return
            gen, seq, sentence = item
            if gen != self._generation:
                continue          # cancelled after enqueue
            self._current = asyncio.create_task(self._speak(sentence, seq, gen))
            try:
                await self._current
            except asyncio.CancelledError:
                pass
            except Exception:
                logger.exception("TTS speak failed")
            finally:
                self._current = None

    async def _speak(self, sentence: str, seq: int, gen: int) -> None:
        try:
            frame_index = 0
            async for chunk in self._kokoro.synthesize(sentence):
                if gen != self._generation:
                    return
                self._emit({
                    "type": "audio_frame",
                    "seq": seq,
                    "frame": frame_index,
                    "sample_rate": self._kokoro.sample_rate,
                    "pcm": base64.b64encode(chunk).decode("ascii"),
                    "final": False,
                })
                frame_index += 1
            if gen == self._generation:
                self._emit({
                    "type": "audio_frame",
                    "seq": seq,
                    "frame": frame_index,
                    "sample_rate": self._kokoro.sample_rate,
                    "pcm": "",
                    "final": True,
                    "text": sentence,
                })
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.warning("Kokoro synth failed for %r: %s — falling back to client TTS",
                           sentence[:60], exc)
            if gen == self._generation:
                self._emit({"type": "speak_text", "seq": seq, "text": sentence})
