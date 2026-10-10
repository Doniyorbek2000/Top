"""Entitlement engine: derives what a customer may use from verified store state and admin overrides."""

import uuid
from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.catalog import PRODUCTS, Entitlement
from app.models import (
    CreditAccount,
    EntitlementOverride,
    Purchase,
    PurchaseStatus,
    Subscription,
    SubscriptionStatus,
)

# Statuses that still grant access while the paid period (or grace period) lasts.
_ACCESS_STATUSES = {SubscriptionStatus.ACTIVE, SubscriptionStatus.CANCELLED, SubscriptionStatus.IN_GRACE}


def subscription_grants_access(sub: Subscription, now: datetime) -> bool:
    if sub.status not in _ACCESS_STATUSES:
        return False
    if sub.status == SubscriptionStatus.IN_GRACE and sub.grace_until is not None:
        return sub.grace_until > now
    return sub.expires_at > now


@dataclass(slots=True)
class EntitlementView:
    entitlement: str
    expires_at: datetime
    source: str  # subscription | override
    product_id: str | None = None
    will_renew: bool = False
    in_grace_period: bool = False
    is_trial: bool = False


@dataclass(slots=True)
class CustomerEntitlements:
    tier: str
    entitlements: list[EntitlementView] = field(default_factory=list)
    owned_assets: list[str] = field(default_factory=list)

    def has(self, entitlement: Entitlement) -> bool:
        return any(e.entitlement == entitlement.value for e in self.entitlements)


def compute_entitlements(
    subscriptions: Iterable[Subscription],
    purchases: Iterable[Purchase],
    overrides: Iterable[EntitlementOverride],
    now: datetime,
) -> CustomerEntitlements:
    best: dict[str, EntitlementView] = {}

    def offer(view: EntitlementView) -> None:
        current = best.get(view.entitlement)
        if current is None or view.expires_at > current.expires_at:
            best[view.entitlement] = view

    for sub in subscriptions:
        if not subscription_grants_access(sub, now):
            continue
        product = PRODUCTS.get(sub.product_id)
        if product is None:
            continue
        expires = sub.grace_until if sub.status == SubscriptionStatus.IN_GRACE and sub.grace_until else sub.expires_at
        for ent in product.entitlements:
            offer(EntitlementView(
                entitlement=ent.value,
                expires_at=expires,
                source="subscription",
                product_id=product.id,
                will_renew=sub.auto_renew and sub.status == SubscriptionStatus.ACTIVE,
                in_grace_period=sub.status == SubscriptionStatus.IN_GRACE,
                is_trial=sub.is_trial,
            ))
    for override in overrides:
        if override.revoked_at is None and override.expires_at > now:
            offer(EntitlementView(entitlement=override.entitlement, expires_at=override.expires_at, source="override"))

    assets = sorted({
        PRODUCTS[p.product_id].asset_id
        for p in purchases
        if p.status == PurchaseStatus.COMPLETED and p.product_id in PRODUCTS and PRODUCTS[p.product_id].asset_id
    })
    views = sorted(best.values(), key=lambda v: v.entitlement)
    names = {v.entitlement for v in views}
    tier = "business" if Entitlement.BUSINESS in names else ("pro" if Entitlement.PRO in names else "free")
    return CustomerEntitlements(tier=tier, entitlements=views, owned_assets=assets)


async def load_entitlements(db: AsyncSession, customer_id: uuid.UUID, now: datetime) -> CustomerEntitlements:
    subs = list(await db.scalars(select(Subscription).where(Subscription.customer_id == customer_id)))
    purchases = list(await db.scalars(select(Purchase).where(Purchase.customer_id == customer_id)))
    overrides = list(await db.scalars(select(EntitlementOverride).where(EntitlementOverride.customer_id == customer_id)))
    return compute_entitlements(subs, purchases, overrides, now)


async def credit_balance(db: AsyncSession, customer_id: uuid.UUID) -> CreditAccount | None:
    return await db.get(CreditAccount, customer_id)
