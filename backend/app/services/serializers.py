"""Batch serializers that turn ORM rows into viewer-specific API payloads with a fixed number of queries."""

from collections import defaultdict
from collections.abc import Iterable, Sequence
from datetime import timedelta

from sqlalchemy import and_, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.models import (
    Block,
    Chat,
    ChatMember,
    ChatType,
    Contact,
    Media,
    MemberRole,
    Message,
    MessageType,
    PollVote,
    Reaction,
    User,
    Visibility,
)
from app.realtime import online_user_ids, utcnow
from app.schemas import (
    ChatOut,
    ForwardInfo,
    MediaOut,
    MeOut,
    MessageOut,
    PollResults,
    ReactionCount,
    ReplyPreview,
    UserOut,
)


def media_out(media: Media | None) -> MediaOut | None:
    if media is None:
        return None
    base = get_settings().public_base_url.rstrip("/")
    return MediaOut(
        id=media.id,
        kind=media.kind,
        mime_type=media.mime_type,
        file_name=media.file_name,
        size=media.size,
        width=media.width,
        height=media.height,
        duration_ms=media.duration_ms,
        waveform=media.waveform,
        url=f"{base}/media/{media.id}",
        thumb_url=f"{base}/media/{media.id}?thumb=1" if media.thumb_key else None,
    )


async def _load_media(db: AsyncSession, ids: Iterable[int | None]) -> dict[int, Media]:
    wanted = {i for i in ids if i is not None}
    if not wanted:
        return {}
    rows = await db.scalars(select(Media).where(Media.id.in_(wanted)))
    return {m.id: m for m in rows}


def _last_seen_hint(user: User) -> str | None:
    if user.last_seen_at is None:
        return "long_ago"
    age = utcnow() - user.last_seen_at
    if age < timedelta(days=3):
        return "recently"
    if age < timedelta(days=7):
        return "within_week"
    if age < timedelta(days=30):
        return "within_month"
    return "long_ago"


async def users_out(db: AsyncSession, viewer_id: int, users: Sequence[User]) -> list[UserOut]:
    if not users:
        return []
    ids = [u.id for u in users]

    contacts_of_viewer = {
        c.contact_id: c
        for c in await db.scalars(select(Contact).where(Contact.owner_id == viewer_id, Contact.contact_id.in_(ids)))
    }
    # Users who have the viewer in *their* contacts (for "contacts only" privacy rules).
    viewer_in_their_contacts = set(
        await db.scalars(select(Contact.owner_id).where(Contact.contact_id == viewer_id, Contact.owner_id.in_(ids)))
    )
    blocked_by_viewer = set(
        await db.scalars(select(Block.blocked_id).where(Block.owner_id == viewer_id, Block.blocked_id.in_(ids)))
    )
    viewer_blocked_by = set(
        await db.scalars(select(Block.owner_id).where(Block.blocked_id == viewer_id, Block.owner_id.in_(ids)))
    )
    media = await _load_media(db, (u.avatar_media_id for u in users))
    online = await online_user_ids(ids)

    def allowed(user: User, rule: Visibility) -> bool:
        if user.id == viewer_id:
            return True
        if user.id in viewer_blocked_by:
            return False
        if rule == Visibility.EVERYBODY:
            return True
        if rule == Visibility.CONTACTS:
            return user.id in viewer_in_their_contacts
        return False

    result: list[UserOut] = []
    for user in users:
        show_last_seen = allowed(user, user.last_seen_visibility)
        contact = contacts_of_viewer.get(user.id)
        result.append(
            UserOut(
                id=user.id,
                username=user.username,
                first_name=user.first_name,
                last_name=user.last_name,
                bio=user.bio,
                phone=user.phone if (allowed(user, user.phone_visibility) or contact is not None) else None,
                avatar=None if user.id in viewer_blocked_by else media_out(media.get(user.avatar_media_id or -1)),
                is_bot=user.is_bot,
                online=show_last_seen and user.id in online,
                last_seen_at=user.last_seen_at if show_last_seen else None,
                last_seen_hint=None if show_last_seen else _last_seen_hint(user),
                is_contact=contact is not None,
                is_blocked=user.id in blocked_by_viewer,
                contact_first_name=contact.first_name if contact else None,
                contact_last_name=contact.last_name if contact else None,
            )
        )
    return result


async def user_out(db: AsyncSession, viewer_id: int, user: User) -> UserOut:
    return (await users_out(db, viewer_id, [user]))[0]


async def me_out(db: AsyncSession, user: User) -> MeOut:
    base = await user_out(db, user.id, user)
    return MeOut(
        **base.model_dump(),
        last_seen_visibility=user.last_seen_visibility,
        phone_visibility=user.phone_visibility,
    )


