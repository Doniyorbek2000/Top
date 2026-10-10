from datetime import UTC, datetime

from fastapi import APIRouter, Query, status
from sqlalchemy import delete, func, select, update

from app.deps import DbDep, ViewerDep
from app.errors import bad_request, conflict, forbidden, not_found
from app.models import Chat, ChatMember, ChatType, HiddenMessage, Media, MemberRole, Message, User
from app.realtime import publish_to_users, utcnow
from app.routers.users import username_taken
from app.schemas import (
    AddMembersIn,
    ChatOut,
    ChatSettingsIn,
    ClearHistoryIn,
    CreateChannelIn,
    CreateGroupIn,
    CreatePrivateIn,
    InvitePreviewOut,
    JoinChatIn,
    MemberOut,
    MessageOut,
    PinMessageIn,
    ReadIn,
    UpdateChatIn,
    UpdateMemberIn,
)
from app.security import new_invite_hash
from app.services.chats import (
    add_members,
    ensure_group_like,
    get_or_create_private_chat,
    get_or_create_saved_chat,
    is_admin,
    member_ids,
    notify_chat_updated,
    refresh_member_count,
    require_admin,
    require_member,
    require_readable,
)
from app.services.messages import post_system_message, visible_messages_filter
from app.services.serializers import chat_out, chats_out, media_out, messages_out, users_out

router = APIRouter(prefix="/chats", tags=["chats"])

MAX_PINNED_CHATS = 10


@router.get("", response_model=list[ChatOut])
async def list_chats(
    viewer: ViewerDep,
    db: DbDep,
    archived: bool | None = None,
    updated_after: datetime | None = None,
    limit: int = Query(default=500, ge=1, le=1000),
) -> list[ChatOut]:
    """All chats of the viewer ordered by pin, then last activity. `updated_after` enables delta sync."""
    query = (
        select(ChatMember)
        .join(Chat, Chat.id == ChatMember.chat_id)
        .where(ChatMember.user_id == viewer.id)
        .order_by(ChatMember.is_pinned.desc(), ChatMember.pin_order, Chat.updated_at.desc())
        .limit(limit)
    )
    if archived is not None:
        query = query.where(ChatMember.is_archived.is_(archived))
    if updated_after is not None:
        query = query.where(Chat.updated_at > updated_after)
    memberships = list(await db.scalars(query))
    # Private chats appear once they have messages and disappear after "delete chat" until new activity.
    memberships = [
        m for m in memberships
        if not (
            m.chat.type == ChatType.PRIVATE
            and (m.chat.last_message_id or 0) <= m.cleared_before_message_id
            and not m.draft
        )
    ]
    return await chats_out(db, viewer.id, [m.chat for m in memberships], {m.chat_id: m for m in memberships})


@router.get("/saved", response_model=ChatOut)
async def saved_messages(viewer: ViewerDep, db: DbDep) -> ChatOut:
    chat = await get_or_create_saved_chat(db, viewer.id)
    return await chat_out(db, viewer.id, chat)


@router.post("/private", response_model=ChatOut)
async def open_private_chat(body: CreatePrivateIn, viewer: ViewerDep, db: DbDep) -> ChatOut:
    chat = await get_or_create_private_chat(db, viewer.id, body.user_id)
    return await chat_out(db, viewer.id, chat)


async def _validate_avatar(db: DbDep, media_id: int | None, owner_id: int) -> int | None:
    if media_id is None:
        return None
    media = await db.get(Media, media_id)
    if media is None or media.owner_id != owner_id or media.kind != "photo":
        raise bad_request("MEDIA_INVALID")
    return media.id


