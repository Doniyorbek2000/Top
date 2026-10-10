"""Applies verified store facts (purchases and notifications) to subscriptions, purchases, revenue and credits."""

import logging
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.catalog import PRODUCTS, Product, ProductKind, product_by_store_id
from app.models import (
    Customer,
    EventStatus,
    ProviderEvent,
    Purchase,
    PurchaseStatus,
    Subscription,
    SubscriptionStatus,
    Transaction,
)
from app.providers.base import EventType, NormalizedEvent, PurchaseState, VerifiedPurchase
from app.services import credits
from app.services.audit import audit

logger = logging.getLogger(__name__)

STORE_PROVIDERS = {"google_play", "app_store"}


class BillingError(Exception):
    def __init__(self, code: str, status: int = 400) -> None:
        super().__init__(code)
        self.code = code
        self.status = status


@dataclass(slots=True)
class ApplyResult:
    state: str  # granted | pending | cancelled | expired
    product_id: str
    external_id: str
    transferred: bool = False


def _now() -> datetime:
    return datetime.now(UTC)


async def _record_transaction(
    db: AsyncSession, customer_id: uuid.UUID, provider: str, txn_id: str, kind: str,
    product_id: str, amount: int, currency: str, country: str, occurred_at: datetime,
) -> None:
    await db.execute(
        pg_insert(Transaction)
        .values(
            customer_id=customer_id, provider=provider, external_txn_id=txn_id, kind=kind,
            product_id=product_id, amount_minor=amount, currency=currency or "XXX", country=country,
            occurred_at=occurred_at,
        )
        .on_conflict_do_nothing(constraint="uq_transactions_provider_txn_kind")
    )


async def _record_charge(
    db: AsyncSession, customer_id: uuid.UUID, provider: str, txn_id: str, kind: str,
    product_id: str, amount: int, currency: str, country: str, occurred_at: datetime,
) -> None:
    """A store transaction is charged once, whether it first arrives via client verify or a notification.
    Callers hold the subscription/purchase row lock, so the existence check cannot race for the same item."""
    existing = await db.scalar(
        select(Transaction.id)
        .where(Transaction.provider == provider, Transaction.external_txn_id == txn_id, Transaction.kind != "refund")
        .limit(1)
    )
    if existing is None:
        await _record_transaction(db, customer_id, provider, txn_id, kind, product_id, amount, currency, country, occurred_at)


async def _grant_period_credits(db: AsyncSession, sub: Subscription, product: Product, period_ref: str) -> None:
    if product.monthly_ai_credits > 0:
        await credits.reset_allowance(db, sub.customer_id, product.monthly_ai_credits, f"{sub.id}:{period_ref}")


def _resolve_product(provider: str, store_product_id: str) -> Product:
    product = product_by_store_id(provider, store_product_id)
    if product is None:
        raise BillingError("PRODUCT_UNKNOWN")
    if provider in STORE_PROVIDERS and not product.in_app:
        raise BillingError("PRODUCT_NOT_SOLD_IN_APP")
    return product


async def _check_ownership(db: AsyncSession, customer: Customer, account_token: str | None, allow_transfer: bool) -> None:
    """The store echoes the account token we attached at purchase time; a mismatch means another Sado account."""
    if account_token is None or account_token == str(customer.store_account_token):
        return
    if not allow_transfer:
        raise BillingError("PURCHASE_BELONGS_TO_OTHER_ACCOUNT", 409)