async def messages_out(db: AsyncSession, viewer_id: int, messages: Sequence[Message]) -> list[MessageOut]:
    if not messages:
        return []
    ids = [m.id for m in messages]

    reply_ids = {m.reply_to_id for m in messages if m.reply_to_id}
    replies: dict[int, Message] = {}
    if reply_ids:
        replies = {r.id: r for r in await db.scalars(select(Message).where(Message.id.in_(reply_ids)))}

    reaction_rows = await db.execute(
        select(Reaction.message_id, Reaction.emoji, func.count(), func.bool_or(Reaction.user_id == viewer_id))
        .where(Reaction.message_id.in_(ids))
        .group_by(Reaction.message_id, Reaction.emoji)
        .order_by(Reaction.message_id, func.count().desc(), func.min(Reaction.created_at))
    )
    reactions: dict[int, list[ReactionCount]] = defaultdict(list)
    for message_id, emoji, count, me in reaction_rows:
        reactions[message_id].append(ReactionCount(emoji=emoji, count=count, me=bool(me)))

    poll_ids = [m.id for m in messages if m.type == MessageType.POLL]
    polls: dict[int, PollResults] = {}
    if poll_ids:
        polls = await poll_results(db, viewer_id, [m for m in messages if m.type == MessageType.POLL])

    result: list[MessageOut] = []
    for m in messages:
        reply = replies.get(m.reply_to_id) if m.reply_to_id else None
        forward = None
        if m.forward_from_user_id or m.forward_from_chat_id or m.forward_sender_name:
            forward = ForwardInfo(
                from_user_id=m.forward_from_user_id,
                from_chat_id=m.forward_from_chat_id,
                from_message_id=m.forward_from_message_id,
                sender_name=m.forward_sender_name,
            )
        result.append(
            MessageOut(
                id=m.id,
                chat_id=m.chat_id,
                sender_id=m.sender_id,
                client_id=m.client_id,
                type=m.type,
                text=m.text,
                entities=m.entities,
                media=media_out(m.media),
                extra=m.extra,
                reply_to=ReplyPreview(
                    id=reply.id,
                    sender_id=reply.sender_id,
                    type=reply.type,
                    text=reply.text[:200],
                    is_deleted=reply.is_deleted,
                )
                if reply
                else None,
                forward=forward,
                views=m.views,
                reactions=reactions.get(m.id, []),
                poll=polls.get(m.id),
                edited_at=m.edited_at,
                created_at=m.created_at,
            )
        )
    return result


async def poll_results(db: AsyncSession, viewer_id: int, poll_messages: Sequence[Message]) -> dict[int, PollResults]:
    ids = [m.id for m in poll_messages]
    counts_rows = await db.execute(
        select(PollVote.message_id, PollVote.option_index, func.count())
        .where(PollVote.message_id.in_(ids))
        .group_by(PollVote.message_id, PollVote.option_index)
    )
    voters_rows = await db.execute(
        select(PollVote.message_id, func.count(func.distinct(PollVote.user_id)))
        .where(PollVote.message_id.in_(ids))
        .group_by(PollVote.message_id)
    )
    mine_rows = await db.execute(
        select(PollVote.message_id, PollVote.option_index).where(
            PollVote.message_id.in_(ids), PollVote.user_id == viewer_id
        )
    )
    counts: dict[int, dict[int, int]] = defaultdict(dict)
    for message_id, option_index, count in counts_rows:
        counts[message_id][option_index] = count
    voters = dict(voters_rows.all())
    mine: dict[int, list[int]] = defaultdict(list)
    for message_id, option_index in mine_rows:
        mine[message_id].append(option_index)

    result: dict[int, PollResults] = {}
    for m in poll_messages:
        options = (m.extra or {}).get("options", [])
        result[m.id] = PollResults(
            counts=[counts[m.id].get(i, 0) for i in range(len(options))],
            total_voters=voters.get(m.id, 0),
            my_votes=sorted(mine.get(m.id, [])),
        )
    return result


async def message_out(db: AsyncSession, viewer_id: int, message: Message) -> MessageOut:
    return (await messages_out(db, viewer_id, [message]))[0]


def invite_link(chat: Chat) -> str | None:
    if not chat.invite_hash:
        return None
    return f"{get_settings().public_base_url.rstrip('/')}/join/{chat.invite_hash}"


