"""Monetization metrics computed only from verified store data (subscriptions, transactions, AI usage).

Amounts are reported per currency; no FX conversion is applied (rates must come from finance).
No Telegram data of any kind is used here.
"""

from collections import defaultdict
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.catalog import PRODUCTS, Entitlement
from app.models import AiUsage, Customer, Subscription, SubscriptionStatus, Transaction

_PAYING = (SubscriptionStatus.ACTIVE, SubscriptionStatus.IN_GRACE)
_ACCESS = (SubscriptionStatus.ACTIVE, SubscriptionStatus.IN_GRACE, SubscriptionStatus.CANCELLED)
_CHURNED = (SubscriptionStatus.EXPIRED, SubscriptionStatus.REFUNDED, SubscriptionStatus.REVOKED)


async def compute_metrics(db: AsyncSession, now: datetime | None = None, window_days: int = 30) -> dict[str, Any]:
    now = now or datetime.now(UTC)
    since = now - timedelta(days=window_days)

    subs = list(await db.scalars(select(Subscription)))
    active = [s for s in subs if s.status in _ACCESS and s.expires_at > now]
    renewing = [s for s in subs if s.status in _PAYING and s.expires_at > now and not s.is_trial]

    mrr: dict[str, float] = defaultdict(float)
    for sub in renewing:
        product = PRODUCTS.get(sub.product_id)
        months = product.period_months if product and product.period_months else 1
        mrr[sub.currency] += sub.price_minor / months

    active_by_product: dict[str, int] = defaultdict(int)
    for sub in active:
        active_by_product[sub.product_id] += 1

    churned = [s for s in subs if s.status in _CHURNED and s.updated_at >= since]
    churn_base = len(active) + len(churned)
    retrying = [s for s in subs if s.status in (SubscriptionStatus.IN_GRACE, SubscriptionStatus.BILLING_RETRY)]

    txns = list(await db.scalars(select(Transaction).where(Transaction.occurred_at >= since)))
    revenue: dict[str, int] = defaultdict(int)
    revenue_by_product: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    revenue_by_country: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    business_revenue: dict[str, int] = defaultdict(int)
    charges = refunds = 0
    paying_customers = set()
    for t in txns:
        revenue[t.currency] += t.amount_minor
        revenue_by_product[t.product_id][t.currency] += t.amount_minor
        revenue_by_country[t.country or "??"][t.currency] += t.amount_minor
        product = PRODUCTS.get(t.product_id)
        if product and Entitlement.BUSINESS in product.entitlements:
            business_revenue[t.currency] += t.amount_minor
        if t.kind == "refund":
            refunds += 1
        elif t.amount_minor > 0:
            charges += 1
            paying_customers.add(t.customer_id)

    arppu = {cur: round(total / len(paying_customers)) for cur, total in revenue.items()} if paying_customers else {}

    total_customers = int(await db.scalar(select(func.count()).select_from(Customer).where(Customer.deleted_at.is_(None))) or 0)
    ever_paid = int(await db.scalar(
        select(func.count(func.distinct(Transaction.customer_id))).where(Transaction.amount_minor > 0)
    ) or 0)

    ai_cost = int(await db.scalar(select(func.coalesce(func.sum(AiUsage.cost_micros), 0)).where(AiUsage.created_at >= since)) or 0)
    ai_credits = int(await db.scalar(select(func.coalesce(func.sum(AiUsage.credits), 0)).where(AiUsage.created_at >= since)) or 0)
    ai_revenue = {
        cur: amount
        for product_id, by_cur in revenue_by_product.items()
        if Entitlement.AI_WRITER in PRODUCTS.get(product_id, PRODUCTS["sado_pro_monthly"]).entitlements
        for cur, amount in by_cur.items()
    }

    return {
        "generated_at": now.isoformat(),
        "window_days": window_days,
        "active_subscribers": len(active),
        "active_by_product": dict(active_by_product),
        "trialing": sum(1 for s in active if s.is_trial),
        "mrr_minor": {cur: round(v) for cur, v in mrr.items()},
        "arr_minor": {cur: round(v * 12) for cur, v in mrr.items()},
        "revenue_minor": dict(revenue),
        "revenue_by_product": {k: dict(v) for k, v in revenue_by_product.items()},
        "revenue_by_country": {k: dict(v) for k, v in revenue_by_country.items()},
        "business_revenue_minor": dict(business_revenue),
        "arppu_minor": arppu,
        "churn_rate": round(len(churned) / churn_base, 4) if churn_base else 0.0,
        "refund_rate": round(refunds / charges, 4) if charges else 0.0,
        "payment_failure_rate": round(len(retrying) / (len(active) + len(retrying)), 4) if (active or retrying) else 0.0,
        "free_to_paid_conversion": round(ever_paid / total_customers, 4) if total_customers else 0.0,
        "customers": total_customers,
        "ai_cost_micros_usd": ai_cost,
        "ai_credits_used": ai_credits,
        # Margin needs FX: revenue is in store currencies, provider cost in USD. Reported side by side.
        "ai_revenue_minor": ai_revenue,
    }
