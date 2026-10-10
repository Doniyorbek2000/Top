"""Sado AI: translation, rewriting, chat summaries and an assistant bot, powered by Claude."""

import asyncio
import logging

import anthropic
from sqlalchemy import select

from app.config import get_settings
from app.db import SessionFactory
from app.errors import ApiError
from app.models import Chat, ChatType, Message, MessageType, User
from app.realtime import publish_to_users

logger = logging.getLogger(__name__)

_client: anthropic.AsyncAnthropic | None = None
_bot_user_id: int | None = None
_background_tasks: set[asyncio.Task[None]] = set()

BOT_SYSTEM_PROMPT = (
    "You are Sado AI, the built-in assistant of the Sado messenger. Reply in the language the user writes in "
    "(Uzbek, Russian, English or any other). Be concise and practical: this is a chat, so prefer short paragraphs "
    "and plain text. Markdown is rendered only for **bold**, _italic_ and `code`."
)

LANGUAGE_NAMES = {"uz": "Uzbek (Latin script)", "ru": "Russian", "en": "English", "tr": "Turkish", "kk": "Kazakh"}

REWRITE_INSTRUCTIONS = {
    "fix": "Fix spelling, grammar and punctuation. Keep the meaning, tone and language unchanged.",
    "formal": "Rewrite in a polite, formal business tone.",
    "friendly": "Rewrite in a warm, friendly, casual tone.",
    "short": "Make it shorter and clearer while keeping all key information.",
    "expand": "Expand it with a bit more detail and clarity, keeping the same intent.",
}


def _get_client() -> anthropic.AsyncAnthropic:
    global _client
    settings = get_settings()
    if not settings.ai_enabled:
        raise ApiError(503, "AI_DISABLED", "AI features are not configured on this server")
    if _client is None:
        _client = anthropic.AsyncAnthropic(api_key=settings.anthropic_api_key, timeout=120.0)
    return _client


def bot_user_id() -> int | None:
    return _bot_user_id


def _language_name(code: str) -> str:
    return LANGUAGE_NAMES.get(code.lower(), code)


async def _complete(system: str, messages: list[dict], max_tokens: int = 4096, effort: str = "low") -> str:
    client = _get_client()
    settings = get_settings()
    try:
        response = await client.beta.messages.create(
            model=settings.ai_model,
            max_tokens=max_tokens,
            system=system,
            messages=messages,
            output_config={"effort": effort},
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
        )
    except anthropic.RateLimitError as exc:
        raise ApiError(429, "AI_RATE_LIMITED") from exc
    except anthropic.APIStatusError as exc:
        logger.error("Claude API error %s: %s", exc.status_code, exc.message)
        raise ApiError(502, "AI_UPSTREAM_ERROR") from exc
    except anthropic.APIConnectionError as exc:
        logger.error("Claude API connection error: %s", exc)
        raise ApiError(502, "AI_UNAVAILABLE") from exc
    if response.stop_reason == "refusal":
        raise ApiError(422, "AI_REFUSED")
    text = "".join(block.text for block in response.content if block.type == "text").strip()
    if not text:
        raise ApiError(502, "AI_EMPTY_RESPONSE")
    return text


async def translate(text: str, target_language: str) -> str:
    system = (
        f"Translate the user's message into {_language_name(target_language)}. "
        "Output only the translation, preserving emoji, line breaks, names and links."
    )
    return await _complete(system, [{"role": "user", "content": text}])


async def rewrite(text: str, style: str, language: str | None) -> str:
    instruction = REWRITE_INSTRUCTIONS[style]
    if language:
        instruction += f" Write the result in {_language_name(language)}."
    system = f"You are a writing assistant inside a messenger. {instruction} Output only the rewritten message."
    return await _complete(system, [{"role": "user", "content": text}])


async def summarize(transcript: str, language: str) -> str:
    system = (
        f"Summarize this group chat transcript in {_language_name(language)}. Give the main topics, decisions, "
        "open questions and anything addressed to the reader as a short bulleted list. Output only the summary."
    )
    return await _complete(system, [{"role": "user", "content": transcript}], max_tokens=8000, effort="medium")


async def ensure_bot_user() -> None:
    """Create the assistant account on startup so users can find it by username."""
    global _bot_user_id
    settings = get_settings()
    async with SessionFactory() as db:
        bot = await db.scalar(select(User).where(User.username == settings.ai_bot_username))
        if bot is None:
            bot = User(username=settings.ai_bot_username, first_name="Sado AI", is_bot=True,
                       bio="Tarjima, matn yozish va savollarga javob beruvchi yordamchi")
            db.add(bot)
            await db.commit()
        _bot_user_id = bot.id


def schedule_bot_reply_if_needed(chat_id: int, sender_id: int) -> None:
    if _bot_user_id is None or sender_id == _bot_user_id or not get_settings().ai_enabled:
        return
    task = asyncio.create_task(_reply_as_bot(chat_id, sender_id))
    _background_tasks.add(task)
    task.add_done_callback(_background_tasks.discard)


async def _reply_as_bot(chat_id: int, sender_id: int) -> None:
    from app.services.messages import persist_and_broadcast

    bot_id = _bot_user_id
    assert bot_id is not None
    async with SessionFactory() as db:
        chat = await db.get(Chat, chat_id)
        low_high = f"{min(sender_id, bot_id)}:{max(sender_id, bot_id)}"
        if chat is None or chat.type != ChatType.PRIVATE or chat.private_key != low_high:
            return
        await publish_to_users([sender_id], "typing", {"chat_id": chat_id, "user_id": bot_id, "action": "typing"})
        history = list(
            await db.scalars(
                select(Message)
                .where(Message.chat_id == chat_id, Message.is_deleted.is_(False), Message.type == MessageType.TEXT)
                .order_by(Message.id.desc())
                .limit(30)
            )
        )
        history.reverse()
        turns: list[dict] = []
        for message in history:
            role = "assistant" if message.sender_id == bot_id else "user"
            if turns and turns[-1]["role"] == role:
                turns[-1]["content"] += "\n\n" + message.text
            else:
                turns.append({"role": role, "content": message.text})
        while turns and turns[0]["role"] != "user":
            turns.pop(0)
        if not turns or turns[-1]["role"] != "user":
            return
        try:
            reply = await _complete(BOT_SYSTEM_PROMPT, turns, max_tokens=8000, effort="medium")
        except ApiError as exc:
            logger.warning("bot reply failed: %s", exc.detail)
            reply = "Kechirasiz, hozir javob bera olmayman. Birozdan so'ng qayta urinib ko'ring."
        await persist_and_broadcast(db, chat, Message(chat_id=chat_id, sender_id=bot_id, type=MessageType.TEXT, text=reply))
