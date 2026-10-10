import re
from datetime import datetime
from typing import Annotated, Any, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, field_validator, model_validator

from app.models import ChatType, MemberRole, MessageType, Visibility

USERNAME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9_]{3,31}$")
PHONE_RE = re.compile(r"^\+[1-9]\d{6,14}$")

Username = Annotated[str, StringConstraints(strip_whitespace=True, max_length=32)]


def normalize_phone(raw: str) -> str:
    digits = re.sub(r"[^\d+]", "", raw.strip())
    if not digits.startswith("+"):
        digits = "+" + digits
    if not PHONE_RE.match(digits):
        raise ValueError("invalid phone number, use international format: +998901234567")
    return digits


def validate_username(value: str | None) -> str | None:
    if value is None or value == "":
        return None
    if not USERNAME_RE.match(value):
        raise ValueError("username must be 4-32 chars: letters, digits, underscore; start with a letter")
    return value


class ApiModel(BaseModel):
    model_config = ConfigDict(from_attributes=True)


# ---------- auth ----------


class SendCodeIn(BaseModel):
    phone: str

    @field_validator("phone")
    @classmethod
    def _phone(cls, v: str) -> str:
        return normalize_phone(v)


class SendCodeOut(BaseModel):
    phone: str
    code_length: int
    expires_in: int
    resend_after: int


class VerifyCodeIn(BaseModel):
    phone: str
    code: Annotated[str, StringConstraints(strip_whitespace=True, min_length=4, max_length=8)]
    first_name: Annotated[str, StringConstraints(strip_whitespace=True, max_length=64)] = ""
    last_name: Annotated[str, StringConstraints(strip_whitespace=True, max_length=64)] = ""
    device_name: Annotated[str, StringConstraints(max_length=128)] = ""
    platform: Annotated[str, StringConstraints(max_length=32)] = ""
    app_version: Annotated[str, StringConstraints(max_length=32)] = ""

    @field_validator("phone")
    @classmethod
    def _phone(cls, v: str) -> str:
        return normalize_phone(v)


class RefreshIn(BaseModel):
    refresh_token: str


class PushTokenIn(BaseModel):
    push_token: Annotated[str, StringConstraints(max_length=512)] | None


class SessionOut(ApiModel):
    id: int
    device_name: str
    platform: str
    app_version: str
    ip: str
    created_at: datetime
    last_active_at: datetime
    is_current: bool = False


# ---------- media ----------


class MediaOut(ApiModel):
    id: int
    kind: str
    mime_type: str
    file_name: str
    size: int
    width: int | None = None
    height: int | None = None
    duration_ms: int | None = None
    waveform: list[int] | None = None
    url: str
    thumb_url: str | None = None


# ---------- users ----------


class UserOut(BaseModel):
    id: int
    username: str | None
    first_name: str
    last_name: str
    bio: str
    phone: str | None
    avatar: MediaOut | None
    is_bot: bool
    online: bool
    last_seen_at: datetime | None
    # Coarse hint when exact last seen is hidden: "recently" | "within_week" | "long_ago" | None
    last_seen_hint: str | None
    is_contact: bool
    is_blocked: bool
    contact_first_name: str | None = None
    contact_last_name: str | None = None


class MeOut(UserOut):
    last_seen_visibility: Visibility
    phone_visibility: Visibility


class UpdateMeIn(BaseModel):
    first_name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=64)] | None = None
    last_name: Annotated[str, StringConstraints(strip_whitespace=True, max_length=64)] | None = None
    bio: Annotated[str, StringConstraints(strip_whitespace=True, max_length=140)] | None = None
    username: Username | None = None
    avatar_media_id: int | None = None
    remove_avatar: bool = False
    last_seen_visibility: Visibility | None = None
    phone_visibility: Visibility | None = None

    _check_username = field_validator("username")(lambda cls, v: validate_username(v) if v else v)


class UsernameCheckOut(BaseModel):
    username: str
    available: bool


# ---------- contacts ----------


class ContactImportItem(BaseModel):
    phone: str
    first_name: Annotated[str, StringConstraints(strip_whitespace=True, max_length=64)] = ""
    last_name: Annotated[str, StringConstraints(strip_whitespace=True, max_length=64)] = ""


class ContactImportIn(BaseModel):
    contacts: Annotated[list[ContactImportItem], Field(max_length=5000)]


