"""
tts_kokoro.py — Kokoro-FastAPI client for server-side neural TTS.

Kokoro-FastAPI (https://github.com/remsky/Kokoro-FastAPI) exposes an
OpenAI-compatible /v1/audio/speech endpoint. We ask for `response_format=pcm`
so we get raw 24 kHz mono s16le PCM back — small enough to stream over the
WebSocket and trivial for iOS to schedule on the player node.

Env vars:
    KOKORO_URL     base URL       (default http://localhost:8880/v1)
    KOKORO_VOICE   voice id       (default af_heart)
    KOKORO_SPEED   playback speed (default 1.0)
"""

import logging
import os
from collections.abc import AsyncIterator

import httpx

logger = logging.getLogger(__name__)

DEFAULT_URL = "http://localhost:8880/v1"
DEFAULT_VOICE = "af_heart"
DEFAULT_MODEL = "kokoro"
DEFAULT_SPEED = 1.0

# Kokoro-FastAPI always returns 24 kHz mono PCM.
KOKORO_SAMPLE_RATE = 24_000

# ~340 ms of audio per WS frame — small enough to feel responsive, large
# enough that per-frame framing overhead is negligible.
CHUNK_BYTES = 16_384


class KokoroTTS:
    def __init__(
        self,
        base_url: str | None = None,
        voice: str | None = None,
        speed: float | None = None,
    ):
        self.base_url = (base_url or os.environ.get("KOKORO_URL") or DEFAULT_URL).rstrip("/")
        self.voice = voice or os.environ.get("KOKORO_VOICE") or DEFAULT_VOICE
        speed_env = os.environ.get("KOKORO_SPEED")
        self.speed = float(speed if speed is not None else (speed_env or DEFAULT_SPEED))
        self._client = httpx.AsyncClient(
            timeout=httpx.Timeout(120.0, connect=5.0),
            headers={"Accept": "audio/pcm"},
        )

    @property
    def sample_rate(self) -> int:
        return KOKORO_SAMPLE_RATE

    async def check_available(self) -> bool:
        """One-shot health probe."""
        try:
            r = await self._client.get(f"{self.base_url}/models", timeout=2.0)
        except Exception as exc:
            logger.info("Kokoro-FastAPI not reachable at %s: %s", self.base_url, exc)
            return False
        ok = r.status_code < 500
        if ok:
            logger.info("Kokoro-FastAPI ready at %s (voice=%s speed=%.2f)",
                        self.base_url, self.voice, self.speed)
        else:
            logger.warning("Kokoro-FastAPI health probe returned %s", r.status_code)
        return ok

    async def synthesize(self, text: str) -> AsyncIterator[bytes]:
        """Yield raw PCM16-mono-24kHz chunks for `text`. Raises on failure."""
        payload = {
            "model": DEFAULT_MODEL,
            "input": text,
            "voice": self.voice,
            "response_format": "pcm",
            "speed": self.speed,
            "stream": True,
        }
        async with self._client.stream(
            "POST",
            f"{self.base_url}/audio/speech",
            json=payload,
        ) as response:
            if response.status_code >= 400:
                body = await response.aread()
                raise RuntimeError(f"Kokoro {response.status_code}: {body[:200]!r}")

            buffer = bytearray()
            async for raw in response.aiter_bytes():
                if not raw:
                    continue
                buffer.extend(raw)
                while len(buffer) >= CHUNK_BYTES:
                    yield bytes(buffer[:CHUNK_BYTES])
                    del buffer[:CHUNK_BYTES]
            if buffer:
                yield bytes(buffer)

    async def close(self) -> None:
        await self._client.aclose()
