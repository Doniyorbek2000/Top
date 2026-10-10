from fastapi import APIRouter, status
from sqlalchemy import delete, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert

from app.config import get_settings
from app.deps import DbDep, ViewerDep
from app.errors import bad_request, forbidden, not_found
from app.models import ChatMember, ChatType, HiddenMessage, Message, MessageType, PollVote, Reaction, User
from app.realtime import publish_to_users, utcnow
from app.schemas import (
    DeleteMessagesIn,
    EditMessageIn,
    ForwardMessagesIn,
    MessageOut,
    ReactIn,
    SendMessageIn,
    VoteIn,
)
from app.services import ai
from app.services.chats import member_ids, require_member
from app.services.messages import (
    build_message_from_input,
    can_delete_for_everyone,
    check_can_send,
    check_edit_window,
    find_existing_by_client_id,
    get_message_in_chat,
    persist_and_broadcast,
)
from app.services.serializers import message_out, messages_out, poll_results

router = APIRouter(tags=["messages"])


@router.post("/chats/{chat_id}/messages", response_model=MessageOut, status_code=status.HTTP_201_CREATED)
async def send_message(chat_id: int, body: SendMessageIn, viewer: ViewerDep, db: DbDep) -> MessageOut:
    existing = await find_existing_by_client_id(db, viewer.id, body.client_id)
    if existing is not None:
        # Idempotent retry from a flaky network: return the stored message instead of duplicating it.
        return await message_out(db, viewer.id, existing)
    chat, member = await require_member(db, chat_id, viewer.id)
    await check_can_send(db, chat, member, viewer.id)
    message = await build_message_from_input(db, chat, viewer.id, body)
    out = await persist_and_broadcast(db, chat, message)
    if chat.type == ChatType.PRIVATE and message.type == MessageType.TEXT:
        ai.schedule_bot_reply_if_needed(chat.id, viewer.id)
    return out


@router.patch("/messages/{message_id}", response_model=MessageOut)
async def edit_message(message_id: int, body: EditMessageIn, viewer: ViewerDep, db: DbDep) -> MessageOut:
    message = await get_message_in_chat(db, message_id)
    chat, _ = await require_member(db, message.chat_id, viewer.id)
    if message.sender_id != viewer.id:
        raise forbidden("MESSAGE_AUTHOR_REQUIRED")
    if chat.type != ChatType.SAVED:
        check_edit_window(message, get_settings().message_edit_window_seconds)
    text = body.text.strip()
    if message.type == MessageType.TEXT and not text:
        raise bad_request("MESSAGE_EMPTY")
    message.text = text
    message.entities = body.entities
    message.edited_at = utcnow()
    await db.commit()
    out = await message_out(db, viewer.id, message)
    await publish_to_users(await member_ids(db, chat.id), "message.edited", {"message": out})
    return out


@router.post("/chats/{chat_id}/messages/delete", status_code=status.HTTP_204_NO_CONTENT)
async def delete_messages(chat_id: int, body: DeleteMessagesIn, viewer: ViewerDep, db: DbDep) -> None:
    chat, member = await require_member(db, chat_id, viewer.id)
    messages = list(
        await db.scalars(
            select(Message).where(
                Message.id.in_(body.message_ids), Message.chat_id == chat.id, Message.is_deleted.is_(False)
            )
        )
    )
    if not messages:
        return
    if body.for_everyone or chat.type == ChatType.CHANNEL:
        for m in messages:
            if not can_delete_for_everyone(chat, member, m, viewer.id):
                raise forbidden("MESSAGE_DELETE_FORBIDDEN")
        ids = [m.id for m in messages]
        await db.execute(
            update(Message)
            .where(Message.id.in_(ids))
            .values(is_deleted=True, text="", entities=None, media_id=None, extra=None)
        )
        await db.execute(delete(Reaction).where(Reaction.message_id.in_(ids)))
        if chat.pinned_message_id in ids:
            chat.pinned_message_id = None
        if chat.last_message_id in ids:
            chat.last_message_id = await db.scalar(
                select(Message.id)
                .where(Message.chat_id == chat.id, Message.is_deleted.is_(False), Message.id.not_in(ids))
                .order_by(Message.id.desc())
                .limit(1)
            )
        await db.commit()
        await publish_to_users(await member_ids(db, chat.id), "message.deleted", {"chat_id": chat.id, "message_ids": ids})
        return
    await db.execute(
        pg_insert(HiddenMessage)
        .values([{"user_id": viewer.id, "message_id": m.id} for m in messages])
        .on_conflict_do_nothing()
    )
    await db.commit()
    await publish_to_users([viewer.id], "message.deleted", {"chat_id": chat.id, "message_ids": [m.id for m in messages]})


