"""Purchase, subscription lifecycle and notification scenarios (Phase 9 test plan)."""

from datetime import timedelta

import pytest
from sqlalchemy import select, text

from app.models import ProviderEvent, Subscription, SubscriptionStatus, Transaction
from app.services.audit import audit
from tests.conftest import iso, mock_token, now, send_webhook

pytestmark = pytest.mark.asyncio(loop_scope="session")


async def verify(customer, product: str, token: str):
    return await customer.post("/v1/purchases/verify", json={"provider": "mock", "store_product_id": product, "token": token})


async def test_new_customer_is_free_tier(new_customer):
    c = await new_customer()
    ent = await c.entitlements()
    assert ent["tier"] == "free"
    assert ent["entitlements"] == []
    assert ent["credits"] == {"allowance": 0, "purchased": 0, "reserved": 0}


async def test_successful_purchase_grants_pro_and_records_revenue(new_customer, session_factory):
    c = await new_customer()
    resp = await verify(c, "sado_pro_monthly", mock_token("sado_pro_monthly", "sub-1", account_token=c.account_token))
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["state"] == "granted"
    assert body["entitlements"]["tier"] == "pro"
    assert body["entitlements"]["entitlements"][0]["will_renew"] is True
    async with session_factory() as db:
        txns = list(await db.scalars(select(Transaction)))
    assert [(t.kind, t.amount_minor, t.currency) for t in txns] == [("purchase", 14_900, "UZS")]

    # Verifying the same token again is idempotent (no duplicate revenue).
    again = await verify(c, "sado_pro_monthly", mock_token("sado_pro_monthly", "sub-1", account_token=c.account_token))
    assert again.status_code == 200
    async with session_factory() as db:
        assert len(list(await db.scalars(select(Transaction)))) == 1


async def test_invalid_tokens_are_rejected(new_customer):
    c = await new_customer()
    forged = mock_token("sado_pro_monthly", "sub-x")[:-4] + "abcd"
    assert (await verify(c, "sado_pro_monthly", forged)).json()["detail"]["code"] == "PURCHASE_TOKEN_INVALID"
    assert (await verify(c, "sado_pro_monthly", "not-a-token-at-all")).status_code == 400
    mismatch = await verify(c, "sado_pro_yearly", mock_token("sado_pro_monthly", "sub-y"))
    assert mismatch.json()["detail"]["code"] == "PURCHASE_PRODUCT_MISMATCH"
    unknown = await c.post("/v1/purchases/verify", json={"provider": "mock", "store_product_id": "nope", "token": mock_token("nope", "z")})
    assert unknown.json()["detail"]["code"] == "PRODUCT_UNKNOWN"
    assert not await c.has("pro")


async def test_pending_and_cancelled_purchases_grant_nothing(new_customer):
    c = await new_customer()
    pending = await verify(c, "sado_pro_monthly", mock_token("sado_pro_monthly", "p1", state="pending"))
    cancelled = await verify(c, "sado_pro_monthly", mock_token("sado_pro_monthly", "p2", state="cancelled"))
    assert pending.json()["state"] == "pending"
    assert cancelled.json()["state"] == "cancelled"
    assert (await c.entitlements())["tier"] == "free"


async def test_already_expired_purchase_grants_nothing(new_customer):
    c = await new_customer()
    token = mock_token("sado_pro_monthly", "old", purchased_at=now() - timedelta(days=40), expires_at=now() - timedelta(days=10))
    assert (await verify(c, "sado_pro_monthly", token)).json()["state"] == "expired"
    assert not await c.has("pro")


async def test_renewal_extends_access_and_resets_ai_allowance(new_customer, client, session_factory):
    from app.services import credits

    c = await new_customer()
    await verify(c, "sado_ai_writer_monthly", mock_token("sado_ai_writer_monthly", "ai-1", price=19_900))
    assert (await c.entitlements())["credits"]["allowance"] == 300
    async with session_factory() as db:
        res = await credits.reserve(db, c.id, 120, "k1")
    async with session_factory() as db:
        await credits.settle(db, res.id, 120)
    assert (await c.entitlements())["credits"]["allowance"] == 180

    new_expiry = now() + timedelta(days=60)
    resp = await send_webhook(client, {
        "event_id": "evt-renew-1", "type": "renewed", "external_id": "ai-1", "occurred_at": iso(now()),
        "expires_at": iso(new_expiry), "txn": "ai-1-txn2", "amount": 19_900, "currency": "UZS", "country": "UZ",
    })
    assert resp.status_code == 200 and resp.json() == {"processed": 1, "duplicates": 0}
    ent = await c.entitlements()
    assert ent["credits"]["allowance"] == 300  # reset, unused 180 expired
    assert ent["entitlements"][0]["expires_at"][:10] == new_expiry.date().isoformat()
    async with session_factory() as db:
        kinds = sorted(t.kind for t in await db.scalars(select(Transaction)))
        assert kinds == ["purchase", "renewal"]
        assert await credits.ledger_consistent(db, c.id)


