import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock

os.environ.setdefault("OPENAI_API_KEY", "test-key")
os.environ.setdefault("TELEGRAM_TOKEN", "123456:test-token")
os.environ.setdefault("TELEGRAM_ALLOWED_USERS", "1")
os.environ.setdefault("INTERNAL_API_TOKEN", "test-internal-token")

from models import MODELS  # noqa: E402
from telegram_bot import _make_keyboard, _safe_filename  # noqa: E402
from transcriber import CHUNK_DURATION, MAX_API_SIZE, Transcriber  # noqa: E402


class ModelCatalogTests(unittest.TestCase):
    def test_supported_models(self):
        self.assertEqual(
            MODELS,
            {
                "g": "gpt-transcribe",
                "d": "gpt-4o-transcribe-diarize",
                "w": "whisper-1",
            },
        )

    def test_telegram_keyboard_offers_all_models_in_recommended_order(self):
        keyboard = _make_keyboard("deadbeef")
        callbacks = [row[0].callback_data for row in keyboard.inline_keyboard]
        self.assertEqual(
            callbacks,
            ["g:deadbeef", "d:deadbeef", "w:deadbeef", "x:deadbeef"],
        )

    def test_telegram_filename_is_reduced_to_a_safe_basename(self):
        self.assertEqual(_safe_filename("../../meeting\n.ogg"), "meeting_.ogg")
        self.assertEqual(_safe_filename("..\\..\\voice.m4a"), "voice.m4a")


class TranscriberTests(unittest.IsolatedAsyncioTestCase):
    async def test_response_format_matches_model(self):
        transcriber = Transcriber()
        create = AsyncMock(return_value=SimpleNamespace(text="ok", segments=None))
        transcriber.client = SimpleNamespace(
            audio=SimpleNamespace(
                transcriptions=SimpleNamespace(create=create),
            )
        )

        await transcriber._call_standard("gpt-transcribe", "audio.ogg", b"data")
        self.assertEqual(create.await_args.kwargs["response_format"], "json")
        self.assertEqual(create.await_args.kwargs["chunking_strategy"], "auto")

        await transcriber._call_standard("gpt-transcribe", "audio.ogg", b"data", "previous context")
        self.assertEqual(create.await_args.kwargs["prompt"], "previous context")

        await transcriber._call_standard("whisper-1", "audio.ogg", b"data")
        self.assertEqual(create.await_args.kwargs["response_format"], "verbose_json")
        self.assertNotIn("chunking_strategy", create.await_args.kwargs)

    async def test_small_long_audio_is_split_by_duration(self):
        transcriber = Transcriber()
        transcriber._get_duration = AsyncMock(return_value=CHUNK_DURATION + 1)
        transcriber._split_audio = AsyncMock(
            return_value=[Path("chunk-1.ogg"), Path("chunk-2.ogg")]
        )
        transcriber._transcribe_file = AsyncMock(side_effect=["first", "second"])

        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "long-but-small.ogg"
            source.write_bytes(b"audio")
            result = await transcriber._process(source, "gpt-transcribe", "task")

        self.assertEqual(result, "first\nsecond")
        transcriber._split_audio.assert_awaited_once()

    async def test_oversized_short_audio_is_optimized_once_and_cleaned_up(self):
        transcriber = Transcriber()
        transcriber._get_duration = AsyncMock(return_value=10)
        transcriber._transcribe_file = AsyncMock(return_value="result")
        optimized_paths = []

        async def fake_encode(_source, output, _offset=0, _duration=None):
            optimized_paths.append(output)
            output.write_bytes(b"optimized")

        transcriber._encode_audio = fake_encode

        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "large.wav"
            with source.open("wb") as audio:
                audio.truncate(MAX_API_SIZE + 1)

            result = await transcriber._process(source, "gpt-transcribe", "task")

        self.assertEqual(result, "result")
        self.assertEqual(len(optimized_paths), 1)
        self.assertFalse(optimized_paths[0].parent.exists())


if __name__ == "__main__":
    unittest.main()
