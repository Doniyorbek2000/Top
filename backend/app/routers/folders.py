from fastapi import APIRouter, status
from sqlalchemy import func, select

from app.deps import DbDep, ViewerDep
from app.errors import bad_request, not_found
from app.models import ChatFolder
from app.realtime import publish_to_users
from app.schemas import FolderIn, FolderOrderIn, FolderOut

router = APIRouter(prefix="/folders", tags=["folders"])

MAX_FOLDERS = 20


async def _get_owned(db: DbDep, folder_id: int, owner_id: int) -> ChatFolder:
    folder = await db.get(ChatFolder, folder_id)
    if folder is None or folder.owner_id != owner_id:
        raise not_found("FOLDER_NOT_FOUND")
    return folder


@router.get("", response_model=list[FolderOut])
async def list_folders(viewer: ViewerDep, db: DbDep) -> list[ChatFolder]:
    return list(
        await db.scalars(select(ChatFolder).where(ChatFolder.owner_id == viewer.id).order_by(ChatFolder.position, ChatFolder.id))
    )


@router.post("", response_model=FolderOut, status_code=status.HTTP_201_CREATED)
async def create_folder(body: FolderIn, viewer: ViewerDep, db: DbDep) -> ChatFolder:
    count = await db.scalar(select(func.count()).select_from(ChatFolder).where(ChatFolder.owner_id == viewer.id))
    if (count or 0) >= MAX_FOLDERS:
        raise bad_request("FOLDER_LIMIT_REACHED")
    if not body.include_types and not body.include_chat_ids:
        raise bad_request("FOLDER_EMPTY")
    folder = ChatFolder(owner_id=viewer.id, position=count or 0, **body.model_dump())
    db.add(folder)
    await db.commit()
    await publish_to_users([viewer.id], "folders.updated", {})
    return folder


@router.put("/{folder_id}", response_model=FolderOut)
async def update_folder(folder_id: int, body: FolderIn, viewer: ViewerDep, db: DbDep) -> ChatFolder:
    folder = await _get_owned(db, folder_id, viewer.id)
    if not body.include_types and not body.include_chat_ids:
        raise bad_request("FOLDER_EMPTY")
    for key, value in body.model_dump().items():
        setattr(folder, key, value)
    await db.commit()
    await publish_to_users([viewer.id], "folders.updated", {})
    return folder


@router.delete("/{folder_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_folder(folder_id: int, viewer: ViewerDep, db: DbDep) -> None:
    folder = await _get_owned(db, folder_id, viewer.id)
    await db.delete(folder)
    await db.commit()
    await publish_to_users([viewer.id], "folders.updated", {})


@router.post("/order", status_code=status.HTTP_204_NO_CONTENT)
async def reorder_folders(body: FolderOrderIn, viewer: ViewerDep, db: DbDep) -> None:
    folders = {
        f.id: f for f in await db.scalars(select(ChatFolder).where(ChatFolder.owner_id == viewer.id))
    }
    for position, fid in enumerate(body.folder_ids):
        if fid in folders:
            folders[fid].position = position
    await db.commit()
    await publish_to_users([viewer.id], "folders.updated", {})