async def test_expiry_event_removes_access(new_customer, client):
    c = await new_customer()
    await verify(c, "sado_pro_monthly", mock_token("sado_pro_monthly", "e-1"))
    await send_webhook(client, {"event_id": "evt-exp", "type": "expired", "external_id": "e-1", "occurred_at": iso(now())})
    assert (await c.entitlements())["tier"] == "free"


async def test_cancellation_keeps_access_until_period_end(new_customer, client):
    c = await new_customer()
    await verify(c, "sado_pro_monthly", mock_token("sado_pro_monthly", "c-1"))
    await send_webhook(client, {"event_id": "evt-off", "type": "auto_renew_off", "external_id": "c-1", "occurred_at": iso(now())})
    ent = await c.entitlements()
    assert ent["tier"] == "pro"
    assert ent["entitlements"][0]["will_renew"] is False


async def test_refund_revokes_access_credits_and_books_negative_revenue(new_customer, client, session_factory):
    c = await new_customer()
    await verify(c, "sado_ai_writer_monthly", mock_token("sado_ai_writer_monthly", "r-1", price=19_900))
    resp = await send_webhook(client, {
        "event_id": "evt-refund", "type": "refunded", "external_id": "r-1", "occurred_at": iso(now()),
        "txn": "r-1-txn1", "amount": 19_900, "currency": "UZS",
    })
    assert resp.status_code == 200
    ent = await c.entitlements()
    assert ent["tier"] == "free" and not ent["entitlements"]
    assert ent["credits"]["allowance"] == 0
    async with session_factory() as db:
        amounts = sorted(t.amount_minor for t in await db.scalars(select(Transaction)))
    assert amounts == [-19_900, 19_900]


async def test_revocation_removes_access(new_customer, client):
    c = await new_customer()
    await verify(c, "sado_pro_yearly", mock_token("sado_pro_yearly", "v-1", expires_at=now() + timedelta(days=365)))
    await send_webhook(client, {"event_id": "evt-revoke", "type": "revoked", "external_id": "v-1", "occurred_at": iso(now())})
    assert not await c.has("pro")
    # A later renewal notification cannot resurrect a revoked subscription.
    await send_webhook(client, {
        "event_id": "evt-late", "type": "renewed", "external_id": "v-1", "occurred_at": iso(now() + timedelta(seconds=5)),
        "expires_at": iso(now() + timedelta(days=400)), "txn": "v-1-txn2",
    })
    assert not await c.has("pro")


async def test_grace_period_keeps_access_then_billing_retry_removes_it(new_customer, client):
    c = await new_customer()
    await verify(c, "sado_pro_monthly", mock_token("sado_pro_monthly", "g-1", expires_at=now() + timedelta(seconds=2)))
    await send_webhook(client, {
        "event_id": "evt-grace", "type": "grace_period", "external_id": "g-1", "occurred_at": iso(now()),
        "grace_until": iso(now() + timedelta(days=3)),
    })
    ent = await c.entitlements()
    assert ent["tier"] == "pro" and ent["entitlements"][0]["in_grace_period"] is True
    await send_webhook(client, {"event_id": "evt-retry", "type": "billing_retry", "external_id": "g-1", "occurred_at": iso(now() + timedelta(seconds=1))})
    assert not await c.has("pro")
    await send_webhook(client, {
        "event_id": "evt-recovered", "type": "recovered", "external_id": "g-1", "occurred_at": iso(now() + timedelta(seconds=2)),
        "expires_at": iso(now() + timedelta(days=30)), "txn": "g-1-txn2", "amount": 14_900, "currency": "UZS",
    })
    assert await c.has("pro")


async def test_duplicate_webhooks_are_processed_once(new_customer, client, session_factory):
    c = await new_customer()
    await verify(c, "sado_pro_monthly", mock_token("sado_pro_monthly", "d-1"))
    payload = {
        "event_id": "evt-dup", "type": "renewed", "external_id": "d-1", "occurred_at": iso(now()),
        "expires_at": iso(now() + timedelta(days=60)), "txn": "d-1-txn2", "amount": 14_900, "currency": "UZS",
    }
    first = await send_webhook(client, payload)
    second = await send_webhook(client, payload)
    assert first.json() == {"processed": 1, "duplicates": 0}
    assert second.json() == {"processed": 0, "duplicates": 1}
    async with session_factory() as db:
        assert len([t for t in await db.scalars(select(Transaction)) if t.kind == "renewal"]) == 1
        assert len(list(await db.scalars(select(ProviderEvent)))) == 1


