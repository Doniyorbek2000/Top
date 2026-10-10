import json
import mimetypes
from typing import Annotated

from fastapi import APIRouter, Form, UploadFile, status
from fastapi.responses import FileResponse
from sqlalchemy import exists, or_, select

from app.config import get_settings
from app.deps import DbDep, ViewerDep
from app.errors import ApiError, bad_request, not_found
from app.models import Chat, ChatMember, Media, Message, User
from app.schemas import MediaOut
from app.services.serializers import media_out
from app.storage import UploadTooLargeError, make_image_thumbnail, path_for, save_upload

router = APIRouter(prefix="/media", tags=["media"])

KINDS = {"photo", "video", "voice", "audio", "file", "sticker"}
MAX_PHOTO_BYTES = 20 * 1024 * 1024


@router.post("", response_model=MediaOut, status_code=status.HTTP_201_CREATED)
async def upload_media(
    viewer: ViewerDep,
    db: DbDep,
    file: UploadFile,
    kind: Annotated[str, Form()],
    duration_ms: Annotated[int | None, Form()] = None,
    width: Annotated[int | None, Form()] = None,
    height: Annotated[int | None, Form()] = None,
    waveform: Annotated[str | None, Form(description="JSON array of 0-31 amplitude samples")] = None,
) -> MediaOut:
    if kind not in KINDS:
        raise bad_request("MEDIA_KIND_INVALID")
    settings = get_settings()
    limit = MAX_PHOTO_BYTES if kind == "photo" else settings.max_upload_bytes
    try:
        stored = await save_upload(file, limit)
    except UploadTooLargeError as exc:
        raise ApiError(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, "FILE_TOO_LARGE") from exc
    if stored.size == 0:
        raise bad_request("FILE_EMPTY")

    mime = file.content_type or mimetypes.guess_type(file.filename or "")[0] or "application/octet-stream"
    parsed_waveform: list[int] | None = None
    if waveform:
        try:
            values = json.loads(waveform)
            parsed_waveform = [max(0, min(31, int(v))) for v in values][:128]
        except (ValueError, TypeError) as exc:
            raise bad_request("WAVEFORM_INVALID") from exc

    media = Media(
        owner_id=viewer.id,
        kind=kind,
        mime_type=mime[:128],
        file_name=(file.filename or "")[:255],
        size=stored.size,
        storage_key=stored.key,
        width=width,
        height=height,
        duration_ms=duration_ms,
        waveform=parsed_waveform,
    )
    if kind in ("photo", "sticker") or (kind == "file" and mime.startswith("image/")):
        info = await make_image_thumbnail(stored.key)
        if info is not None:
            media.width, media.height, media.thumb_key = info.width, info.height, info.thumb_key
        elif kind == "photo":
            raise bad_request("IMAGE_INVALID")
    db.add(media)
    await db.commit()
    out = media_out(media)
    assert out is not None
    return out


async def _can_access(db: DbDep, viewer_id: int, media: Media) -> bool:
    if media.owner_id == viewer_id:
        return True
    # Avatars of users and chats are visible to every authenticated user.
    is_avatar = await db.scalar(
        select(
            or_(
                exists().where(User.avatar_media_id == media.id),
                exists().where(Chat.avatar_media_id == media.id),
            )
        )
    )
    if is_avatar:
        return True
    my_chats = select(ChatMember.chat_id).where(ChatMember.user_id == viewer_id)
    public_chats = select(Chat.id).where(Chat.username.isnot(None))
    return bool(
        await db.scalar(
            select(
                exists().where(
                    Message.media_id == media.id,
                    or_(Message.chat_id.in_(my_chats), Message.chat_id.in_(public_chats)),
                )
            )
        )
    )


@router.get("/{media_id}")
async def download_media(media_id: int, viewer: ViewerDep, db: DbDep, thumb: bool = False) -> FileResponse:
    media = await db.get(Media, media_id)
    if media is None or not await _can_access(db, viewer.id, media):
        raise not_found("MEDIA_NOT_FOUND")
    if thumb:
        if not media.thumb_key:
            raise not_found("THUMB_NOT_FOUND")
        return FileResponse(path_for(media.thumb_key), media_type="image/jpeg",
                            headers={"Cache-Control": "private, max-age=31536000, immutable"})
    path = path_for(media.storage_key)
    if not path.exists():
        raise not_found("MEDIA_NOT_FOUND")
    # FileResponse supports HTTP Range requests, so video/audio can stream and seek.
    return FileResponse(
        path,
        media_type=media.mime_type,
        filename=media.file_name or None,
        content_disposition_type="inline",
        headers={"Cache-Control": "private, max-age=31536000, immutable"},
    )
