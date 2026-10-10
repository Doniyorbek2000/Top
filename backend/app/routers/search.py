from fastapi import APIRouter, Query
from sqlalchemy import and_, exists, func, or_, select

from app.deps import DbDep, ViewerDep
from app.models import Chat, ChatMember, ChatType, Contact, HiddenMessage, Message, MessageType, User
from app.schemas import SearchOut
from app.services.serializers import chats_out, messages_out, users_out

router = APIRouter(prefix="/search", tags=["search"])


@router.get("", response_model=SearchOut)
async def global_search(
    viewer: ViewerDep,
    db: DbDep,
    q: str = Query(min_length=1, max_length=64),
    limit: int = Query(default=20, ge=1, le=50),
) -> SearchOut:
    """Telegram-style global search: my chats and contacts, public usernames, and messages in my chats."""
    term = q.strip().lstrip("@")
    pattern = f"%{term}%"
    prefix = f"{term}%"

    my_chat_ids = select(ChatMember.chat_id).where(ChatMember.user_id == viewer.id)

    # Users: contacts by name, anyone by username prefix.
    contact_ids = select(Contact.contact_id).where(Contact.owner_id == viewer.id)
    users = list(
        await db.scalars(
            select(User)
            .where(
                User.id != viewer.id,
                or_(
                    User.username.ilike(prefix),
                    (User.id.in_(contact_ids)) & (
                        (func.concat(User.first_name, " ", User.last_name).ilike(pattern))
                    ),
                ),
            )
            .order_by(func.length(User.username).nulls_last())
            .limit(limit)
        )
    )

    # Chats: my groups/channels by title, plus public groups/channels by username or title.
    chats = list(
        await db.scalars(
            select(Chat)
            .where(
                Chat.type.in_([ChatType.GROUP, ChatType.CHANNEL]),
                or_(
                    (Chat.id.in_(my_chat_ids)) & Chat.title.ilike(pattern),
                    Chat.username.ilike(prefix),
                    (Chat.username.isnot(None)) & Chat.title.ilike(pattern),
                ),
            )
            .order_by(Chat.member_count.desc())
            .limit(limit)
        )
    )

    messages: list[Message] = []
    if len(term) >= 2:
        member_rows = {
            m.chat_id: m for m in await db.scalars(select(ChatMember).where(ChatMember.user_id == viewer.id))
        }
        candidates = list(
            await db.scalars(
                select(Message)
                .where(
                    Message.chat_id.in_(my_chat_ids),
                    Message.is_deleted.is_(False),
                    Message.type != MessageType.SYSTEM,
                    Message.text.ilike(pattern),
                    ~exists().where(and_(HiddenMessage.message_id == Message.id, HiddenMessage.user_id == viewer.id)),
                )
                .order_by(Message.id.desc())
                .limit(limit * 2)
            )
        )
        messages = [
            m for m in candidates if m.id > member_rows[m.chat_id].cleared_before_message_id
        ][:limit]

    return SearchOut(
        users=await users_out(db, viewer.id, users),
        chats=await chats_out(db, viewer.id, chats),
        messages=await messages_out(db, viewer.id, messages),
    )
