"""AI credit ledger, admin RBAC, metrics and security tests."""

import asyncio
import logging
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from app.models import AdminRole, AdminUser, AiUsage, AuditLog, CreditReservation
from app.security import new_secret, redact, sha256_hex
from app.services import credits
from tests.conftest import mock_token

pytestmark = pytest.mark.asyncio(loop_scope="session")


async def _customer_with_credits(new_customer, session_factory, purchased: int = 0, allowance: int = 0):
    c = await new_customer()
    cid = uuid.UUID(c.id)
    async with session_factory() as db:
        if purchased:
            await credits.add_purchased(db, cid, purchased, "seed")
        if allowance:
            await credits.reset_allowance(db, cid, allowance, "seed-period")
        await db.commit()
    return c, cid


async def test_concurrent_spending_never_overdraws(new_customer, session_factory):
    _, cid = await _customer_with_credits(new_customer, session_factory, purchased=60, allowance=40)

    async def attempt(i: int) -> bool:
        async with session_factory() as db:
            try:
                await credits.reserve(db, cid, 10, f"req-{i}")
                return True
            except credits.InsufficientCredits:
                return False

    results = await asyncio.gather(*(attempt(i) for i in range(25)))
    assert sum(results) == 10
    async with session_factory() as db:
        balance = await credits.get_balance(db, cid)
        assert (balance.allowance, balance.available, balance.reserved) == (0, 0, 100)
        assert await credits.ledger_consistent(db, cid)


async def test_reservation_is_idempotent_per_key(new_customer, session_factory):
    _, cid = await _customer_with_credits(new_customer, session_factory, purchased=50)

    async def same_key() -> uuid.UUID:
        async with session_factory() as db:
            return (await credits.reserve(db, cid, 20, "same")).id

    ids = await asyncio.gather(*(same_key() for _ in range(5)))
    assert len(set(ids)) == 1
    async with session_factory() as db:
        assert (await credits.get_balance(db, cid)).available == 30


async def test_settle_charges_used_and_returns_rest_allowance_first(new_customer, session_factory):
    _, cid = await _customer_with_credits(new_customer, session_factory, purchased=100, allowance=30)
    async with session_factory() as db:
        res = await credits.reserve(db, cid, 50, "s1")
    assert (res.from_allowance, res.from_available) == (30, 20)
    async with session_factory() as db:
        usage = AiUsage(customer_id=cid, reservation_id=res.id, feature="rewrite", model="test", input_tokens=10, output_tokens=20, cost_micros=1500)
        await credits.settle(db, res.id, 35, usage)
    async with session_factory() as db:
        balance = await credits.get_balance(db, cid)
        # 35 used: 30 from allowance, 5 from purchased; 15 purchased returned.
        assert (balance.allowance, balance.available, balance.reserved) == (0, 95, 0)
        # Settling twice and over-charging are both impossible.
        again = await credits.settle(db, res.id, 50)
        assert again.settled_amount == 35
        assert (await credits.get_balance(db, cid)).available == 95
        assert await credits.ledger_consistent(db, cid)
        assert (await db.scalar(select(AiUsage))).credits == 35


async def test_provider_failure_or_timeout_releases_credits(new_customer, session_factory):
    _, cid = await _customer_with_credits(new_customer, session_factory, purchased=40)

    async def failing_ai_call() -> str:
        await asyncio.sleep(0.01)
        raise TimeoutError("provider timed out")

    async with session_factory() as db:
        res = await credits.reserve(db, cid, 25, "t1")
    try:
        await asyncio.wait_for(failing_ai_call(), timeout=1)
    except TimeoutError:
        async with session_factory() as db:
            await credits.release(db, res.id, reason="provider_timeout")
    async with session_factory() as db:
        assert (await credits.get_balance(db, cid)).available == 40
        # A late settle after release cannot charge the customer.
        await credits.settle(db, res.id, 25)
        assert (await credits.get_balance(db, cid)).available == 40
        assert await credits.ledger_consistent(db, cid)


async def test_abandoned_reservations_are_swept(new_customer, session_factory):
    _, cid = await _customer_with_credits(new_customer, session_factory, purchased=10)
    async with session_factory() as db:
        await credits.reserve(db, cid, 10, "lost", ttl_seconds=1)
    async with session_factory() as db:
        released = await credits.release_expired(db, now=datetime.now(UTC) + timedelta(seconds=5))
    assert released == 1
    async with session_factory() as db:
        assert (await credits.get_balance(db, cid)).available == 10
        assert (await db.scalar(select(CreditReservation))).status == "released"


async def test_ai_budget_kill_switch(new_customer, session_factory):
    _, cid = await _customer_with_credits(new_customer, session_factory, purchased=10)
    async with session_factory() as db:
        assert not await credits.ai_budget_allows(db, 0)
        assert await credits.ai_budget_allows(db, 5_000)
        db.add(AiUsage(customer_id=cid, reservation_id=uuid.uuid4(), feature="rewrite", model="m", cost_micros=6_000))
        await db.commit()
        assert not await credits.ai_budget_allows(db, 5_000)


