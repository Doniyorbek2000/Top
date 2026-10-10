from fastapi import APIRouter, status
from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert as pg_insert

from app.deps import DbDep, ViewerDep
from app.errors import bad_request, not_found
from app.models import Contact, User
from app.realtime import publish_to_users
from app.schemas import ContactAddIn, ContactImportIn, UserOut, normalize_phone
from app.services.serializers import user_out, users_out

router = APIRouter(prefix="/contacts", tags=["contacts"])


@router.get("", response_model=list[UserOut])
async def list_contacts(viewer: ViewerDep, db: DbDep) -> list[UserOut]:
    users = list(
        await db.scalars(
            select(User)
            .join(Contact, Contact.contact_id == User.id)
            .where(Contact.owner_id == viewer.id)
            .order_by(Contact.first_name, Contact.last_name, User.first_name)
        )
    )
    return await users_out(db, viewer.id, users)


@router.post("/import", response_model=list[UserOut])
async def import_contacts(body: ContactImportIn, viewer: ViewerDep, db: DbDep) -> list[UserOut]:
    """Match phone book entries against registered users and store the matches as contacts."""
    by_phone: dict[str, tuple[str, str]] = {}
    for item in body.contacts:
        try:
            by_phone[normalize_phone(item.phone)] = (item.first_name, item.last_name)
        except ValueError:
            continue
    if not by_phone:
        return []
    users = list(await db.scalars(select(User).where(User.phone.in_(by_phone.keys()), User.id != viewer.id)))
    if users:
        stmt = pg_insert(Contact).values([
            {
                "owner_id": viewer.id,
                "contact_id": u.id,
                "first_name": by_phone[u.phone][0] or u.first_name,
                "last_name": by_phone[u.phone][1] or u.last_name,
            }
            for u in users
            if u.phone
        ])
        await db.execute(
            stmt.on_conflict_do_update(
                index_elements=[Contact.owner_id, Contact.contact_id],
                set_={"first_name": stmt.excluded.first_name, "last_name": stmt.excluded.last_name},
            )
        )
        await db.commit()
    return await users_out(db, viewer.id, users)


@router.post("", response_model=UserOut)
async def add_contact(body: ContactAddIn, viewer: ViewerDep, db: DbDep) -> UserOut:
    if body.user_id == viewer.id:
        raise bad_request("CANNOT_ADD_SELF")
    user = await db.get(User, body.user_id)
    if user is None:
        raise not_found("USER_NOT_FOUND")
    stmt = pg_insert(Contact).values(
        owner_id=viewer.id,
        contact_id=user.id,
        first_name=body.first_name or user.first_name,
        last_name=body.last_name or user.last_name,
    )
    await db.execute(
        stmt.on_conflict_do_update(
            index_elements=[Contact.owner_id, Contact.contact_id],
            set_={"first_name": stmt.excluded.first_name, "last_name": stmt.excluded.last_name},
        )
    )
    await db.commit()
    await publish_to_users([viewer.id], "user.updated", {"user_id": user.id})
    return await user_out(db, viewer.id, user)


@router.delete("/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_contact(user_id: int, viewer: ViewerDep, db: DbDep) -> None:
    await db.execute(delete(Contact).where(Contact.owner_id == viewer.id, Contact.contact_id == user_id))
    await db.commit()
    await publish_to_users([viewer.id], "user.updated", {"user_id": user_id})
