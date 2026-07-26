import base64
import json
import os
import unittest
from unittest.mock import patch

from bot.openai_realtime import (
    OpenAIRealtimeBridge,
    SAMPLE_RATE,
    is_configured,
)


class FakeWebSocket:
    def __init__(self):
        self.sent = []

    async def send(self, raw):
        self.sent.append(json.loads(raw))


class OpenAIRealtimeConfigTests(unittest.TestCase):
    def test_key_is_optional_and_never_returned(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertFalse(is_configured())
        with patch.dict(os.environ, {"OPENAI_API_KEY": "test-placeholder"}, clear=True):
            self.assertTrue(is_configured())

    def test_session_uses_pcm_and_manual_responses(self):
        bridge = OpenAIRealtimeBridge(
            api_key="test-placeholder",
            on_transcript=_ignore_transcript,
            on_event=_ignore_event,
        )
        session = bridge.session_update_event()["session"]
        self.assertEqual(session["type"], "realtime")
        self.assertEqual(session["audio"]["input"]["format"]["rate"], SAMPLE_RATE)
        self.assertFalse(
            session["audio"]["input"]["turn_detection"]["create_response"]
        )
        self.assertFalse(
            session["audio"]["input"]["turn_detection"]["interrupt_response"]
        )
        self.assertNotIn("test-placeholder", json.dumps(session))

    def test_speech_response_keeps_claude_text_in_instructions(self):
        event = OpenAIRealtimeBridge.speech_response_event("Build finished.")
        self.assertEqual(event["type"], "response.create")
        self.assertIn("Build finished.", event["response"]["instructions"])


class OpenAIRealtimeEventTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.transcripts = []
        self.events = []

        async def transcript(value):
            self.transcripts.append(value)

        async def event(value):
            self.events.append(value)

        self.bridge = OpenAIRealtimeBridge(
            api_key="test-placeholder",
            on_transcript=transcript,
            on_event=event,
        )

    async def test_completed_transcript_is_forwarded_to_claude_handler(self):
        await self.bridge.handle_server_event({
            "type": "conversation.item.input_audio_transcription.completed",
            "transcript": "  fix the tests  ",
        })
        self.assertEqual(self.transcripts, ["fix the tests"])

    async def test_audio_delta_is_normalized_for_phone(self):
        pcm = b"\x01\x02\x03\x04"
        await self.bridge.handle_server_event({
            "type": "response.output_audio.delta",
            "delta": base64.b64encode(pcm).decode("ascii"),
        })
        self.assertEqual(len(self.events), 1)
        self.assertEqual(self.events[0]["type"], "audio_frame")
        self.assertEqual(
            base64.b64decode(self.events[0]["pcm"]),
            pcm,
        )

    async def test_speech_start_cancels_response_and_flushes_phone(self):
        socket = FakeWebSocket()
        self.bridge._ws = socket
        self.bridge._response_active = True
        await self.bridge.handle_server_event({
            "type": "input_audio_buffer.speech_started",
        })
        self.assertEqual(socket.sent, [{"type": "response.cancel"}])
        self.assertEqual(self.events, [{"type": "tts_flush"}])

    async def test_streamed_claude_sentences_are_spoken_in_order(self):
        socket = FakeWebSocket()
        self.bridge._ws = socket
        await self.bridge.add_text_delta("First sentence. Second")
        await self.bridge.add_text_delta(" sentence. ")

        self.assertEqual(len(socket.sent), 1)
        self.assertIn("First sentence.", socket.sent[0]["response"]["instructions"])

        await self.bridge.handle_server_event({"type": "response.done"})
        self.assertEqual(len(socket.sent), 2)
        self.assertIn("Second sentence.", socket.sent[1]["response"]["instructions"])


async def _ignore_transcript(_: str) -> None:
    pass


async def _ignore_event(_: dict) -> None:
    pass


if __name__ == "__main__":
    unittest.main()