async def _admin(session_factory, role: AdminRole) -> dict[str, str]:
    key = new_secret()
    async with session_factory() as db:
        db.add(AdminUser(name=f"{role.value}-{key[:6]}", key_hash=sha256_hex(key), role=role))
        await db.commit()
    return {"X-Admin-Key": key}


async def test_admin_rbac_and_audit(new_customer, client, session_factory):
    c = await new_customer()
    viewer = await _admin(session_factory, AdminRole.VIEWER)
    support = await _admin(session_factory, AdminRole.SUPPORT)
    finance = await _admin(session_factory, AdminRole.FINANCE)
    override = {"entitlement": "pro", "expires_at": (datetime.now(UTC) + timedelta(days=7)).isoformat(), "reason": "support compensation"}

    assert (await client.get("/v1/admin/metrics")).status_code == 401
    assert (await client.get("/v1/admin/metrics", headers={"X-Admin-Key": "guess"})).status_code == 401
    assert (await client.get("/v1/admin/metrics", headers=viewer)).status_code == 200
    assert (await client.post(f"/v1/admin/customers/{c.id}/overrides", json=override, headers=viewer)).status_code == 403
    goodwill = {"amount": 50, "reference": "r1", "reason": "goodwill"}
    assert (await client.post(f"/v1/admin/customers/{c.id}/credits", json=goodwill, headers=support)).status_code == 403
    assert (await client.get("/v1/admin/audit", headers=finance)).status_code == 403

    granted = await client.post(f"/v1/admin/customers/{c.id}/overrides", json=override, headers=support)
    assert granted.status_code == 201
    assert await c.has("pro")
    adjusted = await client.post(f"/v1/admin/customers/{c.id}/credits", json={"amount": 50, "reference": "r1", "reason": "goodwill"}, headers=finance)
    assert adjusted.json()["purchased"] == 50
    # Same reference = same adjustment (idempotent).
    await client.post(f"/v1/admin/customers/{c.id}/credits", json={"amount": 50, "reference": "r1", "reason": "goodwill"}, headers=finance)
    assert (await c.entitlements())["credits"]["purchased"] == 50
    negative = await client.post(f"/v1/admin/customers/{c.id}/credits", json={"amount": -500, "reference": "r2", "reason": "correction"}, headers=finance)
    assert negative.json()["detail"]["code"] == "CREDITS_WOULD_GO_NEGATIVE"

    revoke = await client.delete(f"/v1/admin/overrides/{granted.json()['id']}", headers=support)
    assert revoke.status_code == 204
    assert not await c.has("pro")
    async with session_factory() as db:
        actions = [a.action for a in await db.scalars(select(AuditLog).order_by(AuditLog.id))]
    assert actions == ["override_granted", "credits_adjusted", "override_revoked"]


async def test_metrics_come_from_verified_transactions(new_customer, client, session_factory):
    a = await new_customer()
    b = await new_customer()
    await new_customer()  # free user
    for customer, product, ext, price in ((a, "sado_pro_monthly", "m-a", 14_900), (b, "sado_pro_yearly", "m-b", 149_000)):
        token = mock_token(product, ext, price=price, expires_at=datetime.now(UTC) + timedelta(days=200))
        await customer.post("/v1/purchases/verify", json={"provider": "mock", "store_product_id": product, "token": token})
    # A failed verification adds nothing to revenue.
    await a.post("/v1/purchases/verify", json={"provider": "mock", "store_product_id": "sado_pro_monthly", "token": "forged-token-xyz"})
    owner = await _admin(session_factory, AdminRole.OWNER)
    m = (await client.get("/v1/admin/metrics", headers=owner)).json()
    assert m["active_subscribers"] == 2
    assert m["mrr_minor"] == {"UZS": 14_900 + round(149_000 / 12)}
    assert m["revenue_minor"] == {"UZS": 14_900 + 149_000}
    assert m["free_to_paid_conversion"] == round(2 / 3, 4)
    assert m["refund_rate"] == 0.0
    detail = (await client.get(f"/v1/admin/customers/{a.id}", headers=owner)).json()
    assert detail["subscriptions"][0]["external_id"].endswith("…")  # never the full store token


async def test_secrets_are_redacted_from_logs():
    from app.security import RedactingFilter

    logger = logging.getLogger("redaction-test")
    handler_filter = RedactingFilter()
    record = logger.makeRecord("t", logging.INFO, __file__, 1, "verify purchase_token=%s with Bearer %s", ("abc123secret", "eyJhbGciOi.payload12345.sig"), None)
    handler_filter.filter(record)
    message = record.getMessage()
    assert "abc123secret" not in message and "payload12345" not in message
    assert redact('{"api_hash": "0123456789abcdef"}') == '{"api_hash": "[REDACTED]"}'