@router.post("/group", response_model=ChatOut, status_code=status.HTTP_201_CREATED)
async def create_group(body: CreateGroupIn, viewer: ViewerDep, db: DbDep) -> ChatOut:
    chat = Chat(
        type=ChatType.GROUP,
        title=body.title,
        created_by=viewer.id,
        avatar_media_id=await _validate_avatar(db, body.avatar_media_id, viewer.id),
        invite_hash=new_invite_hash(),
    )
    db.add(chat)
    await db.flush()
    db.add(ChatMember(chat_id=chat.id, user_id=viewer.id, role=MemberRole.OWNER))
    await db.flush()
    await add_members(db, chat, [uid for uid in body.member_ids if uid != viewer.id])
    await db.commit()
    await post_system_message(db, chat, viewer.id, "group_created", title=chat.title)
    return await chat_out(db, viewer.id, chat)


@router.post("/channel", response_model=ChatOut, status_code=status.HTTP_201_CREATED)
async def create_channel(body: CreateChannelIn, viewer: ViewerDep, db: DbDep) -> ChatOut:
    if body.username and await username_taken(db, body.username):
        raise conflict("USERNAME_OCCUPIED")
    chat = Chat(
        type=ChatType.CHANNEL,
        title=body.title,
        description=body.description,
        username=body.username,
        created_by=viewer.id,
        avatar_media_id=await _validate_avatar(db, body.avatar_media_id, viewer.id),
        invite_hash=new_invite_hash(),
        member_count=1,
    )
    db.add(chat)
    await db.flush()
    db.add(ChatMember(chat_id=chat.id, user_id=viewer.id, role=MemberRole.OWNER))
    await db.commit()
    await post_system_message(db, chat, viewer.id, "channel_created", title=chat.title)
    return await chat_out(db, viewer.id, chat)


@router.get("/invite/{invite_hash}", response_model=InvitePreviewOut)
async def preview_invite(invite_hash: str, viewer: ViewerDep, db: DbDep) -> InvitePreviewOut:
    chat = await db.scalar(select(Chat).where(Chat.invite_hash == invite_hash))
    if chat is None:
        raise not_found("INVITE_INVALID")
    is_member = await db.scalar(
        select(ChatMember.user_id).where(ChatMember.chat_id == chat.id, ChatMember.user_id == viewer.id)
    )
    avatar = await db.get(Media, chat.avatar_media_id) if chat.avatar_media_id else None
    return InvitePreviewOut(
        chat_id=chat.id,
        type=chat.type,
        title=chat.title,
        description=chat.description,
        avatar=media_out(avatar),
        member_count=chat.member_count,
        is_member=is_member is not None,
    )


@router.post("/join", response_model=ChatOut)
async def join_chat(body: JoinChatIn, viewer: ViewerDep, db: DbDep) -> ChatOut:
    if body.username:
        chat = await db.scalar(select(Chat).where(func.lower(Chat.username) == body.username.lower()))
    else:
        chat = await db.scalar(select(Chat).where(Chat.invite_hash == body.invite_hash))
    if chat is None or chat.type not in (ChatType.GROUP, ChatType.CHANNEL):
        raise not_found("CHAT_NOT_FOUND")
    added = await add_members(db, chat, [viewer.id])
    await db.commit()
    if added:
        if chat.type == ChatType.GROUP:
            await post_system_message(db, chat, viewer.id, "member_joined", user_ids=[viewer.id])
        else:
            await notify_chat_updated(db, chat.id)
    return await chat_out(db, viewer.id, chat)


@router.get("/{chat_id}", response_model=ChatOut)
async def get_chat(chat_id: int, viewer: ViewerDep, db: DbDep) -> ChatOut:
    chat, _ = await require_readable(db, chat_id, viewer.id)
    return await chat_out(db, viewer.id, chat)


