import uuid
from datetime import UTC, datetime
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Query, status
from pydantic import BaseModel, Field, StringConstraints
from sqlalchemy import select

from app.catalog import Entitlement
from app.deps import DbDep, require_admin
from app.errors import bad_request, not_found
from app.models import AdminRole, AdminUser, AuditLog, Customer, EntitlementOverride, Purchase, Subscription
from app.services import credits
from app.services.audit import audit
from app.services.entitlements import load_entitlements
from app.services.metrics import compute_metrics

router = APIRouter(prefix="/v1/admin", tags=["admin"])

Viewer = Annotated[AdminUser, Depends(require_admin(AdminRole.VIEWER))]
Support = Annotated[AdminUser, Depends(require_admin(AdminRole.SUPPORT))]
Finance = Annotated[AdminUser, Depends(require_admin(AdminRole.FINANCE))]


@router.get("/metrics")
async def metrics(admin: Viewer, db: DbDep, window_days: Annotated[int, Query(ge=1, le=366)] = 30) -> dict[str, Any]:
    return await compute_metrics(db, window_days=window_days)


@router.get("/customers/{customer_id}")
async def customer_detail(customer_id: uuid.UUID, admin: Support, db: DbDep) -> dict[str, Any]:
    customer = await db.get(Customer, customer_id)
    if customer is None:
        raise not_found("CUSTOMER_NOT_FOUND")
    audit(db, f"admin:{admin.name}", "customer_viewed", str(customer_id))
    await db.commit()
    now = datetime.now(UTC)
    ent = await load_entitlements(db, customer_id, now)
    subs = list(await db.scalars(select(Subscription).where(Subscription.customer_id == customer_id)))
    purchases = list(await db.scalars(select(Purchase).where(Purchase.customer_id == customer_id)))
    balance = await credits.get_balance(db, customer_id)
    return {
        "customer_id": str(customer.id),
        "region": customer.region,
        "created_at": customer.created_at.isoformat(),
        "deleted": customer.deleted_at is not None,
        "tier": ent.tier,
        "entitlements": [
            {"entitlement": e.entitlement, "source": e.source, "product_id": e.product_id, "expires_at": e.expires_at.isoformat()}
            for e in ent.entitlements
        ],
        # Store ids are truncated: support needs to match them, not to replay them.
        "subscriptions": [
            {
                "id": str(s.id), "provider": s.provider, "external_id": s.external_id[:12] + "…", "product_id": s.product_id,
                "status": s.status.value, "expires_at": s.expires_at.isoformat(), "auto_renew": s.auto_renew,
            }
            for s in subs
        ],
        "purchases": [{"id": str(p.id), "product_id": p.product_id, "status": p.status.value} for p in purchases],
        "credits": {"allowance": balance.allowance, "purchased": balance.available, "reserved": balance.reserved},
    }


class OverrideIn(BaseModel):
    entitlement: Entitlement
    expires_at: datetime
    reason: Annotated[str, StringConstraints(min_length=5, max_length=256)]


@router.post("/customers/{customer_id}/overrides", status_code=status.HTTP_201_CREATED)
async def grant_override(customer_id: uuid.UUID, body: OverrideIn, admin: Support, db: DbDep) -> dict[str, str]:
    if await db.get(Customer, customer_id) is None:
        raise not_found("CUSTOMER_NOT_FOUND")
    if body.expires_at <= datetime.now(UTC):
        raise bad_request("OVERRIDE_EXPIRY_IN_PAST")
    override = EntitlementOverride(
        customer_id=customer_id, entitlement=body.entitlement.value, expires_at=body.expires_at,
        reason=body.reason, granted_by=admin.name,
    )
    db.add(override)
    await db.flush()
    audit(db, f"admin:{admin.name}", "override_granted", str(customer_id),
          override=override.id, entitlement=body.entitlement.value, expires_at=body.expires_at, reason=body.reason)
    await db.commit()
    return {"id": str(override.id)}


@router.delete("/overrides/{override_id}", status_code=status.HTTP_204_NO_CONTENT)
async def revoke_override(override_id: uuid.UUID, admin: Support, db: DbDep) -> None:
    override = await db.get(EntitlementOverride, override_id)
    if override is None:
        raise not_found("OVERRIDE_NOT_FOUND")
    override.revoked_at = datetime.now(UTC)
    audit(db, f"admin:{admin.name}", "override_revoked", str(override.customer_id), override=override_id)
    await db.commit()


class CreditAdjustIn(BaseModel):
    amount: Annotated[int, Field(ge=-100_000, le=100_000)]
    reference: Annotated[str, StringConstraints(min_length=2, max_length=64, pattern=r"^[A-Za-z0-9._:-]+$")]
    reason: Annotated[str, StringConstraints(min_length=5, max_length=256)]


@router.post("/customers/{customer_id}/credits")
async def adjust_credits(customer_id: uuid.UUID, body: CreditAdjustIn, admin: Finance, db: DbDep) -> dict[str, int]:
    if body.amount == 0:
        raise bad_request("AMOUNT_ZERO")
    if await db.get(Customer, customer_id) is None:
        raise not_found("CUSTOMER_NOT_FOUND")
    try:
        applied = await credits.add_purchased(db, customer_id, body.amount, f"admin:{body.reference}", kind="adjust")
    except credits.InsufficientCredits as exc:
        await db.rollback()
        raise bad_request("CREDITS_WOULD_GO_NEGATIVE") from exc
    if applied:
        audit(db, f"admin:{admin.name}", "credits_adjusted", str(customer_id), amount=body.amount, reason=body.reason)
    await db.commit()
    balance = await credits.get_balance(db, customer_id)
    return {"allowance": balance.allowance, "purchased": balance.available, "reserved": balance.reserved}


@router.get("/audit")
async def audit_log(
    admin: Annotated[AdminUser, Depends(require_admin(AdminRole.OWNER))],
    db: DbDep,
    limit: Annotated[int, Query(ge=1, le=500)] = 100,
) -> list[dict[str, Any]]:
    rows = await db.scalars(select(AuditLog).order_by(AuditLog.id.desc()).limit(limit))
    return [
        {"id": r.id, "actor": r.actor, "action": r.action, "target": r.target, "details": r.details, "at": r.created_at.isoformat()}
        for r in rows
    ]