async def test_out_of_order_and_delayed_events(new_customer, client, session_factory):
    c = await new_customer()
    t0 = now()
    await verify(c, "sado_pro_monthly", mock_token("sado_pro_monthly", "o-1", purchased_at=t0 - timedelta(minutes=10)))
    # Newer renewal arrives first...
    await send_webhook(client, {
        "event_id": "evt-new", "type": "renewed", "external_id": "o-1", "occurred_at": iso(t0),
        "expires_at": iso(t0 + timedelta(days=60)), "txn": "o-1-txn2", "amount": 14_900, "currency": "UZS",
    })
    # ...then a delayed, older "auto renew off" must not override the newer state.
    await send_webhook(client, {"event_id": "evt-old", "type": "auto_renew_off", "external_id": "o-1", "occurred_at": iso(t0 - timedelta(minutes=5))})
    # ...and a delayed older renewal still books its revenue without shortening access.
    await send_webhook(client, {
        "event_id": "evt-older-renew", "type": "renewed", "external_id": "o-1", "occurred_at": iso(t0 - timedelta(minutes=1)),
        "expires_at": iso(t0 + timedelta(days=30)), "txn": "o-1-txn-late", "amount": 14_900, "currency": "UZS",
    })
    ent = await c.entitlements()
    assert ent["entitlements"][0]["will_renew"] is True
    assert ent["entitlements"][0]["expires_at"][:10] == (t0 + timedelta(days=60)).date().isoformat()
    async with session_factory() as db:
        events = {e.event_id: e.status.value for e in await db.scalars(select(ProviderEvent))}
        assert events["evt-old"] == "ignored"
        assert {t.external_txn_id for t in await db.scalars(select(Transaction))} == {"o-1-txn1", "o-1-txn2", "o-1-txn-late"}


async def test_webhook_for_unverified_purchase_creates_subscription_from_account_token(new_customer, client):
    c = await new_customer()
    resp = await send_webhook(client, {
        "event_id": "evt-first", "type": "purchased", "external_id": "w-1", "occurred_at": iso(now()),
        "expires_at": iso(now() + timedelta(days=30)), "txn": "w-1-txn1", "amount": 14_900, "currency": "UZS",
        "product": "sado_pro_monthly", "account_token": c.account_token,
    })
    assert resp.status_code == 200
    assert await c.has("pro")


async def test_webhook_signature_and_replay_protection(new_customer, client):
    payload = {"event_id": "evt-sig", "type": "test", "external_id": "x", "occurred_at": iso(now())}
    assert (await send_webhook(client, payload, secret="wrong-secret-wrong-secret-123")).json()["detail"]["code"] == "WEBHOOK_SIGNATURE_INVALID"
    stale = await send_webhook(client, payload, timestamp=int(now().timestamp()) - 3600)
    assert stale.status_code == 401 and stale.json()["detail"]["code"] == "WEBHOOK_REPLAY_REJECTED"
    unsigned = await client.post("/v1/webhooks/mock", content=b"{}")
    assert unsigned.status_code == 401
    assert (await send_webhook(client, payload)).status_code == 200


async def test_purchase_token_cannot_be_claimed_by_another_account_but_can_be_restored(new_customer):
    owner = await new_customer()
    thief = await new_customer()
    token = mock_token("sado_pro_monthly", "t-1", account_token=owner.account_token)
    assert (await verify(owner, "sado_pro_monthly", token)).json()["state"] == "granted"
    stolen = await verify(thief, "sado_pro_monthly", token)
    assert stolen.status_code == 409 and stolen.json()["detail"]["code"] == "PURCHASE_BELONGS_TO_OTHER_ACCOUNT"
    assert not await thief.has("pro")

    # Restore = the store account (proof of purchase) is now signed into a new install.
    reinstall = await new_customer()
    resp = await reinstall.post("/v1/purchases/restore", json={"purchases": [{"provider": "mock", "store_product_id": "sado_pro_monthly", "token": token}]})
    assert resp.status_code == 200, resp.text
    assert resp.json()["results"] == [{"store_product_id": "sado_pro_monthly", "state": "granted"}]
    assert await reinstall.has("pro")
    assert not await owner.has("pro")  # one active owner at a time


async def test_restore_reports_per_item_errors(new_customer):
    c = await new_customer()
    resp = await c.post("/v1/purchases/restore", json={"purchases": [
        {"provider": "mock", "store_product_id": "sado_pro_monthly", "token": mock_token("sado_pro_monthly", "rs-1")},
        {"provider": "mock", "store_product_id": "sado_pro_monthly", "token": "garbage-token-123"},
    ]})
    results = resp.json()["results"]
    assert results[0]["state"] == "granted"
    assert results[1] == {"store_product_id": "sado_pro_monthly", "state": "error", "code": "PURCHASE_TOKEN_INVALID"}