@router.patch("/{chat_id}", response_model=ChatOut)
async def update_chat(chat_id: int, body: UpdateChatIn, viewer: ViewerDep, db: DbDep) -> ChatOut:
    chat, member = await require_member(db, chat_id, viewer.id)
    ensure_group_like(chat)
    require_admin(member)
    fields = body.model_fields_set
    title_changed = False
    if body.title is not None and body.title != chat.title:
        chat.title = body.title
        title_changed = True
    if body.description is not None:
        chat.description = body.description
    if "username" in fields:
        new_username = body.username or None
        if new_username and await username_taken(db, new_username, exclude_chat_id=chat.id):
            raise conflict("USERNAME_OCCUPIED")
        chat.username = new_username
    avatar_changed = False
    if body.remove_avatar:
        chat.avatar_media_id = None
        avatar_changed = True
    elif body.avatar_media_id is not None:
        chat.avatar_media_id = await _validate_avatar(db, body.avatar_media_id, viewer.id)
        avatar_changed = True
    if body.members_can_send is not None:
        chat.members_can_send = body.members_can_send
    if body.slow_mode_seconds is not None:
        chat.slow_mode_seconds = body.slow_mode_seconds
    chat.updated_at = utcnow()
    await db.commit()
    if title_changed:
        await post_system_message(db, chat, viewer.id, "title_changed", title=chat.title)
    elif avatar_changed:
        await post_system_message(db, chat, viewer.id, "photo_changed")
    else:
        await notify_chat_updated(db, chat.id)
    return await chat_out(db, viewer.id, chat)


@router.patch("/{chat_id}/settings", response_model=ChatOut)
async def update_my_chat_settings(chat_id: int, body: ChatSettingsIn, viewer: ViewerDep, db: DbDep) -> ChatOut:
    chat, member = await require_member(db, chat_id, viewer.id)
    if body.is_pinned is not None and body.is_pinned != member.is_pinned:
        if body.is_pinned:
            pinned_count = await db.scalar(
                select(func.count()).select_from(ChatMember).where(
                    ChatMember.user_id == viewer.id, ChatMember.is_pinned.is_(True)
                )
            )
            if (pinned_count or 0) >= MAX_PINNED_CHATS:
                raise bad_request("PINNED_LIMIT_REACHED")
            min_order = await db.scalar(
                select(func.min(ChatMember.pin_order)).where(ChatMember.user_id == viewer.id, ChatMember.is_pinned.is_(True))
            )
            member.pin_order = (min_order or 0) - 1
        member.is_pinned = body.is_pinned
    if body.is_archived is not None:
        member.is_archived = body.is_archived
        if body.is_archived:
            member.is_pinned = False
    if body.unmute:
        member.muted_until = None
    elif body.muted_until is not None:
        member.muted_until = body.muted_until.astimezone(UTC)
    if body.draft is not None:
        member.draft = body.draft
    await db.commit()
    await publish_to_users([viewer.id], "chat.updated", {"chat_id": chat.id})
    return await chat_out(db, viewer.id, chat)


@router.post("/pinned/order", status_code=status.HTTP_204_NO_CONTENT)
async def reorder_pinned(chat_ids: list[int], viewer: ViewerDep, db: DbDep) -> None:
    for index, cid in enumerate(chat_ids[:MAX_PINNED_CHATS]):
        await db.execute(
            update(ChatMember)
            .where(ChatMember.user_id == viewer.id, ChatMember.chat_id == cid, ChatMember.is_pinned.is_(True))
            .values(pin_order=index)
        )
    await db.commit()


@router.get("/{chat_id}/members", response_model=list[MemberOut])
async def list_members(
    chat_id: int,
    viewer: ViewerDep,
    db: DbDep,
    offset: int = Query(default=0, ge=0),
    limit: int = Query(default=100, ge=1, le=200),
    q: str | None = Query(default=None, max_length=64),
) -> list[MemberOut]:
    chat, member = await require_member(db, chat_id, viewer.id)
    if chat.type == ChatType.CHANNEL and not is_admin(member):
        raise forbidden("ADMIN_REQUIRED")
    query = (
        select(ChatMember, User)
        .join(User, User.id == ChatMember.user_id)
        .where(ChatMember.chat_id == chat.id)
        .order_by(ChatMember.role, ChatMember.joined_at)
        .offset(offset)
        .limit(limit)
    )
    if q:
        pattern = f"%{q}%"
        query = query.where(
            User.first_name.ilike(pattern) | User.last_name.ilike(pattern) | User.username.ilike(pattern)
        )
    rows = (await db.execute(query)).all()
    users = await users_out(db, viewer.id, [u for _, u in rows])
    return [MemberOut(user=u, role=m.role, joined_at=m.joined_at) for (m, _), u in zip(rows, users, strict=True)]