async def chats_out(
    db: AsyncSession,
    viewer_id: int,
    chats: Sequence[Chat],
    memberships: dict[int, ChatMember] | None = None,
) -> list[ChatOut]:
    if not chats:
        return []
    chat_ids = [c.id for c in chats]

    if memberships is None:
        memberships = {
            m.chat_id: m
            for m in await db.scalars(
                select(ChatMember).where(ChatMember.user_id == viewer_id, ChatMember.chat_id.in_(chat_ids))
            )
        }

    # Peers of private chats.
    private_ids = [c.id for c in chats if c.type == ChatType.PRIVATE]
    peer_by_chat: dict[int, User] = {}
    if private_ids:
        rows = await db.execute(
            select(ChatMember.chat_id, User)
            .join(User, User.id == ChatMember.user_id)
            .where(ChatMember.chat_id.in_(private_ids), ChatMember.user_id != viewer_id)
        )
        peer_by_chat = {chat_id: user for chat_id, user in rows}
    peers = await users_out(db, viewer_id, list({u.id: u for u in peer_by_chat.values()}.values()))
    peer_out_by_id = {p.id: p for p in peers}

    # Last messages, respecting per-member clear-history. Hidden ("delete for me") messages are rare,
    # so the chat list uses the chat's last message and the history view filters precisely.
    last_ids = [
        c.last_message_id
        for c in chats
        if c.last_message_id
        and c.last_message_id > (memberships[c.id].cleared_before_message_id if c.id in memberships else 0)
    ]
    last_messages: dict[int, Message] = {}
    if last_ids:
        last_messages = {
            m.chat_id: m for m in await db.scalars(select(Message).where(Message.id.in_(last_ids)))
        }
    last_out = {m.chat_id: m for m in await messages_out(db, viewer_id, list(last_messages.values()))}

    # Unread counts in one grouped query.
    unread: dict[int, int] = {}
    member_chat_ids = [cid for cid in chat_ids if cid in memberships]
    if member_chat_ids:
        rows = await db.execute(
            select(Message.chat_id, func.count())
            .join(
                ChatMember,
                and_(ChatMember.chat_id == Message.chat_id, ChatMember.user_id == viewer_id),
            )
            .where(
                Message.chat_id.in_(member_chat_ids),
                Message.id > ChatMember.last_read_message_id,
                Message.id > ChatMember.cleared_before_message_id,
                Message.is_deleted.is_(False),
                (Message.sender_id != viewer_id) | Message.sender_id.is_(None),
            )
            .group_by(Message.chat_id)
        )
        unread = dict(rows.all())

    # Highest message id read by anyone else (drives the double-check mark on outgoing messages).
    outbox: dict[int, int] = {}
    non_channel = [c.id for c in chats if c.type in (ChatType.PRIVATE, ChatType.GROUP) and c.id in memberships]
    if non_channel:
        rows = await db.execute(
            select(ChatMember.chat_id, func.max(ChatMember.last_read_message_id))
            .where(ChatMember.chat_id.in_(non_channel), ChatMember.user_id != viewer_id)
            .group_by(ChatMember.chat_id)
        )
        outbox = {cid: value or 0 for cid, value in rows}

    media = await _load_media(db, (c.avatar_media_id for c in chats))

    result: list[ChatOut] = []
    for chat in chats:
        member = memberships.get(chat.id)
        peer_user = peer_by_chat.get(chat.id)
        peer = peer_out_by_id.get(peer_user.id) if peer_user else None
        title = chat.title
        if chat.type == ChatType.PRIVATE and peer is not None:
            title = " ".join(
                p for p in ((peer.contact_first_name or peer.first_name), (peer.contact_last_name or peer.last_name)) if p
            ) or (peer.username or "")
        is_admin = member is not None and member.role in (MemberRole.OWNER, MemberRole.ADMIN)
        result.append(
            ChatOut(
                id=chat.id,
                type=chat.type,
                title=title,
                description=chat.description,
                username=chat.username,
                avatar=peer.avatar if chat.type == ChatType.PRIVATE and peer else media_out(media.get(chat.avatar_media_id or -1)),
                member_count=chat.member_count,
                my_role=member.role if member else None,
                is_member=member is not None,
                peer=peer,
                last_message=last_out.get(chat.id),
                unread_count=unread.get(chat.id, 0),
                last_read_message_id=member.last_read_message_id if member else 0,
                read_outbox_max_id=(chat.last_message_id or 0) if chat.type == ChatType.SAVED else outbox.get(chat.id, 0),
                is_pinned=member.is_pinned if member else False,
                pin_order=member.pin_order if member else 0,
                is_archived=member.is_archived if member else False,
                muted_until=member.muted_until if member else None,
                draft=member.draft if member else "",
                pinned_message_id=chat.pinned_message_id,
                invite_link=invite_link(chat) if is_admin else None,
                members_can_send=chat.members_can_send,
                slow_mode_seconds=chat.slow_mode_seconds,
                created_at=chat.created_at,
                updated_at=chat.updated_at,
            )
        )
    return result


async def chat_out(db: AsyncSession, viewer_id: int, chat: Chat) -> ChatOut:
    return (await chats_out(db, viewer_id, [chat]))[0]
