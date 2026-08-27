import asyncio
import logging
import shutil
import tempfile
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from pathlib import Path

from openai import APIError, AsyncOpenAI, RateLimitError

from config import config

log = logging.getLogger(__name__)

MAX_API_SIZE = 24_000_000  # 24 MB, leaving margin below the 25 MB API limit
CHUNK_DURATION = 1800  # 30 minutes, matching the macOS client reliability limit

ERROR_MESSAGES = {
    "insufficient_quota": (
        "Нет баланса на OpenAI. Пополните на platform.openai.com/settings/organization/billing"
    ),
    "rate_limit_exceeded": "OpenAI перегружен, попробуйте через минуту",
    "invalid_api_key": "Неверный ключ OpenAI API",
    "model_not_found": "Модель не найдена. Проверьте доступ к API",
}


def _friendly_error(e: Exception) -> str:
    msg = str(e)
    for key, friendly in ERROR_MESSAGES.items():
        if key in msg:
            return friendly
    return f"Ошибка OpenAI: {msg[:300]}"


class TaskCancelled(Exception):
    pass


@dataclass
class Task:
    filepath: Path
    original_name: str
    model: str
    task_id: str
    callback: Callable[[str | None, str | None], Awaitable[None]]


class Transcriber:
    def __init__(self):
        self.client = AsyncOpenAI(
            api_key=config.openai_api_key,
            max_retries=2,
            timeout=300,
        )
        self.queue: asyncio.Queue[Task] = asyncio.Queue()
        self._cancelled: set[str] = set()

    def cancel(self, task_id: str):
        self._cancelled.add(task_id)
        log.info("Cancel requested: %s", task_id)

    def _check_cancelled(self, task_id: str):
        if task_id in self._cancelled:
            raise TaskCancelled()

    async def enqueue(self, filepath: Path, original_name: str, model: str, task_id: str, callback):
        log.info(
            "Enqueued: %s (model=%s, task_id=%s, queue_size=%d)",
            original_name,
            model,
            task_id,
            self.queue.qsize(),
        )
        await self.queue.put(Task(filepath, original_name, model, task_id, callback))

    async def enqueue_http(
        self,
        filepath: Path,
        original_name: str,
        model: str,
        task_id: str,
        callback_url: str,
        internal_api_token: str,
    ):
        """Enqueue with HTTP callback — posts result to callback_url."""
        import aiohttp

        async def cb(text, error=None):
            try:
                async with aiohttp.ClientSession() as session:
                    async with session.post(
                        callback_url,
                        headers={"Authorization": f"Bearer {internal_api_token}"},
                        json={
                            "task_id": task_id,
                            "text": text,
                            "error": error,
                        },
                    ) as response:
                        response.raise_for_status()
            except Exception:
                log.exception("HTTP callback failed for %s", task_id)

        await self.enqueue(filepath, original_name, model, task_id, cb)

    async def worker(self):
        while True:
            task = await self.queue.get()
            if task.task_id in self._cancelled:
                self._cancelled.discard(task.task_id)
                log.info("Skipped cancelled task: %s", task.original_name)
                task.filepath.unlink(missing_ok=True)
                self.queue.task_done()
                continue
            t0 = time.monotonic()
            log.info("Processing: %s (model=%s)", task.original_name, task.model)
            try:
                text = await self._process(task.filepath, task.model, task.task_id)
                elapsed = time.monotonic() - t0
                log.info("Done: %s (%.1fs, %d chars)", task.original_name, elapsed, len(text))
                await task.callback(text, None)
            except TaskCancelled:
                elapsed = time.monotonic() - t0
                log.info("Cancelled: %s (%.1fs)", task.original_name, elapsed)
            except RateLimitError as e:
                elapsed = time.monotonic() - t0
                log.warning("Rate limited: %s (%.1fs)", task.original_name, elapsed)
                await task.callback(None, _friendly_error(e))
            except APIError as e:
                elapsed = time.monotonic() - t0
                log.warning("API error for %s (%.1fs): %s", task.original_name, elapsed, e)
                await task.callback(None, _friendly_error(e))
            except Exception as e:
                elapsed = time.monotonic() - t0
                log.exception("Failed: %s (%.1fs)", task.original_name, elapsed)
                await task.callback(None, _friendly_error(e))
            finally:
                self._cancelled.discard(task.task_id)
                task.filepath.unlink(missing_ok=True)
                self.queue.task_done()

    async def _process(self, filepath: Path, model: str, task_id: str) -> str:
        file_size = filepath.stat().st_size
        duration = await self._get_duration(filepath)
        log.info("File: %.1f MB, duration=%s sec", file_size / 1e6, duration)

        if file_size <= MAX_API_SIZE and (duration is None or duration <= CHUNK_DURATION):
            self._check_cancelled(task_id)
            return await self._transcribe_file(filepath, model)

        tmpdir = Path(tempfile.mkdtemp(prefix="transcribator-"))
        try:
            if duration is None or duration <= CHUNK_DURATION:
                optimized = tmpdir / "optimized.ogg"
                await self._encode_audio(filepath, optimized)
                optimized_duration = duration or await self._get_duration(optimized)
                if optimized.stat().st_size <= MAX_API_SIZE and (
                    optimized_duration is None or optimized_duration <= CHUNK_DURATION
                ):
                    log.info(
                        "Optimized to %.1f MB; sending as one file", optimized.stat().st_size / 1e6
                    )
                    self._check_cancelled(task_id)
                    return await self._transcribe_file(optimized, model)
                if duration is None:
                    duration = optimized_duration
                log.info("Optimized file still exceeds an API safety limit; splitting")

            if duration is None:
                raise RuntimeError("Cannot determine audio duration for splitting")

            log.info("Splitting into chunks up to %d min...", CHUNK_DURATION // 60)
            chunks = await self._split_audio(filepath, tmpdir, duration)
            log.info("Got %d chunks", len(chunks))
            parts = []
            for i, chunk in enumerate(chunks, 1):
                self._check_cancelled(task_id)
                log.info("Transcribing chunk %d/%d...", i, len(chunks))
                prompt = parts[-1][-1000:] if parts and model == "gpt-transcribe" else None
                text = await self._transcribe_file(chunk, model, prompt)
                if text.strip():
                    parts.append(text)
            return "\n".join(parts)
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    async def _get_duration(self, filepath: Path) -> float | None:
        proc = await asyncio.create_subprocess_exec(
            "ffprobe",
            "-v",
            "quiet",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(filepath),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, _ = await proc.communicate()
        try:
            return float(stdout.strip())
        except (ValueError, TypeError):
            return None

    async def _encode_audio(
        self, filepath: Path, output: Path, offset: float = 0, duration: float | None = None
    ):
        args = ["ffmpeg", "-y", "-ss", str(offset), "-i", str(filepath)]
        if duration is not None:
            args.extend(["-t", str(duration)])
        args.extend(["-c:a", "libopus", "-b:a", "64k", "-vn", str(output)])
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await proc.communicate()
        if proc.returncode != 0:
            raise RuntimeError(f"ffmpeg conversion failed: {stderr.decode()[-500:]}")
        if not output.exists() or output.stat().st_size == 0:
            raise RuntimeError("ffmpeg produced an empty audio file")

    async def _split_audio(self, filepath: Path, tmpdir: Path, duration: float) -> list[Path]:
        chunks = []
        offset = 0
        idx = 0
        while offset < duration:
            out = tmpdir / f"chunk_{idx:03d}.ogg"
            await self._encode_audio(filepath, out, offset, CHUNK_DURATION)
            if out.stat().st_size > MAX_API_SIZE:
                raise RuntimeError(
                    f"Audio chunk is too large for OpenAI: {out.stat().st_size / 1e6:.1f} MB"
                )
            chunks.append(out)
            offset += CHUNK_DURATION
            idx += 1
        if not chunks:
            raise RuntimeError("ffmpeg produced no chunks")
        return chunks

    async def _transcribe_file(self, filepath: Path, model: str, prompt: str | None = None) -> str:
        audio_data = filepath.read_bytes()
        if "diarize" in model:
            return await self._call_diarize(model, filepath.name, audio_data)
        return await self._call_standard(model, filepath.name, audio_data, prompt)

    async def _call_diarize(self, model: str, filename: str, audio_data: bytes) -> str:
        resp = await self.client.audio.transcriptions.create(
            model=model,
            file=(filename, audio_data),
            response_format="diarized_json",
            chunking_strategy="auto",
        )
        segments = getattr(resp, "segments", None)
        if not segments:
            return getattr(resp, "text", str(resp))
        lines = []
        for seg in segments:
            speaker = seg.speaker if hasattr(seg, "speaker") else seg.get("speaker", "?")
            text = seg.text.strip() if hasattr(seg, "text") else seg["text"].strip()
            if text:
                lines.append(f"[{speaker}] — {text}")
        return "\n".join(lines)

    async def _call_standard(
        self, model: str, filename: str, audio_data: bytes, prompt: str | None = None
    ) -> str:
        response_format = "verbose_json" if model == "whisper-1" else "json"
        request = {
            "model": model,
            "file": (filename, audio_data),
            "response_format": response_format,
        }
        if model == "gpt-transcribe":
            request["chunking_strategy"] = "auto"
        if prompt:
            request["prompt"] = prompt
        resp = await self.client.audio.transcriptions.create(
            **request,
        )
        segments = getattr(resp, "segments", None)
        if segments and len(segments) > 1:
            lines = []
            for seg in segments:
                text = seg.text.strip() if hasattr(seg, "text") else seg["text"].strip()
                if text:
                    lines.append(f"— {text}")
            return "\n".join(lines)
        return resp.text