@router.post("/{chat_id}/members", response_model=ChatOut)
async def invite_members(chat_id: int, body: AddMembersIn, viewer: ViewerDep, db: DbDep) -> ChatOut:
    chat, member = await require_member(db, chat_id, viewer.id)
    ensure_group_like(chat)
    if chat.type == ChatType.CHANNEL or not chat.members_can_send:
        require_admin(member)
    added = await add_members(db, chat, body.user_ids)
    await db.commit()
    if added:
        await post_system_message(db, chat, viewer.id, "members_added", user_ids=added)
    return await chat_out(db, viewer.id, chat)


@router.patch("/{chat_id}/members/{user_id}", response_model=MemberOut)
async def update_member(chat_id: int, user_id: int, body: UpdateMemberIn, viewer: ViewerDep, db: DbDep) -> MemberOut:
    chat, member = await require_member(db, chat_id, viewer.id)
    ensure_group_like(chat)
    if member.role != MemberRole.OWNER:
        raise forbidden("OWNER_REQUIRED")
    target = await db.scalar(select(ChatMember).where(ChatMember.chat_id == chat.id, ChatMember.user_id == user_id))
    if target is None:
        raise not_found("MEMBER_NOT_FOUND")
    if target.role == MemberRole.OWNER:
        raise bad_request("CANNOT_CHANGE_OWNER")
    target.role = body.role
    await db.commit()
    await notify_chat_updated(db, chat.id)
    user = await db.get(User, user_id)
    assert user is not None
    return MemberOut(user=(await users_out(db, viewer.id, [user]))[0], role=target.role, joined_at=target.joined_at)


