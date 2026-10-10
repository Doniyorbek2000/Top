import asyncio
import logging
import secrets
from dataclasses import dataclass
from pathlib import Path

import aiofiles
from fastapi import UploadFile
from PIL import Image, ImageOps, UnidentifiedImageError

from app.config import get_settings

logger = logging.getLogger(__name__)

CHUNK_SIZE = 1024 * 1024
THUMB_MAX_SIDE = 320


class UploadTooLargeError(Exception):
    pass


@dataclass(slots=True)
class StoredFile:
    key: str
    size: int


@dataclass(slots=True)
class ImageInfo:
    width: int
    height: int
    thumb_key: str | None


def _root() -> Path:
    root = get_settings().media_root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    return root


def path_for(key: str) -> Path:
    root = _root()
    path = (root / key).resolve()
    if root not in path.parents:
        raise ValueError("invalid storage key")
    return path


def _new_key(suffix: str) -> str:
    token = secrets.token_hex(16)
    return f"{token[:2]}/{token[2:4]}/{token}{suffix}"


async def save_upload(upload: UploadFile, max_bytes: int) -> StoredFile:
    suffix = Path(upload.filename or "").suffix.lower()[:10]
    key = _new_key(suffix)
    path = path_for(key)
    path.parent.mkdir(parents=True, exist_ok=True)
    size = 0
    try:
        async with aiofiles.open(path, "wb") as out:
            while chunk := await upload.read(CHUNK_SIZE):
                size += len(chunk)
                if size > max_bytes:
                    raise UploadTooLargeError
                await out.write(chunk)
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    return StoredFile(key=key, size=size)


def _make_thumbnail(source: Path) -> ImageInfo | None:
    try:
        with Image.open(source) as img:
            img = ImageOps.exif_transpose(img)
            width, height = img.size
            img.thumbnail((THUMB_MAX_SIDE, THUMB_MAX_SIDE))
            if img.mode not in ("RGB", "L"):
                img = img.convert("RGB")
            thumb_key = _new_key(".jpg")
            thumb_path = path_for(thumb_key)
            thumb_path.parent.mkdir(parents=True, exist_ok=True)
            img.save(thumb_path, "JPEG", quality=70, optimize=True)
            return ImageInfo(width=width, height=height, thumb_key=thumb_key)
    except (UnidentifiedImageError, OSError) as exc:
        logger.info("thumbnail generation skipped for %s: %s", source, exc)
        return None


async def make_image_thumbnail(key: str) -> ImageInfo | None:
    return await asyncio.to_thread(_make_thumbnail, path_for(key))


def delete_key(key: str) -> None:
    path_for(key).unlink(missing_ok=True)
