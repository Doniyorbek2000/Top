import uuid
from collections.abc import Callable, Coroutine
from dataclasses import dataclass
from typing import Annotated, Any

from fastapi import Depends, Header, Request
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_db
from app.errors import forbidden, too_many, unauthorized
from app.models import AdminRole, AdminUser, Customer, Device
from app.security import TokenError, decode_access_token, sha256_hex

_redis: Redis | None = None


def get_redis() -> Redis:
    global _redis
    if _redis is None:
        _redis = Redis.from_url(get_settings().redis_url, decode_responses=True)
    return _redis


DbDep = Annotated[AsyncSession, Depends(get_db)]


@dataclass(slots=True)
class CurrentCustomer:
    customer: Customer
    device_id: uuid.UUID

    @property
    def id(self) -> uuid.UUID:
        return self.customer.id


async def get_current_customer(request: Request, db: DbDep) -> CurrentCustomer:
    header = request.headers.get("authorization", "")
    if not header.lower().startswith("bearer "):
        raise unauthorized()
    try:
        customer_id, device_id = decode_access_token(header[7:].strip())
    except TokenError as exc:
        raise unauthorized("TOKEN_INVALID") from exc
    device = await db.get(Device, device_id)
    if device is None or device.revoked_at is not None or device.customer_id != customer_id:
        raise unauthorized("DEVICE_REVOKED")
    customer = await db.get(Customer, customer_id)
    if customer is None or customer.deleted_at is not None:
        raise unauthorized("CUSTOMER_DELETED")
    return CurrentCustomer(customer=customer, device_id=device_id)


CustomerDep = Annotated[CurrentCustomer, Depends(get_current_customer)]

_ROLE_RANK = {AdminRole.VIEWER: 0, AdminRole.SUPPORT: 1, AdminRole.FINANCE: 2, AdminRole.OWNER: 3}


def require_admin(minimum: AdminRole) -> Callable[..., Coroutine[Any, Any, AdminUser]]:
    """Admin auth via X-Admin-Key (stored hashed). Roles are hierarchical."""

    async def dependency(db: DbDep, x_admin_key: Annotated[str | None, Header()] = None) -> AdminUser:
        if not x_admin_key:
            raise unauthorized("ADMIN_KEY_REQUIRED")
        admin = await db.scalar(select(AdminUser).where(AdminUser.key_hash == sha256_hex(x_admin_key)))
        if admin is None or not admin.active:
            raise unauthorized("ADMIN_KEY_INVALID")
        if _ROLE_RANK[admin.role] < _ROLE_RANK[minimum]:
            raise forbidden("ADMIN_ROLE_INSUFFICIENT")
        return admin

    return dependency


async def rate_limit(key: str, limit: int | None = None, window_seconds: int = 60) -> None:
    """Fixed-window limiter in Redis; fails closed for abuse-prone endpoints only if Redis answers."""
    redis = get_redis()
    limit = limit or get_settings().rate_limit_per_minute
    bucket = f"rl:{key}"
    count = await redis.incr(bucket)
    if count == 1:
        await redis.expire(bucket, window_seconds)
    if count > limit:
        ttl = await redis.ttl(bucket)
        raise too_many(max(ttl, 1))


def client_ip(request: Request) -> str:
    # X-Forwarded-For is client-controlled; uvicorn --proxy-headers rewrites request.client only for
    # proxies listed in --forwarded-allow-ips, so the peer address here cannot be spoofed.
    return request.client.host if request.client else "unknown"