class ContactAddIn(BaseModel):
    user_id: int
    first_name: Annotated[str, StringConstraints(strip_whitespace=True, max_length=64)] = ""
    last_name: Annotated[str, StringConstraints(strip_whitespace=True, max_length=64)] = ""


# ---------- messages ----------


class ReactionCount(BaseModel):
    emoji: str
    count: int
    me: bool = False


class ReplyPreview(BaseModel):
    id: int
    sender_id: int | None
    type: MessageType
    text: str
    is_deleted: bool


class ForwardInfo(BaseModel):
    from_user_id: int | None
    from_chat_id: int | None
    from_message_id: int | None
    sender_name: str | None


class PollResults(BaseModel):
    counts: list[int]
    total_voters: int
    my_votes: list[int]


class MessageOut(BaseModel):
    id: int
    chat_id: int
    sender_id: int | None
    client_id: str | None
    type: MessageType
    text: str
    entities: list[dict[str, Any]] | None
    media: MediaOut | None
    extra: dict[str, Any] | None
    reply_to: ReplyPreview | None
    forward: ForwardInfo | None
    views: int
    reactions: list[ReactionCount]
    poll: PollResults | None
    edited_at: datetime | None
    created_at: datetime


class PollIn(BaseModel):
    question: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=255)]
    options: Annotated[list[Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=100)]], Field(min_length=2, max_length=10)]
    multiple_choice: bool = False
    anonymous: bool = True


class LocationIn(BaseModel):
    latitude: Annotated[float, Field(ge=-90, le=90)]
    longitude: Annotated[float, Field(ge=-180, le=180)]


class ContactCardIn(BaseModel):
    user_id: int | None = None
    phone: str
    first_name: str = ""
    last_name: str = ""


class SendMessageIn(BaseModel):
    client_id: Annotated[str, StringConstraints(max_length=64)] | None = None
    type: MessageType = MessageType.TEXT
    text: Annotated[str, StringConstraints(max_length=4096)] = ""
    entities: list[dict[str, Any]] | None = None
    media_id: int | None = None
    reply_to_id: int | None = None
    poll: PollIn | None = None
    location: LocationIn | None = None
    contact: ContactCardIn | None = None
    silent: bool = False

    @model_validator(mode="after")
    def _check_payload(self) -> "SendMessageIn":
        media_types = {MessageType.PHOTO, MessageType.VIDEO, MessageType.VOICE, MessageType.AUDIO,
                       MessageType.FILE, MessageType.STICKER}
        if self.type == MessageType.SYSTEM:
            raise ValueError("system messages cannot be sent by clients")
        if self.type == MessageType.TEXT and not self.text.strip():
            raise ValueError("text must not be empty")
        if self.type in media_types and self.media_id is None:
            raise ValueError("media_id is required for media messages")
        if self.type == MessageType.POLL and self.poll is None:
            raise ValueError("poll is required for poll messages")
        if self.type == MessageType.LOCATION and self.location is None:
            raise ValueError("location is required for location messages")
        if self.type == MessageType.CONTACT and self.contact is None:
            raise ValueError("contact is required for contact messages")
        return self


class EditMessageIn(BaseModel):
    text: Annotated[str, StringConstraints(max_length=4096)]
    entities: list[dict[str, Any]] | None = None


class DeleteMessagesIn(BaseModel):
    message_ids: Annotated[list[int], Field(min_length=1, max_length=100)]
    for_everyone: bool = False


class ForwardMessagesIn(BaseModel):
    from_chat_id: int
    message_ids: Annotated[list[int], Field(min_length=1, max_length=100)]
    to_chat_ids: Annotated[list[int], Field(min_length=1, max_length=20)]
    hide_sender: bool = False


class ReactIn(BaseModel):
    emoji: Annotated[str, StringConstraints(min_length=1, max_length=16)] | None


class VoteIn(BaseModel):
    options: Annotated[list[int], Field(max_length=10)]


class ReadIn(BaseModel):
    message_id: int


# ---------- chats ----------


class ChatOut(BaseModel):
    id: int
    type: ChatType
    title: str
    description: str
    username: str | None
    avatar: MediaOut | None
    member_count: int
    my_role: MemberRole | None
    is_member: bool
    peer: UserOut | None
    last_message: MessageOut | None
    unread_count: int
    last_read_message_id: int
    read_outbox_max_id: int
    is_pinned: bool
    pin_order: int
    is_archived: bool
    muted_until: datetime | None
    draft: str
    pinned_message_id: int | None
    invite_link: str | None
    members_can_send: bool
    slow_mode_seconds: int
    created_at: datetime
    updated_at: datetime