async def apply_verified_purchase(
    db: AsyncSession, customer: Customer, purchase: VerifiedPurchase, *, allow_transfer: bool, actor: str
) -> ApplyResult:
    product = _resolve_product(purchase.provider, purchase.store_product_id)
    if purchase.state == PurchaseState.PENDING:
        return ApplyResult("pending", product.id, purchase.external_id)
    if purchase.state == PurchaseState.CANCELLED:
        return ApplyResult("cancelled", product.id, purchase.external_id)
    await _check_ownership(db, customer, purchase.account_token, allow_transfer)
    if product.kind == ProductKind.SUBSCRIPTION:
        if purchase.expires_at is None:
            raise BillingError("SUBSCRIPTION_EXPIRY_MISSING")
        result = await _apply_subscription(db, customer, product, purchase, allow_transfer=allow_transfer, actor=actor)
    else:
        result = await _apply_one_time(db, customer, product, purchase, allow_transfer=allow_transfer, actor=actor)
    await db.commit()
    return result


async def _apply_subscription(
    db: AsyncSession, customer: Customer, product: Product, p: VerifiedPurchase, *, allow_transfer: bool, actor: str
) -> ApplyResult:
    now = _now()
    assert p.expires_at is not None
    sub = await db.scalar(
        select(Subscription)
        .where(Subscription.provider == p.provider, Subscription.external_id == p.external_id)
        .with_for_update()
    )
    transferred = False
    if sub is None:
        sub = Subscription(
            customer_id=customer.id, provider=p.provider, external_id=p.external_id, product_id=product.id,
            status=SubscriptionStatus.EXPIRED, is_trial=p.is_trial, auto_renew=p.auto_renew,
            period_start=p.purchased_at, expires_at=p.expires_at, price_minor=p.price_minor,
            currency=p.currency, country=p.country, last_event_at=p.purchased_at,
        )
        db.add(sub)
        await db.flush()
        kind = "purchase"
    else:
        if sub.customer_id != customer.id:
            if not allow_transfer:
                raise BillingError("PURCHASE_BELONGS_TO_OTHER_ACCOUNT", 409)
            audit(db, actor, "subscription_transferred", str(sub.id), from_customer=sub.customer_id, to_customer=customer.id)
            sub.customer_id = customer.id
            transferred = True
        kind = "renewal"
        if p.purchased_at >= sub.last_event_at:
            sub.expires_at = max(sub.expires_at, p.expires_at)
            sub.auto_renew = p.auto_renew
            sub.is_trial = p.is_trial
            sub.product_id = product.id  # upgrades/downgrades within a group replace the product
            sub.period_start = p.purchased_at
            sub.last_event_at = p.purchased_at
    if sub.status not in (SubscriptionStatus.REFUNDED, SubscriptionStatus.REVOKED):
        if sub.expires_at <= now:
            sub.status = SubscriptionStatus.EXPIRED
        else:
            sub.status = SubscriptionStatus.ACTIVE if sub.auto_renew else SubscriptionStatus.CANCELLED
    await _record_charge(
        db, sub.customer_id, p.provider, p.transaction_id, kind, product.id,
        0 if p.is_trial else p.price_minor, p.currency, p.country, p.purchased_at,
    )
    granted = sub.status in (SubscriptionStatus.ACTIVE, SubscriptionStatus.CANCELLED)
    if granted:
        await _grant_period_credits(db, sub, product, p.transaction_id)
    return ApplyResult("granted" if granted else "expired", product.id, p.external_id, transferred)


async def _apply_one_time(
    db: AsyncSession, customer: Customer, product: Product, p: VerifiedPurchase, *, allow_transfer: bool, actor: str
) -> ApplyResult:
    purchase = await db.scalar(
        select(Purchase).where(Purchase.provider == p.provider, Purchase.external_id == p.external_id).with_for_update()
    )
    transferred = False
    if purchase is None:
        purchase = Purchase(
            customer_id=customer.id, provider=p.provider, external_id=p.external_id, product_id=product.id,
            status=PurchaseStatus.COMPLETED, purchased_at=p.purchased_at, price_minor=p.price_minor,
            currency=p.currency, country=p.country,
        )
        db.add(purchase)
    elif purchase.customer_id != customer.id:
        if not allow_transfer:
            raise BillingError("PURCHASE_BELONGS_TO_OTHER_ACCOUNT", 409)
        audit(db, actor, "purchase_transferred", str(purchase.id), from_customer=purchase.customer_id, to_customer=customer.id)
        purchase.customer_id = customer.id
        transferred = True
    await _record_charge(
        db, purchase.customer_id, p.provider, p.transaction_id, "purchase", product.id,
        p.price_minor, p.currency, p.country, p.purchased_at,
    )
    state = "granted" if purchase.status == PurchaseStatus.COMPLETED else purchase.status.value
    return ApplyResult(state, product.id, p.external_id, transferred)


