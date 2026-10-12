import os
import subprocess
import sys
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

os.environ.update({
    "SADO_BILLING_ENVIRONMENT": "test",
    "SADO_BILLING_DATABASE_URL": os.environ.get(
        "SADO_BILLING_TEST_DATABASE_URL", "postgresql+asyncpg://sado:sado@localhost:5432/sado_billing_test"
    ),
    "SADO_BILLING_REDIS_URL": os.environ.get("SADO_BILLING_TEST_REDIS_URL", "redis://localhost:6379/3"),
    "SADO_BILLING_JWT_SECRET": "test-secret-test-secret-test-secret-1234",
    "SADO_BILLING_PAYMENTS_ENABLED": "true",
    "SADO_BILLING_ENABLED_PROVIDERS": '["mock"]',
    "SADO_BILLING_MOCK_WEBHOOK_SECRET": "mock-secret-for-tests-only-0123456789",
    "SADO_BILLING_RATE_LIMIT_PER_MINUTE": "1000",
})

import httpx
import pytest
import pytest_asyncio
from sqlalchemy import text

from app.config import get_settings
from app.db import SessionFactory, engine
from app.deps import get_redis
from app.main import app
from app.providers.mock import make_token, sign_notification

SERVER_DIR = Path(__file__).resolve().parent.parent
TABLES = (
    "ai_usage, credit_reservations, credit_ledger, credit_accounts, entitlement_overrides, transactions, "
    "provider_events, purchases, subscriptions, devices, audit_log, admin_users, customers"
)


@pytest.fixture(scope="session", autouse=True)
def migrated_database() -> None:
    env = dict(os.environ)
    for args in (["downgrade", "base"], ["upgrade", "head"]):
        subprocess.run([sys.executable, "-m", "alembic", *args], cwd=SERVER_DIR, env=env, check=True, capture_output=True)


@pytest_asyncio.fixture(autouse=True)
async def clean_state() -> AsyncIterator[None]:
    async with engine.begin() as conn:
        await conn.execute(text(f"TRUNCATE {TABLES} RESTART IDENTITY CASCADE"))
    await get_redis().flushdb()
    yield


@pytest_asyncio.fixture(scope="session", loop_scope="session", autouse=True)
async def dispose_engine() -> AsyncIterator[None]:
    yield
    await engine.dispose()


@pytest_asyncio.fixture
async def client() -> AsyncIterator[httpx.AsyncClient]:
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


class Customer:
    def __init__(self, client: httpx.AsyncClient, data: dict[str, Any]) -> None:
        self.client = client
        self.data = data
        self.id = data["customer_id"]
        self.account_token = data["store_account_token"]
        self.headers = {"Authorization": f"Bearer {data['access_token']}"}

    async def get(self, path: str, **kw: Any) -> httpx.Response:
        return await self.client.get(path, headers=self.headers, **kw)

    async def post(self, path: str, **kw: Any) -> httpx.Response:
        return await self.client.post(path, headers=self.headers, **kw)

    async def delete(self, path: str, **kw: Any) -> httpx.Response:
        return await self.client.delete(path, headers=self.headers, **kw)

    async def entitlements(self) -> dict[str, Any]:
        resp = await self.get("/v1/entitlements")
        assert resp.status_code == 200, resp.text
        return resp.json()

    async def has(self, entitlement: str) -> bool:
        return any(e["entitlement"] == entitlement for e in (await self.entitlements())["entitlements"])


@pytest_asyncio.fixture
async def new_customer(client: httpx.AsyncClient):
    async def factory(platform: str = "android") -> Customer:
        resp = await client.post("/v1/customers", json={"platform": platform})
        assert resp.status_code == 201, resp.text
        return Customer(client, resp.json())

    return factory


def now() -> datetime:
    return datetime.now(UTC)


def iso(dt: datetime) -> str:
    return dt.isoformat()


def mock_token(product: str, external_id: str, *, account_token: str | None = None, **claims: Any) -> str:
    base = {
        "product": product,
        "external_id": external_id,
        "txn": claims.pop("txn", f"{external_id}-txn1"),
        "purchased_at": iso(claims.pop("purchased_at", now())),
        "expires_at": iso(claims.pop("expires_at", now() + timedelta(days=30))) if claims.get("subscription", True) else None,
        "price": claims.pop("price", 14_900),
        "currency": "UZS",
        "country": "UZ",
        "account_token": account_token,
    }
    base.update(claims)
    return make_token(get_settings().mock_webhook_secret, base)


async def send_webhook(client: httpx.AsyncClient, payload: dict[str, Any], *, timestamp: int | None = None, secret: str | None = None) -> httpx.Response:
    import json

    body = json.dumps(payload).encode()
    signature = sign_notification(secret or get_settings().mock_webhook_secret, body, timestamp)
    return await client.post("/v1/webhooks/mock", content=body, headers={"x-mock-signature": signature, "content-type": "application/json"})


@pytest.fixture
def session_factory():
    return SessionFactory
