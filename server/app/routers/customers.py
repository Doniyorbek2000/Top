"""Sado customer identity: anonymous, device-bound accounts. No phone number, no Telegram data.

A customer is created on first launch. Further devices join the same customer with a short-lived
one-time link code shown on an existing device; store purchases can also be restored onto any
customer (the store account is the proof of purchase).
"""

import uuid
from datetime import UTC, datetime
from typing import Annotated, Literal

from fastapi import APIRouter, Request, status
from pydantic import BaseModel, StringConstraints
from sqlalchemy import select, update

from app.config import get_settings
from app.deps import CustomerDep, DbDep, client_ip, get_redis, rate_limit
from app.errors import bad_request, unauthorized
from app.models import Customer, Device
from app.security import create_access_token, new_link_code, new_secret, sha256_hex
from app.services import credits
from app.services.audit import audit

router = APIRouter(prefix="/v1", tags=["customers"])

Platform = Literal["android", "ios", "web"]


class RegisterIn(BaseModel):
    platform: Platform
    region: Annotated[str, StringConstraints(pattern=r"^[A-Za-z]{2}$")] = "UZ"


class TokensOut(BaseModel):
    customer_id: uuid.UUID
    device_id: uuid.UUID
    access_token: str
    refresh_token: str
    expires_in: int
    # Give this to the store as obfuscatedAccountId (Play) / appAccountToken (StoreKit 2).
    store_account_token: uuid.UUID


class RefreshIn(BaseModel):
    refresh_token: Annotated[str, StringConstraints(min_length=20, max_length=200)]


class LinkCodeOut(BaseModel):
    code: str
    expires_in: int


class RedeemLinkIn(BaseModel):
    code: Annotated[str, StringConstraints(pattern=r"^[A-Z2-9]{8}$")]
    platform: Platform


async def _issue(db: DbDep, customer: Customer, platform: str) -> TokensOut:
    refresh = new_secret()
    device = Device(customer_id=customer.id, refresh_hash=sha256_hex(refresh), platform=platform)
    db.add(device)
    await db.commit()
    return TokensOut(
        customer_id=customer.id,
        device_id=device.id,
        access_token=create_access_token(customer.id, device.id),
        refresh_token=refresh,
        expires_in=get_settings().access_token_ttl_seconds,
        store_account_token=customer.store_account_token,
    )


@router.post("/customers", response_model=TokensOut, status_code=status.HTTP_201_CREATED)
async def register(body: RegisterIn, request: Request, db: DbDep) -> TokensOut:
    await rate_limit(f"register:{client_ip(request)}", limit=10, window_seconds=3600)
    customer = Customer(region=body.region.upper())
    db.add(customer)
    await db.flush()
    return await _issue(db, customer, body.platform)


@router.post("/auth/refresh", response_model=TokensOut)
async def refresh_tokens(body: RefreshIn, request: Request, db: DbDep) -> TokensOut:
    await rate_limit(f"refresh:{client_ip(request)}", limit=60)
    device = await db.scalar(select(Device).where(Device.refresh_hash == sha256_hex(body.refresh_token)).with_for_update())
    if device is None or device.revoked_at is not None:
        raise unauthorized("REFRESH_TOKEN_INVALID")
    customer = await db.get(Customer, device.customer_id)
    if customer is None or customer.deleted_at is not None:
        raise unauthorized("CUSTOMER_DELETED")
    refresh = new_secret()  # rotation: the old refresh token stops working immediately
    device.refresh_hash = sha256_hex(refresh)
    device.last_seen_at = datetime.now(UTC)
    await db.commit()
    return TokensOut(
        customer_id=customer.id,
        device_id=device.id,
        access_token=create_access_token(customer.id, device.id),
        refresh_token=refresh,
        expires_in=get_settings().access_token_ttl_seconds,
        store_account_token=customer.store_account_token,
    )


@router.post("/customers/me/link-code", response_model=LinkCodeOut)
async def create_link_code(current: CustomerDep) -> LinkCodeOut:
    await rate_limit(f"linkcode:{current.id}", limit=5, window_seconds=3600)
    ttl = get_settings().link_code_ttl_seconds
    code = new_link_code()
    await get_redis().set(f"link:{code}", str(current.id), ex=ttl, nx=True)
    return LinkCodeOut(code=code, expires_in=ttl)


@router.post("/customers/link", response_model=TokensOut)
async def redeem_link_code(body: RedeemLinkIn, request: Request, db: DbDep) -> TokensOut:
    await rate_limit(f"linkredeem:{client_ip(request)}", limit=10, window_seconds=600)
    customer_id = await get_redis().getdel(f"link:{body.code}")  # single use
    if customer_id is None:
        raise bad_request("LINK_CODE_INVALID")
    customer = await db.get(Customer, uuid.UUID(customer_id))
    if customer is None or customer.deleted_at is not None:
        raise bad_request("LINK_CODE_INVALID")
    audit(db, f"customer:{customer.id}", "device_linked", str(customer.id), platform=body.platform)
    return await _issue(db, customer, body.platform)


@router.delete("/customers/me", status_code=status.HTTP_204_NO_CONTENT)
async def delete_account(current: CustomerDep, db: DbDep) -> None:
    """Account deletion: revokes all devices and credits. Financial records are kept for the legally
    required retention period but contain no personal data beyond an opaque customer id.
    Store subscriptions must still be cancelled by the user in Google Play / App Store settings."""
    now = datetime.now(UTC)
    await db.execute(update(Device).where(Device.customer_id == current.id).values(revoked_at=now))
    current.customer.deleted_at = now
    balance = await credits.get_balance(db, current.id)
    if balance.available:
        await credits.add_purchased(db, current.id, -balance.available, f"deletion:{now.isoformat()}", kind="adjust")
    await credits.revoke_allowance(db, current.id, f"deletion:{now.isoformat()}")
    audit(db, f"customer:{current.id}", "account_deleted", str(current.id))
    await db.commit()
