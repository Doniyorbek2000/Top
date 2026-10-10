from datetime import datetime
from enum import StrEnum

from sqlalchemy import (
    BigInteger,
    Boolean,
    DateTime,
    Enum,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import ARRAY, JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base


class ChatType(StrEnum):
    PRIVATE = "private"
    GROUP = "group"
    CHANNEL = "channel"
    SAVED = "saved"


class MemberRole(StrEnum):
    OWNER = "owner"
    ADMIN = "admin"
    MEMBER = "member"


class MessageType(StrEnum):
    TEXT = "text"
    PHOTO = "photo"
    VIDEO = "video"
    VOICE = "voice"
    AUDIO = "audio"
    FILE = "file"
    STICKER = "sticker"
    LOCATION = "location"
    CONTACT = "contact"
    POLL = "poll"
    SYSTEM = "system"


class Visibility(StrEnum):
    EVERYBODY = "everybody"
    CONTACTS = "contacts"
    NOBODY = "nobody"


def _enum(enum_cls: type[StrEnum], name: str) -> Enum:
    return Enum(enum_cls, name=name, values_callable=lambda cls: [m.value for m in cls])


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    phone: Mapped[str | None] = mapped_column(String(20), unique=True)
    username: Mapped[str | None] = mapped_column(String(32))
    first_name: Mapped[str] = mapped_column(String(64), default="")
    last_name: Mapped[str] = mapped_column(String(64), default="")
    bio: Mapped[str] = mapped_column(String(140), default="")
    avatar_media_id: Mapped[int | None] = mapped_column(ForeignKey("media.id", ondelete="SET NULL", use_alter=True))
    is_bot: Mapped[bool] = mapped_column(Boolean, default=False)
    last_seen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_seen_visibility: Mapped[Visibility] = mapped_column(_enum(Visibility, "visibility"), default=Visibility.EVERYBODY)
    phone_visibility: Mapped[Visibility] = mapped_column(_enum(Visibility, "visibility"), default=Visibility.CONTACTS)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (
        Index("uq_users_username_lower", func.lower(username), unique=True, postgresql_where=username.isnot(None)),
        Index("ix_users_name_trgm", "first_name", "last_name", postgresql_using="gin",
              postgresql_ops={"first_name": "gin_trgm_ops", "last_name": "gin_trgm_ops"}),
    )


class AuthSession(Base):
    """A logged-in device. Refresh tokens are bound to a session so devices can be terminated individually."""

    __tablename__ = "auth_sessions"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    refresh_token_hash: Mapped[str] = mapped_column(String(64), unique=True)
    device_name: Mapped[str] = mapped_column(String(128), default="")
    platform: Mapped[str] = mapped_column(String(32), default="")
    app_version: Mapped[str] = mapped_column(String(32), default="")
    ip: Mapped[str] = mapped_column(String(64), default="")
    push_token: Mapped[str | None] = mapped_column(String(512))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    last_active_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class Contact(Base):
    __tablename__ = "contacts"

    owner_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    contact_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    first_name: Mapped[str] = mapped_column(String(64), default="")
    last_name: Mapped[str] = mapped_column(String(64), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class Block(Base):
    __tablename__ = "blocks"

    owner_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    blocked_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class Media(Base):
    __tablename__ = "media"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    owner_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    kind: Mapped[str] = mapped_column(String(16))
    mime_type: Mapped[str] = mapped_column(String(128))
    file_name: Mapped[str] = mapped_column(String(255), default="")
    size: Mapped[int] = mapped_column(BigInteger)
    storage_key: Mapped[str] = mapped_column(String(255), unique=True)
    thumb_key: Mapped[str | None] = mapped_column(String(255))
    width: Mapped[int | None] = mapped_column(Integer)
    height: Mapped[int | None] = mapped_column(Integer)
    duration_ms: Mapped[int | None] = mapped_column(Integer)
    waveform: Mapped[list[int] | None] = mapped_column(ARRAY(Integer))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class Chat(Base):
    __tablename__ = "chats"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    type: Mapped[ChatType] = mapped_column(_enum(ChatType, "chat_type"))
    title: Mapped[str] = mapped_column(String(128), default="")
    description: Mapped[str] = mapped_column(String(255), default="")
    username: Mapped[str | None] = mapped_column(String(32))
    avatar_media_id: Mapped[int | None] = mapped_column(ForeignKey("media.id", ondelete="SET NULL"))
    invite_hash: Mapped[str | None] = mapped_column(String(32), unique=True)
    # For private chats: canonical "min:max" pair to guarantee a single chat per user pair.
    private_key: Mapped[str | None] = mapped_column(String(64), unique=True)
    created_by: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    pinned_message_id: Mapped[int | None] = mapped_column(BigInteger)
    last_message_id: Mapped[int | None] = mapped_column(BigInteger)
    members_can_send: Mapped[bool] = mapped_column(Boolean, default=True)
    slow_mode_seconds: Mapped[int] = mapped_column(Integer, default=0)
    member_count: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    __table_args__ = (
        Index("uq_chats_username_lower", func.lower(username), unique=True, postgresql_where=username.isnot(None)),
        Index("ix_chats_title_trgm", "title", postgresql_using="gin", postgresql_ops={"title": "gin_trgm_ops"}),
    )


class ChatMember(Base):
    __tablename__ = "chat_members"

    chat_id: Mapped[int] = mapped_column(ForeignKey("chats.id", ondelete="CASCADE"), primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    role: Mapped[MemberRole] = mapped_column(_enum(MemberRole, "member_role"), default=MemberRole.MEMBER)
    last_read_message_id: Mapped[int] = mapped_column(BigInteger, default=0)
    # Messages with id <= cleared_before are hidden for this member ("clear history").
    cleared_before_message_id: Mapped[int] = mapped_column(BigInteger, default=0)
    muted_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    is_pinned: Mapped[bool] = mapped_column(Boolean, default=False)
    pin_order: Mapped[int] = mapped_column(Integer, default=0)
    is_archived: Mapped[bool] = mapped_column(Boolean, default=False)
    draft: Mapped[str] = mapped_column(Text, default="")
    joined_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    chat: Mapped[Chat] = relationship(lazy="joined")

    __table_args__ = (Index("ix_chat_members_user", "user_id"),)


class Message(Base):
    __tablename__ = "messages"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    chat_id: Mapped[int] = mapped_column(ForeignKey("chats.id", ondelete="CASCADE"))
    sender_id: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    client_id: Mapped[str | None] = mapped_column(String(64))
    type: Mapped[MessageType] = mapped_column(_enum(MessageType, "message_type"), default=MessageType.TEXT)
    text: Mapped[str] = mapped_column(Text, default="")
    entities: Mapped[list[dict] | None] = mapped_column(JSONB)
    media_id: Mapped[int | None] = mapped_column(ForeignKey("media.id", ondelete="SET NULL"))
    extra: Mapped[dict | None] = mapped_column(JSONB)
    reply_to_id: Mapped[int | None] = mapped_column(BigInteger)
    forward_from_user_id: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    forward_from_chat_id: Mapped[int | None] = mapped_column(ForeignKey("chats.id", ondelete="SET NULL"))
    forward_from_message_id: Mapped[int | None] = mapped_column(BigInteger)
    forward_sender_name: Mapped[str | None] = mapped_column(String(128))
    views: Mapped[int] = mapped_column(Integer, default=0)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False)
    edited_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    media: Mapped[Media | None] = relationship(lazy="joined")

    __table_args__ = (
        Index("ix_messages_chat_id_id", "chat_id", "id"),
        Index("ix_messages_text_trgm", "text", postgresql_using="gin", postgresql_ops={"text": "gin_trgm_ops"}),
        UniqueConstraint("sender_id", "client_id", name="uq_messages_sender_client"),
    )


class HiddenMessage(Base):
    """Per-user "delete for me"."""

    __tablename__ = "hidden_messages"

    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    message_id: Mapped[int] = mapped_column(ForeignKey("messages.id", ondelete="CASCADE"), primary_key=True)


class Reaction(Base):
    __tablename__ = "reactions"

    message_id: Mapped[int] = mapped_column(ForeignKey("messages.id", ondelete="CASCADE"), primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    emoji: Mapped[str] = mapped_column(String(16), primary_key=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class PollVote(Base):
    __tablename__ = "poll_votes"

    message_id: Mapped[int] = mapped_column(ForeignKey("messages.id", ondelete="CASCADE"), primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    option_index: Mapped[int] = mapped_column(Integer, primary_key=True)


class ChatFolder(Base):
    """User-defined chat folders (Plus Messenger / Telegram style tabs)."""

    __tablename__ = "chat_folders"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    owner_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    title: Mapped[str] = mapped_column(String(32))
    emoji: Mapped[str] = mapped_column(String(16), default="")
    position: Mapped[int] = mapped_column(Integer, default=0)
    include_types: Mapped[list[str]] = mapped_column(ARRAY(String(16)), default=list)
    include_chat_ids: Mapped[list[int]] = mapped_column(ARRAY(BigInteger), default=list)
    exclude_chat_ids: Mapped[list[int]] = mapped_column(ARRAY(BigInteger), default=list)
    exclude_muted: Mapped[bool] = mapped_column(Boolean, default=False)
    exclude_read: Mapped[bool] = mapped_column(Boolean, default=False)
    exclude_archived: Mapped[bool] = mapped_column(Boolean, default=True)
