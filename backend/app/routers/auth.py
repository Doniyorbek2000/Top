import logging
from datetime import timedelta

from fastapi import APIRouter, Request, status
from pydantic import BaseModel
from sqlalchemy import delete, select

from app.config import get_settings
from app.deps import DbDep, ViewerDep
from app.errors import ApiError, bad_request, not_found, too_many, unauthorized
from app.models import AuthSession, User
from app.realtime import publish_to_session, utcnow
from app.redis_client import redis
from app.schemas import MeOut, PushTokenIn, RefreshIn, SendCodeIn, SendCodeOut, SessionOut, VerifyCodeIn
from app.security import create_access_token, generate_otp, hash_token, new_refresh_token
from app.services.serializers import me_out
from app.sms import SmsDeliveryError, send_otp_sms

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/auth", tags=["auth"])

OTP_LENGTH = 5
OTP_HOURLY_LIMIT = 10


class TokensOut(BaseModel):
    access_token: str
    refresh_token: str
    expires_in: int
    session_id: int


class AuthOut(TokensOut):
    user: MeOut
    is_new_user: bool


def _client_ip(request: Request) -> str:
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else ""


@router.post("/send-code", response_model=SendCodeOut)
async def send_code(body: SendCodeIn, request: Request) -> SendCodeOut:
    settings = get_settings()
    phone = body.phone
    cooldown_key = f"otp:cooldown:{phone}"
    ttl = await redis.ttl(cooldown_key)
    if ttl > 0:
        raise too_many("OTP_COOLDOWN", ttl)

    hourly_key = f"otp:hourly:{_client_ip(request)}"
    sent = await redis.incr(hourly_key)
    if sent == 1:
        await redis.expire(hourly_key, 3600)
    if sent > OTP_HOURLY_LIMIT and settings.environment == "production":
        raise too_many("OTP_RATE_LIMIT", await redis.ttl(hourly_key))

    code = generate_otp(OTP_LENGTH)
    await redis.hset(f"otp:{phone}", mapping={"code": code, "attempts": 0})
    await redis.expire(f"otp:{phone}", settings.otp_ttl_seconds)
    if settings.otp_resend_cooldown_seconds > 0:
        await redis.set(cooldown_key, "1", ex=settings.otp_resend_cooldown_seconds)
    try:
        await send_otp_sms(phone, code)
    except SmsDeliveryError as exc:
        logger.error("SMS delivery failed for %s: %s", phone, exc)
        await redis.delete(f"otp:{phone}", cooldown_key)
        raise ApiError(status.HTTP_502_BAD_GATEWAY, "SMS_DELIVERY_FAILED") from exc

    return SendCodeOut(
        phone=phone,
        code_length=OTP_LENGTH,
        expires_in=settings.otp_ttl_seconds,
        resend_after=settings.otp_resend_cooldown_seconds,
    )


async def _check_code(phone: str, code: str) -> None:
    settings = get_settings()
    if settings.environment != "production" and code == settings.dev_otp_code:
        await redis.delete(f"otp:{phone}")
        return
    key = f"otp:{phone}"
    stored = await redis.hgetall(key)
    if not stored:
        raise bad_request("OTP_EXPIRED")
    attempts = await redis.hincrby(key, "attempts", 1)
    if attempts > settings.otp_max_attempts:
        await redis.delete(key)
        raise too_many("OTP_TOO_MANY_ATTEMPTS", settings.otp_resend_cooldown_seconds)
    if stored["code"] != code:
        raise bad_request("OTP_INVALID")
    await redis.delete(key)


async def _issue_session(db: DbDep, user: User, request: Request, device_name: str, platform: str, app_version: str) -> TokensOut:
    refresh = new_refresh_token()
    session = AuthSession(
        user_id=user.id,
        refresh_token_hash=hash_token(refresh),
        device_name=device_name,
        platform=platform,
        app_version=app_version,
        ip=_client_ip(request),
    )
    db.add(session)
    await db.commit()
    settings = get_settings()
    return TokensOut(
        access_token=create_access_token(user.id, session.id),
        refresh_token=refresh,
        expires_in=settings.access_token_ttl_seconds,
        session_id=session.id,
    )


