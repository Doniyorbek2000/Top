"""Payment provider abstraction.

Providers turn store-specific data (Play purchase tokens, App Store signed transactions, signed
webhooks) into normalized, *verified* facts. Nothing reaches the entitlement engine without passing
through a provider's verification.
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum

from starlette.datastructures import Headers


class ProviderError(Exception):
    """Verification failed: the token/notification is invalid, forged or for another app."""

    def __init__(self, code: str, message: str = "") -> None:
        super().__init__(message or code)
        self.code = code


class ProviderNotConfigured(ProviderError):
    def __init__(self, provider: str) -> None:
        super().__init__("PROVIDER_NOT_CONFIGURED", f"{provider} billing is not configured on this server")


class PurchaseState(StrEnum):
    PURCHASED = "purchased"
    PENDING = "pending"  # e.g. Play "pending" cash payments: grant nothing yet
    CANCELLED = "cancelled"  # user cancelled the flow / never paid


class EventType(StrEnum):
    PURCHASED = "purchased"
    RENEWED = "renewed"
    RECOVERED = "recovered"  # payment fixed after billing retry
    AUTO_RENEW_OFF = "auto_renew_off"
    AUTO_RENEW_ON = "auto_renew_on"
    GRACE_PERIOD = "grace_period"
    BILLING_RETRY = "billing_retry"
    PAUSED = "paused"
    EXPIRED = "expired"
    REFUNDED = "refunded"
    REVOKED = "revoked"
    TEST = "test"


@dataclass(frozen=True, slots=True)
class VerifiedPurchase:
    provider: str
    store_product_id: str
    external_id: str  # stable subscription/purchase id at the store
    transaction_id: str  # id of this particular payment (renewals get new ones)
    state: PurchaseState
    purchased_at: datetime
    expires_at: datetime | None  # subscriptions only
    auto_renew: bool
    is_trial: bool
    price_minor: int
    currency: str
    country: str
    account_token: str | None  # obfuscatedAccountId / appAccountToken set at purchase time
    is_subscription: bool


@dataclass(frozen=True, slots=True)
class NormalizedEvent:
    provider: str
    event_id: str  # unique per provider; used for idempotency
    type: EventType
    external_id: str
    occurred_at: datetime
    expires_at: datetime | None = None
    grace_until: datetime | None = None
    transaction_id: str | None = None
    amount_minor: int = 0
    currency: str = ""
    country: str = ""
    store_product_id: str | None = None
    account_token: str | None = None


class BillingProvider(ABC):
    name: str

    @abstractmethod
    def is_configured(self) -> bool: ...

    @abstractmethod
    async def verify_purchase(self, store_product_id: str, token: str) -> VerifiedPurchase:
        """Verify a client-supplied purchase token with the store. Raises ProviderError."""

    @abstractmethod
    async def acknowledge(self, purchase: VerifiedPurchase, token: str) -> None:
        """Acknowledge/consume where the store requires it (Play refunds unacknowledged purchases)."""

    @abstractmethod
    async def parse_notification(self, headers: Headers, body: bytes) -> list[NormalizedEvent]:
        """Authenticate and parse a server notification. Raises ProviderError on bad signatures."""