@router.delete("/{chat_id}/members/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_member(chat_id: int, user_id: int, viewer: ViewerDep, db: DbDep) -> None:
    """Kick a member (admin) or leave the chat (user_id == viewer)."""
    chat, member = await require_member(db, chat_id, viewer.id)
    ensure_group_like(chat)
    leaving = user_id == viewer.id
    target = member if leaving else await db.scalar(
        select(ChatMember).where(ChatMember.chat_id == chat.id, ChatMember.user_id == user_id)
    )
    if target is None:
        raise not_found("MEMBER_NOT_FOUND")
    if not leaving:
        require_admin(member)
        if target.role == MemberRole.OWNER or (target.role == MemberRole.ADMIN and member.role != MemberRole.OWNER):
            raise forbidden("CANNOT_REMOVE_ADMIN")
    if leaving and member.role == MemberRole.OWNER:
        # Hand ownership to the oldest admin, else the oldest member; delete the chat if nobody remains.
        successor = await db.scalar(
            select(ChatMember)
            .where(ChatMember.chat_id == chat.id, ChatMember.user_id != viewer.id)
            .order_by((ChatMember.role == MemberRole.ADMIN).desc(), ChatMember.joined_at)
            .limit(1)
        )
        if successor is None:
            await db.delete(chat)
            await db.commit()
            await publish_to_users([viewer.id], "chat.removed", {"chat_id": chat_id})
            return
        successor.role = MemberRole.OWNER
    await db.delete(target)
    await db.flush()
    await refresh_member_count(db, chat)
    await db.commit()
    await publish_to_users([user_id], "chat.removed", {"chat_id": chat.id})
    if chat.type == ChatType.GROUP:
        await post_system_message(db, chat, viewer.id, "member_left" if leaving else "member_removed", user_ids=[user_id])
    else:
        await notify_chat_updated(db, chat.id)


@router.post("/{chat_id}/invite-link", response_model=ChatOut)
async def regenerate_invite_link(chat_id: int, viewer: ViewerDep, db: DbDep) -> ChatOut:
    chat, member = await require_member(db, chat_id, viewer.id)
    ensure_group_like(chat)
    require_admin(member)
    chat.invite_hash = new_invite_hash()
    await db.commit()
    return await chat_out(db, viewer.id, chat)


@router.post("/{chat_id}/pin", response_model=ChatOut)
async def pin_message(chat_id: int, body: PinMessageIn, viewer: ViewerDep, db: DbDep) -> ChatOut:
    chat, member = await require_member(db, chat_id, viewer.id)
    if chat.type in (ChatType.GROUP, ChatType.CHANNEL):
        require_admin(member)
    if body.message_id is not None:
        exists_in_chat = await db.scalar(
            select(Message.id).where(Message.id == body.message_id, Message.chat_id == chat.id, Message.is_deleted.is_(False))
        )
        if exists_in_chat is None:
            raise not_found("MESSAGE_NOT_FOUND")
    chat.pinned_message_id = body.message_id
    await db.commit()
    if body.message_id is not None and chat.type == ChatType.GROUP:
        await post_system_message(db, chat, viewer.id, "message_pinned", message_id=body.message_id)
    else:
        await notify_chat_updated(db, chat.id)
    return await chat_out(db, viewer.id, chat)


@router.get("/{chat_id}/messages", response_model=list[MessageOut])
async def list_messages(
    chat_id: int,
    viewer: ViewerDep,
    db: DbDep,
    before_id: int | None = None,
    after_id: int | None = None,
    around_id: int | None = None,
    limit: int = Query(default=50, ge=1, le=200),
) -> list[MessageOut]:
    """History page in ascending id order. Use `before_id` to scroll up, `after_id` to catch up after reconnect."""
    chat, member = await require_readable(db, chat_id, viewer.id)
    base = select(Message).where(Message.chat_id == chat.id, visible_messages_filter(viewer.id, member))
    if around_id is not None:
        half = limit // 2
        older = list(await db.scalars(base.where(Message.id < around_id).order_by(Message.id.desc()).limit(half)))
        newer = list(await db.scalars(base.where(Message.id >= around_id).order_by(Message.id).limit(limit - half)))
        rows = list(reversed(older)) + newer
    elif after_id is not None:
        rows = list(await db.scalars(base.where(Message.id > after_id).order_by(Message.id).limit(limit)))
    else:
        query = base.order_by(Message.id.desc()).limit(limit)
        if before_id is not None:
            query = query.where(Message.id < before_id)
        rows = list(reversed(list(await db.scalars(query))))
    return await messages_out(db, viewer.id, rows)


@router.get("/{chat_id}/messages/search", response_model=list[MessageOut])
async def search_in_chat(
    chat_id: int,
    viewer: ViewerDep,
    db: DbDep,
    q: str = Query(min_length=1, max_length=128),
    type: str | None = Query(default=None, description="filter by message type, e.g. photo"),
    limit: int = Query(default=50, ge=1, le=100),
) -> list[MessageOut]:
    chat, member = await require_readable(db, chat_id, viewer.id)
    query = (
        select(Message)
        .where(Message.chat_id == chat.id, visible_messages_filter(viewer.id, member), Message.text.ilike(f"%{q}%"))
        .order_by(Message.id.desc())
        .limit(limit)
    )
    if type:
        query = query.where(Message.type == type)
    return await messages_out(db, viewer.id, list(await db.scalars(query)))


@router.get("/{chat_id}/media", response_model=list[MessageOut])
async def shared_media(
    chat_id: int,
    viewer: ViewerDep,
    db: DbDep,
    kind: str = Query(pattern="^(media|file|voice|link)$"),
    before_id: int | None = None,
    limit: int = Query(default=60, ge=1, le=200),
) -> list[MessageOut]:
    """Shared media tab on the profile screen."""
    chat, member = await require_readable(db, chat_id, viewer.id)
    types = {
        "media": ("photo", "video"),
        "file": ("file", "audio"),
        "voice": ("voice",),
    }
    query = select(Message).where(Message.chat_id == chat.id, visible_messages_filter(viewer.id, member))
    if kind == "link":
        query = query.where(Message.text.op("~*")(r"https?://"))
    else:
        query = query.where(Message.type.in_(types[kind]))
    if before_id is not None:
        query = query.where(Message.id < before_id)
    rows = list(await db.scalars(query.order_by(Message.id.desc()).limit(limit)))
    return await messages_out(db, viewer.id, rows)


@router.post("/{chat_id}/read", status_code=status.HTTP_204_NO_CONTENT)
async def mark_read(chat_id: int, body: ReadIn, viewer: ViewerDep, db: DbDep) -> None:
    chat, member = await require_member(db, chat_id, viewer.id)
    target = min(body.message_id, chat.last_message_id or 0)
    if target <= member.last_read_message_id:
        return
    previous = member.last_read_message_id
    member.last_read_message_id = target
    if chat.type == ChatType.CHANNEL:
        await db.execute(
            update(Message)
            .where(Message.chat_id == chat.id, Message.id > previous, Message.id <= target)
            .values(views=Message.views + 1)
        )
    await db.commit()
    if chat.type == ChatType.CHANNEL:
        await publish_to_users([viewer.id], "chat.read", {"chat_id": chat.id, "user_id": viewer.id, "message_id": target})
    else:
        await publish_to_users(
            await member_ids(db, chat.id), "chat.read", {"chat_id": chat.id, "user_id": viewer.id, "message_id": target}
        )


@router.post("/{chat_id}/clear", status_code=status.HTTP_204_NO_CONTENT)
async def clear_history(chat_id: int, body: ClearHistoryIn, viewer: ViewerDep, db: DbDep) -> None:
    chat, member = await require_member(db, chat_id, viewer.id)
    last_id = chat.last_message_id or 0
    if body.for_everyone:
        if chat.type in (ChatType.GROUP, ChatType.CHANNEL):
            raise bad_request("USE_DELETE_CHAT")
        await db.execute(
            update(ChatMember).where(ChatMember.chat_id == chat.id).values(cleared_before_message_id=last_id)
        )
        recipients = await member_ids(db, chat.id)
    else:
        member.cleared_before_message_id = last_id
        recipients = [viewer.id]
    await db.execute(delete(HiddenMessage).where(HiddenMessage.user_id.in_(recipients), HiddenMessage.message_id <= last_id))
    await db.commit()
    await publish_to_users(recipients, "chat.cleared", {"chat_id": chat.id, "before_id": last_id})


@router.delete("/{chat_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_chat(chat_id: int, viewer: ViewerDep, db: DbDep) -> None:
    """Owner deletes a group/channel for everyone. For private chats: clears and hides it for the viewer."""
    chat, member = await require_member(db, chat_id, viewer.id)
    if chat.type in (ChatType.GROUP, ChatType.CHANNEL):
        if member.role != MemberRole.OWNER:
            raise forbidden("OWNER_REQUIRED")
        recipients = await member_ids(db, chat.id)
        await db.delete(chat)
        await db.commit()
        await publish_to_users(recipients, "chat.removed", {"chat_id": chat_id})
        return
    member.cleared_before_message_id = chat.last_message_id or 0
    member.is_pinned = False
    await db.commit()
    await publish_to_users([viewer.id], "chat.removed", {"chat_id": chat_id})


@router.get("/{chat_id}/common", response_model=list[ChatOut])
async def common_groups(chat_id: int, viewer: ViewerDep, db: DbDep) -> list[ChatOut]:
    """Groups shared with the peer of a private chat."""
    chat, _ = await require_member(db, chat_id, viewer.id)
    if chat.type != ChatType.PRIVATE or not chat.private_key:
        return []
    low, high = (int(x) for x in chat.private_key.split(":"))
    peer_id = high if low == viewer.id else low
    mine = select(ChatMember.chat_id).where(ChatMember.user_id == viewer.id)
    rows = list(
        await db.scalars(
            select(Chat)
            .join(ChatMember, ChatMember.chat_id == Chat.id)
            .where(ChatMember.user_id == peer_id, Chat.id.in_(mine), Chat.type == ChatType.GROUP)
            .order_by(Chat.updated_at.desc())
            .limit(100)
        )
    )
    return await chats_out(db, viewer.id, rows)
