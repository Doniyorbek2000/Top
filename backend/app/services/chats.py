from collections.abc import Sequence

from sqlalchemy import exists, func, or_, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import bad_request, forbidden, not_found
from app.models import Block, Chat, ChatMember, ChatType, MemberRole, User
from app.realtime import publish_to_users


async def get_chat_or_404(db: AsyncSession, chat_id: int) -> Chat:
    chat = await db.get(Chat, chat_id)
    if chat is None:
        raise not_found("CHAT_NOT_FOUND")
    return chat


async def get_membership(db: AsyncSession, chat_id: int, user_id: int) -> ChatMember | None:
    return await db.scalar(select(ChatMember).where(ChatMember.chat_id == chat_id, ChatMember.user_id == user_id))


async def require_member(db: AsyncSession, chat_id: int, user_id: int) -> tuple[Chat, ChatMember]:
    member = await get_membership(db, chat_id, user_id)
    if member is None:
        # Do not leak existence of private chats.
        raise not_found("CHAT_NOT_FOUND")
    return member.chat, member


async def require_readable(db: AsyncSession, chat_id: int, user_id: int) -> tuple[Chat, ChatMember | None]:
    """Members can read any chat; non-members can read public groups/channels (preview before joining)."""
    member = await get_membership(db, chat_id, user_id)
    if member is not None:
        return member.chat, member
    chat = await get_chat_or_404(db, chat_id)
    if chat.type in (ChatType.GROUP, ChatType.CHANNEL) and chat.username:
        return chat, None
    raise not_found("CHAT_NOT_FOUND")


def is_admin(member: ChatMember | None) -> bool:
    return member is not None and member.role in (MemberRole.OWNER, MemberRole.ADMIN)


def require_admin(member: ChatMember) -> None:
    if not is_admin(member):
        raise forbidden("ADMIN_REQUIRED")


async def member_ids(db: AsyncSession, chat_id: int) -> list[int]:
    return list(await db.scalars(select(ChatMember.user_id).where(ChatMember.chat_id == chat_id)))


async def is_blocked_between(db: AsyncSession, a: int, b: int) -> bool:
    return bool(
        await db.scalar(
            select(
                exists().where(
                    or_(
                        (Block.owner_id == a) & (Block.blocked_id == b),
                        (Block.owner_id == b) & (Block.blocked_id == a),
                    )
                )
            )
        )
    )


async def private_peer_id(db: AsyncSession, chat: Chat, viewer_id: int) -> int | None:
    if chat.type != ChatType.PRIVATE or not chat.private_key:
        return None
    low, high = (int(x) for x in chat.private_key.split(":"))
    return high if low == viewer_id else low


async def get_or_create_private_chat(db: AsyncSession, viewer_id: int, peer_id: int) -> Chat:
    if viewer_id == peer_id:
        return await get_or_create_saved_chat(db, viewer_id)
    peer = await db.get(User, peer_id)
    if peer is None:
        raise not_found("USER_NOT_FOUND")
    low, high = sorted((viewer_id, peer_id))
    key = f"{low}:{high}"
    chat = await db.scalar(select(Chat).where(Chat.private_key == key))
    if chat is None:
        inserted = await db.execute(
            pg_insert(Chat)
            .values(type=ChatType.PRIVATE, private_key=key, created_by=viewer_id, member_count=2)
            .on_conflict_do_nothing(index_elements=[Chat.private_key])
            .returning(Chat.id)
        )
        chat_id = inserted.scalar_one_or_none()
        if chat_id is None:
            chat = await db.scalar(select(Chat).where(Chat.private_key == key))
        else:
            chat = await db.get(Chat, chat_id)
    assert chat is not None
    await db.execute(
        pg_insert(ChatMember)
        .values([
            {"chat_id": chat.id, "user_id": low, "role": MemberRole.MEMBER},
            {"chat_id": chat.id, "user_id": high, "role": MemberRole.MEMBER},
        ])
        .on_conflict_do_nothing()
    )
    await db.commit()
    return chat


async def get_or_create_saved_chat(db: AsyncSession, user_id: int) -> Chat:
    key = f"saved:{user_id}"
    chat = await db.scalar(select(Chat).where(Chat.private_key == key))
    if chat is None:
        inserted = await db.execute(
            pg_insert(Chat)
            .values(type=ChatType.SAVED, private_key=key, created_by=user_id, member_count=1)
            .on_conflict_do_nothing(index_elements=[Chat.private_key])
            .returning(Chat.id)
        )
        chat_id = inserted.scalar_one_or_none()
        chat = await db.get(Chat, chat_id) if chat_id else await db.scalar(select(Chat).where(Chat.private_key == key))
        assert chat is not None
        await db.execute(
            pg_insert(ChatMember)
            .values(chat_id=chat.id, user_id=user_id, role=MemberRole.OWNER)
            .on_conflict_do_nothing()
        )
        await db.commit()
    return chat


async def add_members(db: AsyncSession, chat: Chat, user_ids: Sequence[int], role: MemberRole = MemberRole.MEMBER) -> list[int]:
    """Adds users that exist and are not yet members. Returns ids actually added."""
    if not user_ids:
        return []
    existing_users = set(await db.scalars(select(User.id).where(User.id.in_(set(user_ids)))))
    if not existing_users:
        return []
    result = await db.execute(
        pg_insert(ChatMember)
        .values([{"chat_id": chat.id, "user_id": uid, "role": role} for uid in existing_users])
        .on_conflict_do_nothing()
        .returning(ChatMember.user_id)
    )
    added = list(result.scalars())
    await refresh_member_count(db, chat)
    return added


async def refresh_member_count(db: AsyncSession, chat: Chat) -> None:
    count = await db.scalar(select(func.count()).select_from(ChatMember).where(ChatMember.chat_id == chat.id))
    await db.execute(update(Chat).where(Chat.id == chat.id).values(member_count=count or 0))
    chat.member_count = count or 0


async def notify_chat_updated(db: AsyncSession, chat_id: int, extra_user_ids: Sequence[int] = ()) -> None:
    ids = await member_ids(db, chat_id)
    await publish_to_users([*ids, *extra_user_ids], "chat.updated", {"chat_id": chat_id})


def ensure_group_like(chat: Chat) -> None:
    if chat.type not in (ChatType.GROUP, ChatType.CHANNEL):
        raise bad_request("NOT_A_GROUP")
