import logging
from datetime import timedelta
from typing import Any

from sqlalchemy import and_, exists, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import bad_request, forbidden, not_found, too_many
from app.models import (
    Chat,
    ChatMember,
    ChatType,
    HiddenMessage,
    Media,
    MemberRole,
    Message,
    MessageType,
)
from app.realtime import publish_to_users, utcnow
from app.schemas import MessageOut, SendMessageIn
from app.services.chats import is_admin, is_blocked_between, member_ids, private_peer_id
from app.services.serializers import message_out

logger = logging.getLogger(__name__)

MEDIA_KIND_BY_TYPE = {
    MessageType.PHOTO: {"photo"},
    MessageType.VIDEO: {"video"},
    MessageType.VOICE: {"voice"},
    MessageType.AUDIO: {"audio", "file"},
    MessageType.FILE: {"file", "photo", "video", "audio"},
    MessageType.STICKER: {"sticker", "photo"},
}


def visible_messages_filter(viewer_id: int, member: ChatMember | None):
    """SQL filter for messages a viewer can see in a chat."""
    conditions = [Message.is_deleted.is_(False)]
    if member is not None:
        conditions.append(Message.id > member.cleared_before_message_id)
        conditions.append(
            ~exists().where(and_(HiddenMessage.message_id == Message.id, HiddenMessage.user_id == viewer_id))
        )
    return and_(*conditions)


async def check_can_send(db: AsyncSession, chat: Chat, member: ChatMember, sender_id: int) -> None:
    if chat.type == ChatType.CHANNEL and not is_admin(member):
        raise forbidden("CHANNEL_ADMIN_ONLY")
    if chat.type == ChatType.GROUP and not chat.members_can_send and not is_admin(member):
        raise forbidden("CHAT_SEND_RESTRICTED")
    if chat.type == ChatType.PRIVATE:
        peer_id = await private_peer_id(db, chat, sender_id)
        if peer_id is not None and await is_blocked_between(db, sender_id, peer_id):
            raise forbidden("USER_BLOCKED")
    if chat.type == ChatType.GROUP and chat.slow_mode_seconds > 0 and not is_admin(member):
        last = await db.scalar(
            select(Message.created_at)
            .where(Message.chat_id == chat.id, Message.sender_id == sender_id)
            .order_by(Message.id.desc())
            .limit(1)
        )
        if last is not None:
            wait = chat.slow_mode_seconds - int((utcnow() - last).total_seconds())
            if wait > 0:
                raise too_many("SLOW_MODE", wait)


async def build_message_from_input(
    db: AsyncSession, chat: Chat, sender_id: int, payload: SendMessageIn
) -> Message:
    extra: dict[str, Any] | None = None
    media_id: int | None = None
    if payload.media_id is not None:
        media = await db.get(Media, payload.media_id)
        if media is None or media.owner_id != sender_id:
            raise bad_request("MEDIA_INVALID")
        allowed = MEDIA_KIND_BY_TYPE.get(payload.type)
        if allowed is None or media.kind not in allowed:
            raise bad_request("MEDIA_TYPE_MISMATCH")
        media_id = media.id
    if payload.type == MessageType.POLL and payload.poll is not None:
        extra = payload.poll.model_dump()
    elif payload.type == MessageType.LOCATION and payload.location is not None:
        extra = payload.location.model_dump()
    elif payload.type == MessageType.CONTACT and payload.contact is not None:
        extra = payload.contact.model_dump()
    if payload.silent:
        extra = {**(extra or {}), "silent": True}

    reply_to_id = None
    if payload.reply_to_id is not None:
        target = await db.scalar(
            select(Message.id).where(Message.id == payload.reply_to_id, Message.chat_id == chat.id)
        )
        if target is None:
            raise bad_request("REPLY_TARGET_INVALID")
        reply_to_id = target

    return Message(
        chat_id=chat.id,
        sender_id=sender_id,
        client_id=payload.client_id,
        type=payload.type,
        text=payload.text.strip() if payload.type == MessageType.TEXT else payload.text,
        entities=payload.entities,
        media_id=media_id,
        extra=extra,
        reply_to_id=reply_to_id,
    )


async def persist_and_broadcast(db: AsyncSession, chat: Chat, message: Message) -> MessageOut:
    """Insert a message, update chat/member bookkeeping, commit, and fan out `message.new`."""
    db.add(message)
    await db.flush()
    await db.execute(
        update(Chat).where(Chat.id == chat.id).values(last_message_id=message.id, updated_at=utcnow())
    )
    if message.sender_id is not None:
        await db.execute(
            update(ChatMember)
            .where(ChatMember.chat_id == chat.id, ChatMember.user_id == message.sender_id)
            .values(last_read_message_id=message.id, draft="")
        )
    # New activity brings archived, unmuted chats back to the main list (Telegram behaviour).
    await db.execute(
        update(ChatMember)
        .where(
            ChatMember.chat_id == chat.id,
            ChatMember.is_archived.is_(True),
            (ChatMember.muted_until.is_(None)) | (ChatMember.muted_until < utcnow()),
        )
        .values(is_archived=False)
    )
    await db.commit()
    await db.refresh(message, attribute_names=["media", "created_at"])
    out = await message_out(db, message.sender_id or 0, message)
    recipients = await member_ids(db, chat.id)
    await publish_to_users(recipients, "message.new", {"message": out})
    return out


async def find_existing_by_client_id(db: AsyncSession, sender_id: int, client_id: str | None) -> Message | None:
    if not client_id:
        return None
    return await db.scalar(select(Message).where(Message.sender_id == sender_id, Message.client_id == client_id))


async def post_system_message(db: AsyncSession, chat: Chat, actor_id: int | None, action: str, **data: Any) -> MessageOut:
    message = Message(
        chat_id=chat.id,
        sender_id=actor_id,
        type=MessageType.SYSTEM,
        text="",
        extra={"action": action, **data},
    )
    return await persist_and_broadcast(db, chat, message)


async def get_message_in_chat(db: AsyncSession, message_id: int) -> Message:
    message = await db.get(Message, message_id)
    if message is None or message.is_deleted:
        raise not_found("MESSAGE_NOT_FOUND")
    return message


def can_delete_for_everyone(chat: Chat, member: ChatMember, message: Message, viewer_id: int) -> bool:
    if chat.type == ChatType.SAVED:
        return True
    if chat.type == ChatType.PRIVATE:
        # Telegram allows revoking any message in private chats.
        return True
    if message.sender_id == viewer_id:
        return True
    if is_admin(member):
        # Admins cannot delete the owner's messages.
        return member.role == MemberRole.OWNER or message.sender_id != chat.created_by
    return False


def check_edit_window(message: Message, window_seconds: int) -> None:
    if message.type in (MessageType.SYSTEM, MessageType.POLL, MessageType.LOCATION, MessageType.CONTACT):
        raise bad_request("MESSAGE_NOT_EDITABLE")
    if utcnow() - message.created_at > timedelta(seconds=window_seconds):
        raise forbidden("MESSAGE_EDIT_TIME_EXPIRED")