class CreateGroupIn(BaseModel):
    title: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=128)]
    member_ids: Annotated[list[int], Field(max_length=200)] = []
    avatar_media_id: int | None = None


class CreateChannelIn(BaseModel):
    title: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=128)]
    description: Annotated[str, StringConstraints(strip_whitespace=True, max_length=255)] = ""
    username: Username | None = None
    avatar_media_id: int | None = None

    _check_username = field_validator("username")(lambda cls, v: validate_username(v) if v else v)


class CreatePrivateIn(BaseModel):
    user_id: int


class UpdateChatIn(BaseModel):
    title: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=128)] | None = None
    description: Annotated[str, StringConstraints(strip_whitespace=True, max_length=255)] | None = None
    username: Username | None = None
    avatar_media_id: int | None = None
    remove_avatar: bool = False
    members_can_send: bool | None = None
    slow_mode_seconds: Annotated[int, Field(ge=0, le=3600)] | None = None

    _check_username = field_validator("username")(lambda cls, v: validate_username(v) if v else v)


class ChatSettingsIn(BaseModel):
    is_pinned: bool | None = None
    is_archived: bool | None = None
    muted_until: datetime | None = None
    unmute: bool = False
    draft: Annotated[str, StringConstraints(max_length=4096)] | None = None


class AddMembersIn(BaseModel):
    user_ids: Annotated[list[int], Field(min_length=1, max_length=200)]


class UpdateMemberIn(BaseModel):
    role: Literal[MemberRole.ADMIN, MemberRole.MEMBER]


class MemberOut(BaseModel):
    user: UserOut
    role: MemberRole
    joined_at: datetime


class JoinChatIn(BaseModel):
    username: str | None = None
    invite_hash: str | None = None

    @model_validator(mode="after")
    def _one_of(self) -> "JoinChatIn":
        if bool(self.username) == bool(self.invite_hash):
            raise ValueError("provide exactly one of username or invite_hash")
        return self


class PinMessageIn(BaseModel):
    message_id: int | None


class ClearHistoryIn(BaseModel):
    for_everyone: bool = False


class InvitePreviewOut(BaseModel):
    chat_id: int
    type: ChatType
    title: str
    description: str
    avatar: MediaOut | None
    member_count: int
    is_member: bool


# ---------- folders ----------

FolderChatType = Literal["contacts", "non_contacts", "groups", "channels", "bots", "unread"]


class FolderIn(BaseModel):
    title: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=32)]
    emoji: Annotated[str, StringConstraints(max_length=16)] = ""
    include_types: list[FolderChatType] = []
    include_chat_ids: Annotated[list[int], Field(max_length=200)] = []
    exclude_chat_ids: Annotated[list[int], Field(max_length=200)] = []
    exclude_muted: bool = False
    exclude_read: bool = False
    exclude_archived: bool = True


class FolderOut(ApiModel):
    id: int
    title: str
    emoji: str
    position: int
    include_types: list[str]
    include_chat_ids: list[int]
    exclude_chat_ids: list[int]
    exclude_muted: bool
    exclude_read: bool
    exclude_archived: bool


class FolderOrderIn(BaseModel):
    folder_ids: list[int]


# ---------- search ----------


class SearchOut(BaseModel):
    users: list[UserOut]
    chats: list[ChatOut]
    messages: list[MessageOut]


# ---------- AI ----------


class TranslateIn(BaseModel):
    text: Annotated[str, StringConstraints(min_length=1, max_length=8000)]
    target_language: Annotated[str, StringConstraints(min_length=2, max_length=32)] = "uz"


class RewriteIn(BaseModel):
    text: Annotated[str, StringConstraints(min_length=1, max_length=8000)]
    style: Literal["fix", "formal", "friendly", "short", "expand"] = "fix"
    language: Annotated[str, StringConstraints(max_length=32)] | None = None


class SummarizeIn(BaseModel):
    chat_id: int
    limit: Annotated[int, Field(ge=10, le=500)] = 200
    language: Annotated[str, StringConstraints(max_length=32)] = "uz"


class AiTextOut(BaseModel):
    text: str


class AiStatusOut(BaseModel):
    enabled: bool
    bot_user_id: int | None


# ---------- calls ----------


class IceServer(BaseModel):
    urls: list[str]
    username: str | None = None
    credential: str | None = None


class CallConfigOut(BaseModel):
    ice_servers: list[IceServer]