@router.post("/messages/forward", response_model=list[MessageOut])
async def forward_messages(body: ForwardMessagesIn, viewer: ViewerDep, db: DbDep) -> list[MessageOut]:
    source_chat, _ = await require_member(db, body.from_chat_id, viewer.id)
    originals = list(
        await db.scalars(
            select(Message)
            .where(
                Message.id.in_(body.message_ids),
                Message.chat_id == source_chat.id,
                Message.is_deleted.is_(False),
                Message.type != MessageType.SYSTEM,
            )
            .order_by(Message.id)
        )
    )
    if not originals:
        raise not_found("MESSAGE_NOT_FOUND")
    sender_ids = {m.sender_id for m in originals if m.sender_id}
    senders = {u.id: u for u in await db.scalars(select(User).where(User.id.in_(sender_ids)))} if sender_ids else {}

    results: list[MessageOut] = []
    for target_id in dict.fromkeys(body.to_chat_ids):
        target_chat, target_member = await require_member(db, target_id, viewer.id)
        await check_can_send(db, target_chat, target_member, viewer.id)
        for original in originals:
            already_forwarded = original.forward_from_user_id or original.forward_from_chat_id or original.forward_sender_name
            if body.hide_sender:
                fwd_user, fwd_chat, fwd_msg, fwd_name = None, None, None, None
            elif already_forwarded:
                fwd_user = original.forward_from_user_id
                fwd_chat = original.forward_from_chat_id
                fwd_msg = original.forward_from_message_id
                fwd_name = original.forward_sender_name
            elif source_chat.type == ChatType.CHANNEL:
                fwd_user, fwd_chat, fwd_msg, fwd_name = None, source_chat.id, original.id, source_chat.title
            else:
                sender = senders.get(original.sender_id or -1)
                fwd_user = original.sender_id
                fwd_chat, fwd_msg = None, original.id
                fwd_name = f"{sender.first_name} {sender.last_name}".strip() if sender else None
            copy = Message(
                chat_id=target_chat.id,
                sender_id=viewer.id,
                type=original.type,
                text=original.text,
                entities=original.entities,
                media_id=original.media_id,
                extra=original.extra,
                forward_from_user_id=fwd_user,
                forward_from_chat_id=fwd_chat,
                forward_from_message_id=fwd_msg,
                forward_sender_name=fwd_name,
            )
            results.append(await persist_and_broadcast(db, target_chat, copy))
    return results


@router.post("/messages/{message_id}/reactions", response_model=MessageOut)
async def react(message_id: int, body: ReactIn, viewer: ViewerDep, db: DbDep) -> MessageOut:
    """One reaction per user. Sending the same emoji again or `null` removes it."""
    message = await get_message_in_chat(db, message_id)
    chat, _ = await require_member(db, message.chat_id, viewer.id)
    current = await db.scalar(
        select(Reaction.emoji).where(Reaction.message_id == message.id, Reaction.user_id == viewer.id)
    )
    await db.execute(delete(Reaction).where(Reaction.message_id == message.id, Reaction.user_id == viewer.id))
    added = body.emoji is not None and body.emoji != current
    if added:
        db.add(Reaction(message_id=message.id, user_id=viewer.id, emoji=body.emoji))
    await db.commit()
    out = await message_out(db, viewer.id, message)
    payload = {
        "chat_id": chat.id,
        "message_id": message.id,
        "actor_id": viewer.id,
        "emoji": body.emoji if added else None,
        "reactions": [{"emoji": r.emoji, "count": r.count} for r in out.reactions],
        "sender_id": message.sender_id,
    }
    await publish_to_users(await member_ids(db, chat.id), "message.reactions", payload)
    return out


