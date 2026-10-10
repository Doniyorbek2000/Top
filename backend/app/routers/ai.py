from fastapi import APIRouter
from sqlalchemy import select

from app.config import get_settings
from app.deps import DbDep, ViewerDep
from app.errors import bad_request
from app.models import Message, MessageType, User
from app.schemas import AiStatusOut, AiTextOut, RewriteIn, SummarizeIn, TranslateIn
from app.services import ai
from app.services.chats import require_member
from app.services.messages import visible_messages_filter

router = APIRouter(prefix="/ai", tags=["ai"])


@router.get("/status", response_model=AiStatusOut)
async def ai_status(viewer: ViewerDep) -> AiStatusOut:
    return AiStatusOut(enabled=get_settings().ai_enabled, bot_user_id=ai.bot_user_id())


@router.post("/translate", response_model=AiTextOut)
async def translate(body: TranslateIn, viewer: ViewerDep) -> AiTextOut:
    return AiTextOut(text=await ai.translate(body.text, body.target_language))


@router.post("/rewrite", response_model=AiTextOut)
async def rewrite(body: RewriteIn, viewer: ViewerDep) -> AiTextOut:
    return AiTextOut(text=await ai.rewrite(body.text, body.style, body.language))


@router.post("/summarize", response_model=AiTextOut)
async def summarize(body: SummarizeIn, viewer: ViewerDep, db: DbDep) -> AiTextOut:
    chat, member = await require_member(db, body.chat_id, viewer.id)
    rows = list(
        await db.scalars(
            select(Message)
            .where(
                Message.chat_id == chat.id,
                visible_messages_filter(viewer.id, member),
                Message.type.in_([MessageType.TEXT, MessageType.PHOTO, MessageType.VIDEO, MessageType.FILE]),
            )
            .order_by(Message.id.desc())
            .limit(body.limit)
        )
    )
    rows.reverse()
    if not rows:
        raise bad_request("NOTHING_TO_SUMMARIZE")
    sender_ids = {m.sender_id for m in rows if m.sender_id}
    names = {
        u.id: f"{u.first_name} {u.last_name}".strip() or (u.username or f"user{u.id}")
        for u in await db.scalars(select(User).where(User.id.in_(sender_ids)))
    }
    lines = []
    for m in rows:
        author = names.get(m.sender_id or -1, chat.title or "channel")
        body_text = m.text or f"[{m.type.value}]"
        lines.append(f"[{m.created_at:%Y-%m-%d %H:%M}] {author}: {body_text}")
    return AiTextOut(text=await ai.summarize("\n".join(lines), body.language))
