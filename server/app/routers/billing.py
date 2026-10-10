import logging
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Query, Request
from pydantic import BaseModel, Field, StringConstraints

from app.catalog import PRODUCTS, ProductKind, price_for
from app.deps import CustomerDep, DbDep, rate_limit
from app.errors import ApiError, bad_request
from app.providers.base import ProviderError
from app.providers.registry import get_provider, provider_status
from app.services import credits
from app.services.billing import BillingError, apply_verified_purchase, process_event
from app.services.entitlements import load_entitlements

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/v1", tags=["billing"])


class PriceOut(BaseModel):
    amount_minor: int
    currency: str


class ProductOut(BaseModel):
    id: str
    kind: ProductKind
    entitlements: list[str]
    period_months: int
    trial_days: int
    group: str
    monthly_ai_credits: int
    asset_id: str
    store_product_id: str | None
    reference_price: PriceOut | None


class CatalogOut(BaseModel):
    products: list[ProductOut]
    providers: dict[str, str]


@router.get("/catalog", response_model=CatalogOut)
async def catalog(
    region: Annotated[str, Query(pattern=r"^[A-Za-z]{2}$")] = "UZ",
    provider: Annotated[str | None, Query(max_length=32)] = None,
) -> CatalogOut:
    """Public catalog. The client shows the store's localized price (ProductDetails / Product.displayPrice);
    reference_price is only a fallback for display before the store answers."""
    products = []
    for p in PRODUCTS.values():
        if provider in ("google_play", "app_store") and not p.in_app:
            continue
        price = price_for(p, region)
        products.append(ProductOut(
            id=p.id, kind=p.kind, entitlements=[e.value for e in p.entitlements], period_months=p.period_months,
            trial_days=p.trial_days, group=p.group, monthly_ai_credits=p.monthly_ai_credits, asset_id=p.asset_id,
            store_product_id=p.store_ids.get(provider) if provider else None,
            reference_price=PriceOut(amount_minor=price.amount_minor, currency=price.currency) if price else None,
        ))
    return CatalogOut(products=products, providers=provider_status())


class EntitlementOut(BaseModel):
    entitlement: str
    expires_at: datetime
    source: str
    product_id: str | None
    will_renew: bool
    in_grace_period: bool
    is_trial: bool


class CreditsOut(BaseModel):
    allowance: int
    purchased: int
    reserved: int


class EntitlementsOut(BaseModel):
    customer_id: str
    tier: str
    entitlements: list[EntitlementOut]
    owned_assets: list[str]
    credits: CreditsOut
    checked_at: datetime


async def _entitlements_out(db: DbDep, current: CustomerDep) -> EntitlementsOut:
    now = datetime.now(UTC)
    ent = await load_entitlements(db, current.id, now)
    balance = await credits.get_balance(db, current.id)
    return EntitlementsOut(
        customer_id=str(current.id),
        tier=ent.tier,
        entitlements=[
            EntitlementOut(
                entitlement=e.entitlement, expires_at=e.expires_at, source=e.source, product_id=e.product_id,
                will_renew=e.will_renew, in_grace_period=e.in_grace_period, is_trial=e.is_trial,
            )
            for e in ent.entitlements
        ],
        owned_assets=ent.owned_assets,
        credits=CreditsOut(allowance=balance.allowance, purchased=balance.available, reserved=balance.reserved),
        checked_at=now,
    )


@router.get("/entitlements", response_model=EntitlementsOut)
async def get_entitlements(current: CustomerDep, db: DbDep) -> EntitlementsOut:
    """Source of truth for paid features. Clients cache it and refresh on launch and after purchases."""
    return await _entitlements_out(db, current)


class VerifyIn(BaseModel):
    provider: Annotated[str, StringConstraints(max_length=32)]
    store_product_id: Annotated[str, StringConstraints(min_length=1, max_length=128)]
    token: Annotated[str, StringConstraints(min_length=10, max_length=8192)]


class VerifyOut(BaseModel):
    state: str
    product_id: str
    entitlements: EntitlementsOut


async def _verify(body: VerifyIn, current: CustomerDep, db: DbDep, *, allow_transfer: bool) -> VerifyOut:
    provider = get_provider(body.provider)
    try:
        purchase = await provider.verify_purchase(body.store_product_id, body.token)
    except ProviderError as exc:
        raise bad_request(exc.code) from exc
    try:
        result = await apply_verified_purchase(
            db, current.customer, purchase, allow_transfer=allow_transfer, actor=f"customer:{current.id}"
        )
    except BillingError as exc:
        await db.rollback()
        raise ApiError(exc.status, exc.code) from exc
    if result.state == "granted":
        try:
            await provider.acknowledge(purchase, body.token)
        except ProviderError:
            # Entitlement is already recorded; acknowledgement is retried on the next sync/notification.
            logger.warning("acknowledge failed for %s purchase %s", body.provider, result.product_id)
    return VerifyOut(state=result.state, product_id=result.product_id, entitlements=await _entitlements_out(db, current))


@router.post("/purchases/verify", response_model=VerifyOut)
async def verify_purchase(body: VerifyIn, current: CustomerDep, db: DbDep) -> VerifyOut:
    """Called by the app after the store reports a purchase. Access is granted only from this server-side check."""
    await rate_limit(f"verify:{current.id}")
    return await _verify(body, current, db, allow_transfer=False)


class RestoreIn(BaseModel):
    purchases: Annotated[list[VerifyIn], Field(min_length=1, max_length=50)]


class RestoreOut(BaseModel):
    results: list[dict[str, str]]
    entitlements: EntitlementsOut


@router.post("/purchases/restore", response_model=RestoreOut)
async def restore_purchases(body: RestoreIn, current: CustomerDep, db: DbDep) -> RestoreOut:
    """Re-verifies the store's purchase history and moves it onto this customer (reinstall / new device).
    The store account is the proof of ownership, so transfers are allowed here and audited."""
    await rate_limit(f"restore:{current.id}", limit=10)
    results = []
    for item in body.purchases:
        try:
            outcome = await _verify(item, current, db, allow_transfer=True)
            results.append({"store_product_id": item.store_product_id, "state": outcome.state})
        except ApiError as exc:
            detail = exc.detail if isinstance(exc.detail, dict) else {"code": str(exc.detail)}
            results.append({"store_product_id": item.store_product_id, "state": "error", "code": detail.get("code", "")})
    return RestoreOut(results=results, entitlements=await _entitlements_out(db, current))


@router.post("/webhooks/{provider_name}")
async def provider_webhook(provider_name: str, request: Request, db: DbDep) -> dict[str, int]:
    """Store server notifications. Authenticated by the provider (signature/OIDC), idempotent per event id."""
    provider = get_provider(provider_name)
    body = await request.body()
    if len(body) > 256 * 1024:
        raise bad_request("PAYLOAD_TOO_LARGE")
    try:
        events = await provider.parse_notification(request.headers, body)
    except ProviderError as exc:
        raise ApiError(401, exc.code) from exc
    processed = duplicates = 0
    for event in events:
        outcome = await process_event(db, event)
        if outcome is None:
            duplicates += 1
        else:
            processed += 1
    return {"processed": processed, "duplicates": duplicates}