@router.post("/messages/{message_id}/vote", response_model=MessageOut)
async def vote(message_id: int, body: VoteIn, viewer: ViewerDep, db: DbDep) -> MessageOut:
    message = await get_message_in_chat(db, message_id)
    if message.type != MessageType.POLL or not message.extra:
        raise bad_request("NOT_A_POLL")
    if (message.extra or {}).get("closed"):
        raise bad_request("POLL_CLOSED")
    chat, _ = await require_member(db, message.chat_id, viewer.id)
    options_count = len(message.extra.get("options", []))
    chosen = sorted(set(body.options))
    if any(i < 0 or i >= options_count for i in chosen):
        raise bad_request("POLL_OPTION_INVALID")
    if len(chosen) > 1 and not message.extra.get("multiple_choice"):
        raise bad_request("POLL_SINGLE_CHOICE")
    await db.execute(delete(PollVote).where(PollVote.message_id == message.id, PollVote.user_id == viewer.id))
    if chosen:
        await db.execute(
            pg_insert(PollVote).values([
                {"message_id": message.id, "user_id": viewer.id, "option_index": i} for i in chosen
            ])
        )
    await db.commit()
    results = (await poll_results(db, viewer.id, [message]))[message.id]
    await publish_to_users(
        await member_ids(db, chat.id),
        "message.poll",
        {
            "chat_id": chat.id,
            "message_id": message.id,
            "actor_id": viewer.id,
            "counts": results.counts,
            "total_voters": results.total_voters,
            "actor_votes": results.my_votes,
        },
    )
    return await message_out(db, viewer.id, message)


@router.post("/messages/{message_id}/close-poll", response_model=MessageOut)
async def close_poll(message_id: int, viewer: ViewerDep, db: DbDep) -> MessageOut:
    message = await get_message_in_chat(db, message_id)
    if message.type != MessageType.POLL:
        raise bad_request("NOT_A_POLL")
    if message.sender_id != viewer.id:
        raise forbidden("MESSAGE_AUTHOR_REQUIRED")
    message.extra = {**(message.extra or {}), "closed": True}
    await db.commit()
    out = await message_out(db, viewer.id, message)
    await publish_to_users(await member_ids(db, message.chat_id), "message.edited", {"message": out})
    return out


@router.get("/messages/{message_id}/readers", response_model=list[int])
async def message_readers(message_id: int, viewer: ViewerDep, db: DbDep) -> list[int]:
    """User ids who have read a message in a small group (Telegram shows this for groups up to 100 members)."""
    message = await get_message_in_chat(db, message_id)
    chat, _ = await require_member(db, message.chat_id, viewer.id)
    if chat.type != ChatType.GROUP or chat.member_count > 100:
        return []
    rows = await db.scalars(
        select(ChatMember.user_id).where(
            ChatMember.chat_id == chat.id,
            ChatMember.last_read_message_id >= message.id,
            ChatMember.user_id != message.sender_id,
        )
    )
    return list(rows)


@router.post("/messages/batch", response_model=list[MessageOut])
async def get_messages(ids: list[int], viewer: ViewerDep, db: DbDep) -> list[MessageOut]:
    if len(ids) > 200:
        raise bad_request("TOO_MANY_IDS")
    my_chats = select(ChatMember.chat_id).where(ChatMember.user_id == viewer.id)
    rows = list(
        await db.scalars(
            select(Message).where(Message.id.in_(set(ids)), Message.chat_id.in_(my_chats), Message.is_deleted.is_(False))
        )
    )
    return await messages_out(db, viewer.id, rows)