@router.post("/verify", response_model=AuthOut)
async def verify_code(body: VerifyCodeIn, request: Request, db: DbDep) -> AuthOut:
    await _check_code(body.phone, body.code)
    user = await db.scalar(select(User).where(User.phone == body.phone))
    is_new = user is None
    if user is None:
        user = User(phone=body.phone, first_name=body.first_name or "", last_name=body.last_name or "")
        db.add(user)
        await db.flush()
    tokens = await _issue_session(db, user, request, body.device_name, body.platform, body.app_version)
    return AuthOut(**tokens.model_dump(), user=await me_out(db, user), is_new_user=is_new)


@router.post("/refresh", response_model=TokensOut)
async def refresh_tokens(body: RefreshIn, db: DbDep) -> TokensOut:
    session = await db.scalar(select(AuthSession).where(AuthSession.refresh_token_hash == hash_token(body.refresh_token)))
    if session is None:
        raise unauthorized("REFRESH_TOKEN_INVALID")
    settings = get_settings()
    if utcnow() - session.last_active_at > timedelta(seconds=settings.refresh_token_ttl_seconds):
        await db.delete(session)
        await db.commit()
        raise unauthorized("REFRESH_TOKEN_EXPIRED")
    refresh = new_refresh_token()
    session.refresh_token_hash = hash_token(refresh)
    session.last_active_at = utcnow()
    await db.commit()
    return TokensOut(
        access_token=create_access_token(session.user_id, session.id),
        refresh_token=refresh,
        expires_in=settings.access_token_ttl_seconds,
        session_id=session.id,
    )


async def _revoke(session_id: int) -> None:
    settings = get_settings()
    await redis.set(f"revoked_session:{session_id}", "1", ex=settings.access_token_ttl_seconds + 60)
    await publish_to_session(session_id, "session.terminated", {"session_id": session_id})


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(viewer: ViewerDep, db: DbDep) -> None:
    await db.execute(delete(AuthSession).where(AuthSession.id == viewer.session_id))
    await db.commit()
    await _revoke(viewer.session_id)


@router.get("/sessions", response_model=list[SessionOut])
async def list_sessions(viewer: ViewerDep, db: DbDep) -> list[SessionOut]:
    rows = await db.scalars(
        select(AuthSession).where(AuthSession.user_id == viewer.id).order_by(AuthSession.last_active_at.desc())
    )
    result = []
    for s in rows:
        item = SessionOut.model_validate(s)
        item.is_current = s.id == viewer.session_id
        result.append(item)
    return result


@router.delete("/sessions/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
async def terminate_session(session_id: int, viewer: ViewerDep, db: DbDep) -> None:
    result = await db.execute(
        delete(AuthSession).where(AuthSession.id == session_id, AuthSession.user_id == viewer.id)
    )
    if result.rowcount == 0:
        raise not_found("SESSION_NOT_FOUND")
    await db.commit()
    await _revoke(session_id)


@router.delete("/sessions", status_code=status.HTTP_204_NO_CONTENT)
async def terminate_other_sessions(viewer: ViewerDep, db: DbDep) -> None:
    result = await db.execute(
        delete(AuthSession)
        .where(AuthSession.user_id == viewer.id, AuthSession.id != viewer.session_id)
        .returning(AuthSession.id)
    )
    ids = list(result.scalars())
    await db.commit()
    for sid in ids:
        await _revoke(sid)


@router.put("/push-token", status_code=status.HTTP_204_NO_CONTENT)
async def set_push_token(body: PushTokenIn, viewer: ViewerDep, db: DbDep) -> None:
    session = await db.get(AuthSession, viewer.session_id)
    if session is None:
        raise unauthorized("SESSION_REVOKED")
    session.push_token = body.push_token
    await db.commit()
