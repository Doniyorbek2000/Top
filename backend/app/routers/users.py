from fastapi import APIRouter, Query, status
from sqlalchemy import delete, func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert

from app.deps import DbDep, ViewerDep
from app.errors import bad_request, conflict, not_found
from app.models import Block, Chat, ChatMember, ChatType, Contact, Media, User
from app.realtime import publish_to_users
from app.schemas import MeOut, UpdateMeIn, UserOut, UsernameCheckOut, validate_username
from app.services.serializers import me_out, user_out, users_out

router = APIRouter(prefix="/users", tags=["users"])


async def username_taken(db: DbDep, username: str, exclude_user_id: int | None = None, exclude_chat_id: int | None = None) -> bool:
    lowered = username.lower()
    user_q = select(User.id).where(func.lower(User.username) == lowered)
    if exclude_user_id is not None:
        user_q = user_q.where(User.id != exclude_user_id)
    chat_q = select(Chat.id).where(func.lower(Chat.username) == lowered)
    if exclude_chat_id is not None:
        chat_q = chat_q.where(Chat.id != exclude_chat_id)
    return (await db.scalar(user_q.limit(1))) is not None or (await db.scalar(chat_q.limit(1))) is not None


async def related_user_ids(db: DbDep, user_id: int) -> set[int]:
    """Users who should receive profile/presence updates: contacts-of and private-chat peers."""
    contacts = set(await db.scalars(select(Contact.owner_id).where(Contact.contact_id == user_id)))
    private_chats = select(ChatMember.chat_id).join(Chat, Chat.id == ChatMember.chat_id).where(
        ChatMember.user_id == user_id, Chat.type == ChatType.PRIVATE
    )
    peers = set(
        await db.scalars(
            select(ChatMember.user_id).where(ChatMember.chat_id.in_(private_chats), ChatMember.user_id != user_id)
        )
    )
    return contacts | peers


@router.get("/me", response_model=MeOut)
async def get_me(viewer: ViewerDep, db: DbDep) -> MeOut:
    return await me_out(db, viewer.user)


@router.patch("/me", response_model=MeOut)
async def update_me(body: UpdateMeIn, viewer: ViewerDep, db: DbDep) -> MeOut:
    user = viewer.user
    fields = body.model_fields_set
    if "first_name" in fields and body.first_name is not None:
        user.first_name = body.first_name
    if "last_name" in fields and body.last_name is not None:
        user.last_name = body.last_name
    if "bio" in fields and body.bio is not None:
        user.bio = body.bio
    if "username" in fields:
        new_username = body.username or None
        if new_username and await username_taken(db, new_username, exclude_user_id=user.id):
            raise conflict("USERNAME_OCCUPIED")
        user.username = new_username
    if body.remove_avatar:
        user.avatar_media_id = None
    elif body.avatar_media_id is not None:
        media = await db.get(Media, body.avatar_media_id)
        if media is None or media.owner_id != user.id or media.kind != "photo":
            raise bad_request("MEDIA_INVALID")
        user.avatar_media_id = media.id
    if body.last_seen_visibility is not None:
        user.last_seen_visibility = body.last_seen_visibility
    if body.phone_visibility is not None:
        user.phone_visibility = body.phone_visibility
    await db.commit()
    await publish_to_users({*await related_user_ids(db, user.id), user.id}, "user.updated", {"user_id": user.id})
    return await me_out(db, user)


@router.get("/check-username", response_model=UsernameCheckOut)
async def check_username(viewer: ViewerDep, db: DbDep, username: str = Query(max_length=32)) -> UsernameCheckOut:
    try:
        validate_username(username)
    except ValueError as exc:
        raise bad_request("USERNAME_INVALID", str(exc)) from exc
    taken = await username_taken(db, username, exclude_user_id=viewer.id)
    return UsernameCheckOut(username=username, available=not taken)


@router.get("/blocked", response_model=list[UserOut])
async def list_blocked(viewer: ViewerDep, db: DbDep) -> list[UserOut]:
    users = list(
        await db.scalars(
            select(User).join(Block, Block.blocked_id == User.id).where(Block.owner_id == viewer.id).order_by(Block.created_at.desc())
        )
    )
    return await users_out(db, viewer.id, users)


@router.get("/by-username/{username}", response_model=UserOut)
async def get_by_username(username: str, viewer: ViewerDep, db: DbDep) -> UserOut:
    user = await db.scalar(select(User).where(func.lower(User.username) == username.lower()))
    if user is None:
        raise not_found("USER_NOT_FOUND")
    return await user_out(db, viewer.id, user)


@router.get("/{user_id}", response_model=UserOut)
async def get_user(user_id: int, viewer: ViewerDep, db: DbDep) -> UserOut:
    user = await db.get(User, user_id)
    if user is None:
        raise not_found("USER_NOT_FOUND")
    return await user_out(db, viewer.id, user)


@router.post("/batch", response_model=list[UserOut])
async def get_users(ids: list[int], viewer: ViewerDep, db: DbDep) -> list[UserOut]:
    if len(ids) > 500:
        raise bad_request("TOO_MANY_IDS")
    users = list(await db.scalars(select(User).where(User.id.in_(set(ids)))))
    return await users_out(db, viewer.id, users)


@router.post("/{user_id}/block", status_code=status.HTTP_204_NO_CONTENT)
async def block_user(user_id: int, viewer: ViewerDep, db: DbDep) -> None:
    if user_id == viewer.id:
        raise bad_request("CANNOT_BLOCK_SELF")
    if await db.get(User, user_id) is None:
        raise not_found("USER_NOT_FOUND")
    await db.execute(pg_insert(Block).values(owner_id=viewer.id, blocked_id=user_id).on_conflict_do_nothing())
    await db.commit()
    await publish_to_users([viewer.id, user_id], "user.updated", {"user_id": viewer.id})
    await publish_to_users([viewer.id], "user.updated", {"user_id": user_id})


@router.delete("/{user_id}/block", status_code=status.HTTP_204_NO_CONTENT)
async def unblock_user(user_id: int, viewer: ViewerDep, db: DbDep) -> None:
    await db.execute(delete(Block).where(Block.owner_id == viewer.id, Block.blocked_id == user_id))
    await db.commit()
    await publish_to_users([viewer.id, user_id], "user.updated", {"user_id": viewer.id})
    await publish_to_users([viewer.id], "user.updated", {"user_id": user_id})