# ------------------------------------------------------------------ notifications


async def process_event(db: AsyncSession, event: NormalizedEvent) -> EventStatus | None:
    """Applies one verified notification. Returns None for a duplicate (already processed) event."""
    inserted = await db.execute(
        pg_insert(ProviderEvent)
        .values(
            provider=event.provider, event_id=event.event_id, event_type=event.type.value,
            external_id=event.external_id, occurred_at=event.occurred_at, status=EventStatus.PROCESSED,
        )
        .on_conflict_do_nothing(constraint="uq_provider_events_provider_event")
        .returning(ProviderEvent.id)
    )
    event_row_id = inserted.scalar_one_or_none()
    if event_row_id is None:
        await db.rollback()
        return None
    status, detail = await _apply_event(db, event)
    row = await db.get(ProviderEvent, event_row_id)
    assert row is not None
    row.status = status
    row.detail = detail
    await db.commit()
    return status


async def _apply_event(db: AsyncSession, event: NormalizedEvent) -> tuple[EventStatus, str]:
    if event.type == EventType.TEST:
        return EventStatus.IGNORED, "test notification"

    one_time = await db.scalar(
        select(Purchase).where(Purchase.provider == event.provider, Purchase.external_id == event.external_id).with_for_update()
    )
    if one_time is not None:
        return await _apply_one_time_event(db, one_time, event)

    sub = await db.scalar(
        select(Subscription)
        .where(Subscription.provider == event.provider, Subscription.external_id == event.external_id)
        .with_for_update()
    )
    if sub is None:
        sub = await _create_from_event(db, event)
        if sub is None:
            # The client has not verified this purchase yet and the event cannot identify the customer.
            # Real providers re-fetch full state from the store here (phase B).
            return EventStatus.IGNORED, "unknown subscription"

    product = product_by_store_id(event.provider, event.store_product_id or "") if event.store_product_id else None
    product_id = product.id if product else sub.product_id

    # Money events are recorded even when they arrive late; state changes are not regressed.
    if event.type in (EventType.PURCHASED, EventType.RENEWED, EventType.RECOVERED) and event.transaction_id:
        await _record_charge(
            db, sub.customer_id, event.provider, event.transaction_id,
            "purchase" if event.type == EventType.PURCHASED else "renewal",
            product_id, event.amount_minor, event.currency or sub.currency, event.country or sub.country, event.occurred_at,
        )
    if event.type == EventType.REFUNDED and event.transaction_id:
        await _record_transaction(
            db, sub.customer_id, event.provider, event.transaction_id, "refund",
            sub.product_id, -abs(event.amount_minor or sub.price_minor), event.currency or sub.currency,
            event.country or sub.country, event.occurred_at,
        )

    terminal = event.type in (EventType.REFUNDED, EventType.REVOKED)
    if not terminal and event.occurred_at < sub.last_event_at:
        return EventStatus.IGNORED, "stale event (out of order)"
    if sub.status in (SubscriptionStatus.REFUNDED, SubscriptionStatus.REVOKED) and not terminal:
        return EventStatus.IGNORED, "subscription already refunded or revoked"

    sub.last_event_at = max(sub.last_event_at, event.occurred_at)
    match event.type:
        case EventType.PURCHASED | EventType.RENEWED | EventType.RECOVERED:
            if event.expires_at is not None:
                sub.expires_at = max(sub.expires_at, event.expires_at)
            sub.period_start = event.occurred_at
            sub.status = SubscriptionStatus.ACTIVE
            sub.auto_renew = True
            sub.grace_until = None
            if event.type != EventType.PURCHASED:
                sub.is_trial = False  # a renewal is a paid period
            if product is not None:
                sub.product_id = product.id
            await _grant_period_credits(db, sub, PRODUCTS[sub.product_id], event.transaction_id or event.event_id)
        case EventType.AUTO_RENEW_OFF:
            sub.auto_renew = False
            if sub.status == SubscriptionStatus.ACTIVE:
                sub.status = SubscriptionStatus.CANCELLED
        case EventType.AUTO_RENEW_ON:
            sub.auto_renew = True
            if sub.status == SubscriptionStatus.CANCELLED:
                sub.status = SubscriptionStatus.ACTIVE
        case EventType.GRACE_PERIOD:
            sub.status = SubscriptionStatus.IN_GRACE
            sub.grace_until = event.grace_until or event.expires_at
        case EventType.BILLING_RETRY:
            sub.status = SubscriptionStatus.BILLING_RETRY
            sub.grace_until = None
        case EventType.PAUSED:
            sub.status = SubscriptionStatus.PAUSED
        case EventType.EXPIRED:
            sub.status = SubscriptionStatus.EXPIRED
            sub.auto_renew = False
        case EventType.REFUNDED | EventType.REVOKED:
            sub.status = SubscriptionStatus.REFUNDED if event.type == EventType.REFUNDED else SubscriptionStatus.REVOKED
            sub.auto_renew = False
            await credits.revoke_allowance(db, sub.customer_id, f"{sub.id}:{event.event_id}")
            audit(db, f"provider:{event.provider}", f"subscription_{event.type.value}", str(sub.id), customer=sub.customer_id)
        case _:
            return EventStatus.IGNORED, f"unhandled event {event.type.value}"
    return EventStatus.PROCESSED, ""


