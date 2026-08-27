import asyncio
import html
import logging
import shutil
import tempfile
import uuid
from pathlib import Path

from aiogram import Bot, Dispatcher, F, Router
from aiogram.client.session.aiohttp import AiohttpSession
from aiogram.client.telegram import TelegramAPIServer
from aiogram.enums import ContentType
from aiogram.types import (
    BufferedInputFile,
    CallbackQuery,
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    Message,
)

from config import config
from models import MODEL_OPTIONS, MODELS

log = logging.getLogger(__name__)

router = Router()

# task_id -> (filepath, original_name, original_message)
_pending: dict[str, tuple[Path, str, Message]] = {}
PENDING_TTL_SECONDS = 3600


def _safe_filename(value: str, fallback: str = "audio") -> str:
    """Keep user-provided names displayable and safe for temporary paths."""
    base = Path(value.replace("\\", "/")).name.strip()
    cleaned = "".join("_" if ord(char) < 32 or ord(char) == 127 else char for char in base)
    return (cleaned or fallback)[:180]


def _make_keyboard(task_id: str) -> InlineKeyboardMarkup:
    model_rows = [
        [InlineKeyboardButton(text=option.label, callback_data=f"{option.key}:{task_id}")]
        for option in MODEL_OPTIONS
    ]
    return InlineKeyboardMarkup(
        inline_keyboard=model_rows
        + [
            [InlineKeyboardButton(text="Отмена", callback_data=f"x:{task_id}")],
        ]
    )


def _cancel_keyboard(task_id: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[[InlineKeyboardButton(text="Отмена", callback_data=f"x:{task_id}")]]
    )


async def _expire_pending(task_id: str):
    await asyncio.sleep(PENDING_TTL_SECONDS)
    data = _pending.pop(task_id, None)
    if data:
        filepath, filename, _ = data
        filepath.unlink(missing_ok=True)
        log.info("TG: expired pending model choice: %s", filename)


@router.message(F.content_type.in_({ContentType.VOICE, ContentType.AUDIO, ContentType.DOCUMENT}))
async def handle_audio(message: Message, transcriber):
    if message.from_user.id not in config.telegram_allowed_users:
        log.warning("TG: rejected user %s (%s)", message.from_user.id, message.from_user.full_name)
        return

    if message.voice:
        file_id = message.voice.file_id
        filename = "voice.ogg"
        file_size = message.voice.file_size or 0
    elif message.audio:
        file_id = message.audio.file_id
        filename = message.audio.file_name or "audio.mp3"
        file_size = message.audio.file_size or 0
    elif message.document:
        mime = message.document.mime_type or ""
        if not mime.startswith("audio/"):
            return
        file_id = message.document.file_id
        filename = message.document.file_name or "document.ogg"
        file_size = message.document.file_size or 0
    else:
        return

    filename = _safe_filename(filename)

    log.info(
        "TG: audio from %s (%s) — %s (%.1f MB)",
        message.from_user.full_name,
        message.from_user.id,
        filename,
        file_size / 1e6,
    )

    try:
        bot = message.bot
        file_info = await bot.get_file(file_id)
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=f"_{filename}")
        if config.telegram_api_url:
            # Local mode: file_path is a local filesystem path on shared volume
            tmp.close()
            shutil.copy2(file_info.file_path, tmp.name)
        else:
            try:
                await bot.download_file(file_info.file_path, tmp)
            finally:
                tmp.close()
    except Exception as e:
        log.exception("TG: failed to download %s", filename)
        await message.reply(f"Ошибка загрузки: {e}")
        return

    task_id = uuid.uuid4().hex[:8]
    _pending[task_id] = (Path(tmp.name), filename, message)
    asyncio.create_task(_expire_pending(task_id))

    await message.reply("Выберите модель:", reply_markup=_make_keyboard(task_id))


@router.callback_query(F.data.regexp(r"^x:[0-9a-f]{8}$"))
async def on_cancel(callback: CallbackQuery, transcriber):
    if callback.from_user.id not in config.telegram_allowed_users:
        await callback.answer("Нет доступа", show_alert=True)
        return

    _, task_id = callback.data.split(":", 1)
    data = _pending.pop(task_id, None)
    if data:
        filepath, filename, _ = data
        filepath.unlink(missing_ok=True)
        log.info("TG: cancelled before transcription: %s", filename)
    else:
        transcriber.cancel(task_id)
        log.info("TG: cancelled during transcription: %s", task_id)

    await callback.message.edit_text("Отменено")
    await callback.answer()


@router.callback_query(F.data.regexp(r"^[gdw]:[0-9a-f]{8}$"))
async def on_model_choice(callback: CallbackQuery, transcriber):
    if callback.from_user.id not in config.telegram_allowed_users:
        await callback.answer("Нет доступа", show_alert=True)
        return

    key, task_id = callback.data.split(":", 1)
    data = _pending.pop(task_id, None)
    if not data:
        await callback.answer("Запрос устарел")
        return

    filepath, filename, original_msg = data
    model = MODELS[key]

    log.info("TG: model=%s chosen for %s by %s", model, filename, callback.from_user.full_name)

    await callback.message.edit_text(
        f"Транскрибирую... ({model})",
        reply_markup=_cancel_keyboard(task_id),
    )
    await callback.answer()

    status_msg = callback.message

    async def cb(text, error=None, *, msg=original_msg, name=filename):
        try:
            await status_msg.edit_text(f"Готово ({model})" if not error else f"Ошибка ({model})")
        except Exception:
            pass
        try:
            if error:
                log.error("TG callback error for %s: %s", name, error)
                await msg.reply(
                    f"Ошибка транскрибации <code>{html.escape(name)}</code>:\n"
                    f"<pre>{html.escape(error[:1500])}</pre>",
                    parse_mode="HTML",
                )
                return
            txt_name = name.rsplit(".", 1)[0] + ".txt" if "." in name else name + ".txt"
            await msg.reply_document(BufferedInputFile(text.encode("utf-8"), filename=txt_name))
            log.info("TG: sent result for %s", name)
        except Exception:
            log.exception("TG: failed to send result for %s", name)

    await transcriber.enqueue(filepath, filename, model, task_id, cb)


def create_telegram_bot(transcriber) -> tuple[Bot, Dispatcher]:
    session = None
    if config.telegram_api_url:
        log.info("TG: using local API server at %s", config.telegram_api_url)
        session = AiohttpSession(api=TelegramAPIServer.from_base(config.telegram_api_url))

    bot = Bot(token=config.telegram_token, session=session)
    dp = Dispatcher()
    dp["transcriber"] = transcriber
    dp.include_router(router)
    return bot, dp
