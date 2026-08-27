import asyncio
import hmac
import logging
import os
from logging.handlers import RotatingFileHandler
from pathlib import Path

from aiohttp import web
from dotenv import load_dotenv

load_dotenv()

from config import config  # noqa: E402
from models import MODELS  # noqa: E402
from telegram_bot import create_telegram_bot  # noqa: E402
from transcriber import Transcriber  # noqa: E402

LOG_DIR = "logs"
os.makedirs(LOG_DIR, exist_ok=True)

fmt = logging.Formatter("%(asctime)s [%(name)s] %(levelname)s: %(message)s")

root = logging.getLogger()
root.setLevel(logging.INFO)

console = logging.StreamHandler()
console.setFormatter(fmt)
root.addHandler(console)

file_handler = RotatingFileHandler(
    f"{LOG_DIR}/bot.log", maxBytes=10 * 1024 * 1024, backupCount=5, encoding="utf-8"
)
file_handler.setFormatter(fmt)
root.addHandler(file_handler)

log = logging.getLogger(__name__)


def _shared_file(raw_path: str) -> Path:
    shared_root = Path(config.shared_dir).resolve()
    try:
        candidate = Path(raw_path).resolve(strict=True)
        candidate.relative_to(shared_root)
    except (FileNotFoundError, ValueError) as error:
        raise web.HTTPBadRequest(
            text="File must exist inside the shared audio directory"
        ) from error
    if not candidate.is_file():
        raise web.HTTPBadRequest(text="Shared path is not a regular file")
    return candidate


@web.middleware
async def require_internal_auth(request, handler):
    if request.method != "GET":
        expected = f"Bearer {config.internal_api_token}"
        provided = request.headers.get("Authorization", "")
        if not hmac.compare_digest(provided, expected):
            raise web.HTTPUnauthorized(text="Invalid internal API token")
    return await handler(request)


# ── HTTP API for Node.js Discord bot ─────────────────────────


async def handle_transcribe(request):
    data = await request.json()
    transcriber = request.app["transcriber"]

    file_path = _shared_file(data["file_path"])
    model_key = data["model"]
    task_id = data["task_id"]

    if model_key not in MODELS:
        raise web.HTTPBadRequest(text="Unknown transcription model")
    model = MODELS[model_key]
    original_name = data.get("original_name", file_path.name)

    await transcriber.enqueue_http(
        file_path,
        original_name,
        model,
        task_id,
        config.discord_callback_url,
        config.internal_api_token,
    )

    return web.json_response({"ok": True, "task_id": task_id})


async def handle_cancel(request):
    data = await request.json()
    transcriber = request.app["transcriber"]
    transcriber.cancel(data["task_id"])
    return web.json_response({"ok": True})


async def handle_health(request):
    transcriber = request.app["transcriber"]
    return web.json_response(
        {
            "ok": True,
            "queue_size": transcriber.queue.qsize(),
        }
    )


async def handle_send_telegram(request):
    data = await request.json()
    tg_bot = request.app["tg_bot"]

    chat_id = int(data["chat_id"])
    if chat_id not in config.telegram_fallback_chats:
        raise web.HTTPForbidden(text="Telegram fallback chat is not allowed")
    file_path = _shared_file(data["file_path"])
    filename = data["filename"]

    from aiogram.types import FSInputFile

    tg_file = FSInputFile(file_path, filename=filename)
    await tg_bot.send_document(chat_id, tg_file)

    return web.json_response({"ok": True})


async def main():
    transcriber = Transcriber()

    for _ in range(config.workers):
        asyncio.create_task(transcriber.worker())

    tg_bot, tg_dp = create_telegram_bot(transcriber)

    # HTTP server
    app = web.Application(middlewares=[require_internal_auth], client_max_size=1024 * 1024)
    app["transcriber"] = transcriber
    app["tg_bot"] = tg_bot
    app.router.add_post("/transcribe", handle_transcribe)
    app.router.add_post("/cancel", handle_cancel)
    app.router.add_get("/health", handle_health)
    app.router.add_post("/send-telegram", handle_send_telegram)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", config.http_port)
    await site.start()

    log.info("HTTP API listening on port %d", config.http_port)
    log.info("Starting Telegram bot (workers=%d)...", config.workers)

    await tg_dp.start_polling(tg_bot)


if __name__ == "__main__":
    asyncio.run(main())