async def _create_from_event(db: AsyncSession, event: NormalizedEvent) -> Subscription | None:
    if event.type not in (EventType.PURCHASED, EventType.RENEWED) or not event.account_token or not event.store_product_id:
        return None
    try:
        token = uuid.UUID(event.account_token)
    except ValueError:
        return None
    customer = await db.scalar(select(Customer).where(Customer.store_account_token == token))
    product = product_by_store_id(event.provider, event.store_product_id)
    if customer is None or product is None or event.expires_at is None:
        return None
    sub = Subscription(
        customer_id=customer.id, provider=event.provider, external_id=event.external_id, product_id=product.id,
        status=SubscriptionStatus.EXPIRED, auto_renew=True, period_start=event.occurred_at,
        expires_at=event.expires_at, price_minor=event.amount_minor, currency=event.currency,
        country=event.country, last_event_at=datetime.min.replace(tzinfo=UTC),
    )
    db.add(sub)
    await db.flush()
    return sub


async def _apply_one_time_event(db: AsyncSession, purchase: Purchase, event: NormalizedEvent) -> tuple[EventStatus, str]:
    if event.type not in (EventType.REFUNDED, EventType.REVOKED):
        return EventStatus.IGNORED, "no state change for one-time purchase"
    purchase.status = PurchaseStatus.REFUNDED if event.type == EventType.REFUNDED else PurchaseStatus.REVOKED
    if event.type == EventType.REFUNDED:
        await _record_transaction(
            db, purchase.customer_id, event.provider, event.transaction_id or purchase.external_id, "refund",
            purchase.product_id, -abs(event.amount_minor or purchase.price_minor), event.currency or purchase.currency,
            event.country or purchase.country, event.occurred_at,
        )
    audit(db, f"provider:{event.provider}", f"purchase_{event.type.value}", str(purchase.id), customer=purchase.customer_id)
    return EventStatus.PROCESSED, ""