async def test_cross_device_sync_with_one_time_link_code(new_customer, client):
    phone = await new_customer("android")
    await verify(phone, "sado_pro_monthly", mock_token("sado_pro_monthly", "x-1"))
    code = (await phone.post("/v1/customers/me/link-code")).json()["code"]
    tablet = await client.post("/v1/customers/link", json={"code": code, "platform": "ios"})
    assert tablet.status_code == 200
    assert tablet.json()["customer_id"] == phone.id
    headers = {"Authorization": f"Bearer {tablet.json()['access_token']}"}
    assert (await client.get("/v1/entitlements", headers=headers)).json()["tier"] == "pro"
    reused = await client.post("/v1/customers/link", json={"code": code, "platform": "ios"})
    assert reused.json()["detail"]["code"] == "LINK_CODE_INVALID"


async def test_one_time_theme_purchase_and_refund(new_customer, client):
    c = await new_customer()
    token = mock_token("theme_pack_aurora", "theme-1", subscription=False, price=9_900)
    assert (await verify(c, "theme_pack_aurora", token)).json()["state"] == "granted"
    ent = await c.entitlements()
    assert ent["owned_assets"] == ["theme:aurora"] and ent["tier"] == "free"
    await send_webhook(client, {"event_id": "evt-theme-refund", "type": "refunded", "external_id": "theme-1", "occurred_at": iso(now()), "txn": "theme-1-txn1"})
    assert (await c.entitlements())["owned_assets"] == []


async def test_business_plan_cannot_be_bought_in_app(client):
    catalog = (await client.get("/v1/catalog", params={"provider": "google_play"})).json()
    assert "sado_business_monthly" not in [p["id"] for p in catalog["products"]]
    pro = next(p for p in (await client.get("/v1/catalog")).json()["products"] if p["id"] == "sado_pro_monthly")
    assert pro["reference_price"] == {"amount_minor": 14_900, "currency": "UZS"}


async def test_payments_disabled_and_unconfigured_providers(new_customer):
    from app.config import get_settings

    c = await new_customer()
    google = await c.post("/v1/purchases/verify", json={"provider": "google_play", "store_product_id": "sado_pro:monthly", "token": "x" * 20})
    assert google.status_code == 503 and google.json()["detail"]["code"] == "PROVIDER_NOT_CONFIGURED"
    settings = get_settings()
    settings.payments_enabled = False
    try:
        off = await verify(c, "sado_pro_monthly", mock_token("sado_pro_monthly", "off-1"))
        assert off.status_code == 503 and off.json()["detail"]["code"] == "PAYMENTS_DISABLED"
    finally:
        settings.payments_enabled = True
    assert not await c.has("pro")


async def test_mock_provider_refused_in_production():
    from pydantic import ValidationError

    from app.config import Settings

    with pytest.raises(ValidationError):
        Settings(environment="production", enabled_providers=["mock"], jwt_secret="x" * 40)


async def test_unauthenticated_and_revoked_access(new_customer, client):
    assert (await client.get("/v1/entitlements")).status_code == 401
    assert (await client.get("/v1/entitlements", headers={"Authorization": "Bearer junk"})).status_code == 401
    c = await new_customer()
    assert (await c.delete("/v1/customers/me")).status_code == 204
    assert (await c.get("/v1/entitlements")).status_code == 401
    refreshed = await client.post("/v1/auth/refresh", json={"refresh_token": c.data["refresh_token"]})
    assert refreshed.status_code == 401


async def test_refresh_token_rotation(new_customer, client):
    c = await new_customer()
    first = await client.post("/v1/auth/refresh", json={"refresh_token": c.data["refresh_token"]})
    assert first.status_code == 200
    replay = await client.post("/v1/auth/refresh", json={"refresh_token": c.data["refresh_token"]})
    assert replay.status_code == 401


async def test_financial_tables_are_append_only(new_customer, session_factory):
    c = await new_customer()
    await verify(c, "sado_pro_monthly", mock_token("sado_pro_monthly", "ao-1"))
    async with session_factory() as db:
        audit(db, "test", "seed", "x")
        await db.commit()
        with pytest.raises(Exception, match="append-only"):
            await db.execute(text("UPDATE transactions SET amount_minor = 0"))
        await db.rollback()
        with pytest.raises(Exception, match="append-only"):
            await db.execute(text("DELETE FROM audit_log"))


async def test_subscription_state_is_server_side(new_customer, session_factory):
    """A client cannot mark itself paid: there is no endpoint that accepts entitlement claims."""
    c = await new_customer()
    for path in ("/v1/entitlements", "/v1/customers/me/entitlements"):
        resp = await c.post(path, json={"tier": "pro"})
        assert resp.status_code in (404, 405)
    async with session_factory() as db:
        assert list(await db.scalars(select(Subscription))) == []
    assert SubscriptionStatus.ACTIVE  # enum import used for documentation of states
