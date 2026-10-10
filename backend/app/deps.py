from dataclasses import dataclass
from typing import Annotated

from fastapi import Depends, Query, Request
from sqlalchemy import update
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.errors import unauthorized
from app.models import AuthSession, User
from app.realtime import utcnow
from app.redis_client import redis
from app.security import TokenError, decode_access_token

SESSION_TOUCH_INTERVAL_SECONDS = 300


@dataclass(slots=True)
class Viewer:
    user: User
    session_id: int

    @property
    def id(self) -> int:
        return self.user.id


def _extract_token(request: Request, token_query: str | None) -> str | None:
    header = request.headers.get("authorization", "")
    if header.lower().startswith("bearer "):
        return header[7:].strip()
    return token_query


async def authenticate_token(db: AsyncSession, token: str | None) -> Viewer:
    if not token:
        raise unauthorized()
    try:
        user_id, session_id = decode_access_token(token)
    except TokenError as exc:
        raise unauthorized("TOKEN_INVALID") from exc

    # Revoked sessions are cached in Redis so a terminated device loses access immediately.
    if await redis.exists(f"revoked_session:{session_id}"):
        raise unauthorized("SESSION_REVOKED")

    user = await db.get(User, user_id)
    if user is None:
        raise unauthorized("USER_NOT_FOUND")

    if await redis.set(f"session_touch:{session_id}", "1", ex=SESSION_TOUCH_INTERVAL_SECONDS, nx=True):
        result = await db.execute(
            update(AuthSession).where(AuthSession.id == session_id).values(last_active_at=utcnow())
        )
        if result.rowcount == 0:
            await db.rollback()
            raise unauthorized("SESSION_REVOKED")
        await db.commit()
    return Viewer(user=user, session_id=session_id)


async def get_viewer(
    request: Request,
    db: Annotated[AsyncSession, Depends(get_db)],
    token: Annotated[str | None, Query(include_in_schema=False)] = None,
) -> Viewer:
    return await authenticate_token(db, _extract_token(request, token))


DbDep = Annotated[AsyncSession, Depends(get_db)]
ViewerDep = Annotated[Viewer, Depends(get_viewer)]
