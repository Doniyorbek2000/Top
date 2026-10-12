"""Deterministic provider for development and automated tests only.

Tokens and notifications are HMAC-signed with SADO_BILLING_MOCK_WEBHOOK_SECRET so tests exercise the
same signature, replay and idempotency checks as real providers. The registry refuses to load it in
staging or production.
"""

import base64
import json
import time
from datetime import datetime

from starlette.datastructures import Headers

from app.config import get_settings
from app.providers.base import (
    BillingProvider,
    EventType,
    NormalizedEvent,
    ProviderError,
    PurchaseState,
    VerifiedPurchase,
)
from app.security import constant_time_equals, hmac_sha256_hex

SIGNATURE_HEADER = "x-mock-signature"


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def _unb64(data: str) -> bytes:
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))


def make_token(secret: str, claims: dict) -> str:
    """Test helper: what a store would hand the client after a purchase."""
    body = _b64(json.dumps(claims, separators=(",", ":")).encode())
    return f"{body}.{hmac_sha256_hex(secret, body.encode())}"


def sign_notification(secret: str, body: bytes, timestamp: int | None = None) -> str:
    ts = int(time.time()) if timestamp is None else timestamp
    return f"t={ts},v1={hmac_sha256_hex(secret, f'{ts}.'.encode() + body)}"


def _dt(value: str | None) -> datetime | None:
    return datetime.fromisoformat(value) if value else None


class MockProvider(BillingProvider):
    name = "mock"

    def __init__(self) -> None:
        self._secret = get_settings().mock_webhook_secret

    def is_configured(self) -> bool:
        return get_settings().mock_allowed and len(self._secret) >= 16

    async def verify_purchase(self, store_product_id: str, token: str) -> VerifiedPurchase:
        try:
            body, signature = token.rsplit(".", 1)
        except ValueError as exc:
            raise ProviderError("PURCHASE_TOKEN_INVALID") from exc
        if not constant_time_equals(signature, hmac_sha256_hex(self._secret, body.encode())):
            raise ProviderError("PURCHASE_TOKEN_INVALID")
        try:
            claims = json.loads(_unb64(body))
        except (ValueError, json.JSONDecodeError) as exc:
            raise ProviderError("PURCHASE_TOKEN_INVALID") from exc
        if claims.get("product") != store_product_id:
            raise ProviderError("PURCHASE_PRODUCT_MISMATCH")
        return VerifiedPurchase(
            provider=self.name,
            store_product_id=claims["product"],
            external_id=claims["external_id"],
            transaction_id=claims.get("txn", claims["external_id"]),
            state=PurchaseState(claims.get("state", "purchased")),
            purchased_at=datetime.fromisoformat(claims["purchased_at"]),
            expires_at=_dt(claims.get("expires_at")),
            auto_renew=claims.get("auto_renew", True),
            is_trial=claims.get("trial", False),
            price_minor=int(claims.get("price", 0)),
            currency=claims.get("currency", "UZS"),
            country=claims.get("country", "UZ"),
            account_token=claims.get("account_token"),
            is_subscription=claims.get("subscription", True),
        )

    async def acknowledge(self, purchase: VerifiedPurchase, token: str) -> None:
        return None

    async def parse_notification(self, headers: Headers, body: bytes) -> list[NormalizedEvent]:
        header = headers.get(SIGNATURE_HEADER, "")
        try:
            parts = dict(item.split("=", 1) for item in header.split(","))
            timestamp = int(parts["t"])
            signature = parts["v1"]
        except (ValueError, KeyError) as exc:
            raise ProviderError("WEBHOOK_SIGNATURE_INVALID") from exc
        if abs(time.time() - timestamp) > get_settings().webhook_max_age_seconds:
            raise ProviderError("WEBHOOK_REPLAY_REJECTED")
        expected = hmac_sha256_hex(self._secret, f"{timestamp}.".encode() + body)
        if not constant_time_equals(signature, expected):
            raise ProviderError("WEBHOOK_SIGNATURE_INVALID")
        try:
            data = json.loads(body)
            return [
                NormalizedEvent(
                    provider=self.name,
                    event_id=data["event_id"],
                    type=EventType(data["type"]),
                    external_id=data["external_id"],
                    occurred_at=datetime.fromisoformat(data["occurred_at"]),
                    expires_at=_dt(data.get("expires_at")),
                    grace_until=_dt(data.get("grace_until")),
                    transaction_id=data.get("txn"),
                    amount_minor=int(data.get("amount", 0)),
                    currency=data.get("currency", ""),
                    country=data.get("country", ""),
                    store_product_id=data.get("product"),
                    account_token=data.get("account_token"),
                )
            ]
        except (ValueError, KeyError, json.JSONDecodeError) as exc:
            raise ProviderError("WEBHOOK_PAYLOAD_INVALID") from exc
