import uuid
from datetime import datetime
from enum import StrEnum

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    DateTime,
    Enum,
    ForeignKey,
    Index,
    Integer,
    String,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


def _enum(enum_cls: type[StrEnum], name: str) -> Enum:
    return Enum(enum_cls, name=name, values_callable=lambda cls: [m.value for m in cls])


class SubscriptionStatus(StrEnum):
    ACTIVE = "active"  # paid (or trial) and auto-renewing
    CANCELLED = "cancelled"  # auto-renew off, access until expires_at
    IN_GRACE = "in_grace"  # renewal payment failing, store grace period: access kept
    BILLING_RETRY = "billing_retry"  # grace over, store still retrying: no access
    PAUSED = "paused"  # Google Play pause: no access
    EXPIRED = "expired"
    REFUNDED = "refunded"
    REVOKED = "revoked"  # e.g. family sharing removed, chargeback


class PurchaseStatus(StrEnum):
    COMPLETED = "completed"
    REFUNDED = "refunded"
    REVOKED = "revoked"


class EventStatus(StrEnum):
    PROCESSED = "processed"
    IGNORED = "ignored"  # stale (out of order) or irrelevant
    FAILED = "failed"


class AdminRole(StrEnum):
    VIEWER = "viewer"  # metrics only
    SUPPORT = "support"  # + customer lookup, entitlement overrides
    FINANCE = "finance"  # + credit adjustments
    OWNER = "owner"  # everything incl. admin management


class Customer(Base):
    """A Sado customer. Independent of Telegram: a Telegram user id is never used as identity."""

    __tablename__ = "customers"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    # Opaque token handed to the stores (Play obfuscatedAccountId / App Store appAccountToken)
    # so store transactions can be tied back to this customer.
    store_account_token: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), unique=True, default=uuid.uuid4)
    region: Mapped[str] = mapped_column(String(2), default="UZ")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Device(Base):
    __tablename__ = "devices"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"), index=True)
    refresh_hash: Mapped[str] = mapped_column(String(64), unique=True)
    platform: Mapped[str] = mapped_column(String(16))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Subscription(Base):
    __tablename__ = "subscriptions"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="RESTRICT"), index=True)
    provider: Mapped[str] = mapped_column(String(32))
    # Stable store identifier: Play purchase token (first in the linked chain) / App Store original_transaction_id.
    external_id: Mapped[str] = mapped_column(String(512))
    product_id: Mapped[str] = mapped_column(String(64))
    status: Mapped[SubscriptionStatus] = mapped_column(_enum(SubscriptionStatus, "subscription_status"))
    is_trial: Mapped[bool] = mapped_column(Boolean, default=False)
    auto_renew: Mapped[bool] = mapped_column(Boolean, default=True)
    period_start: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    grace_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    price_minor: Mapped[int] = mapped_column(BigInteger, default=0)
    currency: Mapped[str] = mapped_column(String(3), default="")
    country: Mapped[str] = mapped_column(String(2), default="")
    # Time of the newest store event applied; older events are ignored (out-of-order protection).
    last_event_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    __table_args__ = (UniqueConstraint("provider", "external_id", name="uq_subscriptions_provider_external"),)


class Purchase(Base):
    """One-time purchase (theme packs, icon packs)."""

    __tablename__ = "purchases"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="RESTRICT"), index=True)
    provider: Mapped[str] = mapped_column(String(32))
    external_id: Mapped[str] = mapped_column(String(512))
    product_id: Mapped[str] = mapped_column(String(64))
    status: Mapped[PurchaseStatus] = mapped_column(_enum(PurchaseStatus, "purchase_status"))
    purchased_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    price_minor: Mapped[int] = mapped_column(BigInteger, default=0)
    currency: Mapped[str] = mapped_column(String(3), default="")
    country: Mapped[str] = mapped_column(String(2), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (UniqueConstraint("provider", "external_id", name="uq_purchases_provider_external"),)


class ProviderEvent(Base):
    """Every webhook/notification received, for idempotency, replay protection and audit."""

    __tablename__ = "provider_events"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    provider: Mapped[str] = mapped_column(String(32))
    event_id: Mapped[str] = mapped_column(String(256))
    event_type: Mapped[str] = mapped_column(String(64))
    external_id: Mapped[str] = mapped_column(String(512))
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    status: Mapped[EventStatus] = mapped_column(_enum(EventStatus, "event_status"))
    detail: Mapped[str] = mapped_column(String(512), default="")

    __table_args__ = (UniqueConstraint("provider", "event_id", name="uq_provider_events_provider_event"),)


class Transaction(Base):
    """Verified money movement reported by a store. Revenue analytics are computed only from this table."""

    __tablename__ = "transactions"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="RESTRICT"), index=True)
    provider: Mapped[str] = mapped_column(String(32))
    external_txn_id: Mapped[str] = mapped_column(String(512))
    kind: Mapped[str] = mapped_column(String(16))  # purchase | renewal | refund
    product_id: Mapped[str] = mapped_column(String(64))
    amount_minor: Mapped[int] = mapped_column(BigInteger)  # negative for refunds
    currency: Mapped[str] = mapped_column(String(3))
    country: Mapped[str] = mapped_column(String(2), default="")
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))

    __table_args__ = (
        UniqueConstraint("provider", "external_txn_id", "kind", name="uq_transactions_provider_txn_kind"),
        Index("ix_transactions_occurred_at", "occurred_at"),
    )


class CreditAccount(Base):
    """Current AI credit balance. Changed only together with a CreditLedger row, in one transaction.

    `allowance` comes with the AI Writer subscription and is reset every billing period.
    `available` holds purchased credits, which never expire (App Store Review Guideline 3.1.1).
    Spending uses the allowance first.
    """

    __tablename__ = "credit_accounts"

    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"), primary_key=True)
    allowance: Mapped[int] = mapped_column(BigInteger, default=0)
    available: Mapped[int] = mapped_column(BigInteger, default=0)
    reserved: Mapped[int] = mapped_column(BigInteger, default=0)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    __table_args__ = (
        CheckConstraint("allowance >= 0", name="ck_credit_allowance_non_negative"),
        CheckConstraint("available >= 0", name="ck_credit_available_non_negative"),
        CheckConstraint("reserved >= 0", name="ck_credit_reserved_non_negative"),
    )


class CreditLedger(Base):
    """Append-only credit journal. (customer, kind, reference) is unique, making every operation idempotent."""

    __tablename__ = "credit_ledger"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"), index=True)
    kind: Mapped[str] = mapped_column(String(16))  # grant | purchase | reserve | settle | release | expire | adjust
    reference: Mapped[str] = mapped_column(String(128))
    delta_allowance: Mapped[int] = mapped_column(BigInteger, default=0)
    delta_available: Mapped[int] = mapped_column(BigInteger, default=0)
    delta_reserved: Mapped[int] = mapped_column(BigInteger, default=0)
    meta: Mapped[dict] = mapped_column(JSONB, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (UniqueConstraint("customer_id", "kind", "reference", name="uq_credit_ledger_idempotency"),)


class CreditReservation(Base):
    __tablename__ = "credit_reservations"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"), index=True)
    idempotency_key: Mapped[str] = mapped_column(String(128))
    amount: Mapped[int] = mapped_column(BigInteger)
    from_allowance: Mapped[int] = mapped_column(BigInteger)
    from_available: Mapped[int] = mapped_column(BigInteger)
    status: Mapped[str] = mapped_column(String(16))  # held | settled | released
    settled_amount: Mapped[int] = mapped_column(BigInteger, default=0)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (
        UniqueConstraint("customer_id", "idempotency_key", name="uq_credit_reservations_idempotency"),
        CheckConstraint("amount > 0", name="ck_reservation_amount_positive"),
    )


class AiUsage(Base):
    """Provider cost per AI request (no prompt or output text is stored)."""

    __tablename__ = "ai_usage"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"), index=True)
    reservation_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True))
    feature: Mapped[str] = mapped_column(String(32))
    model: Mapped[str] = mapped_column(String(64))
    input_tokens: Mapped[int] = mapped_column(Integer, default=0)
    output_tokens: Mapped[int] = mapped_column(Integer, default=0)
    cost_micros: Mapped[int] = mapped_column(BigInteger, default=0)  # USD micro-dollars
    credits: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)


class EntitlementOverride(Base):
    """Admin-granted access (support compensation, testers). Always audited."""

    __tablename__ = "entitlement_overrides"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"), index=True)
    entitlement: Mapped[str] = mapped_column(String(32))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    reason: Mapped[str] = mapped_column(String(256))
    granted_by: Mapped[str] = mapped_column(String(64))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class AdminUser(Base):
    __tablename__ = "admin_users"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String(64), unique=True)
    key_hash: Mapped[str] = mapped_column(String(64), unique=True)
    role: Mapped[AdminRole] = mapped_column(_enum(AdminRole, "admin_role"))
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class AuditLog(Base):
    """Append-only record of privileged and financial actions (revoked UPDATE/DELETE in migration)."""

    __tablename__ = "audit_log"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    actor: Mapped[str] = mapped_column(String(128))
    action: Mapped[str] = mapped_column(String(64))
    target: Mapped[str] = mapped_column(String(128))
    details: Mapped[dict] = mapped_column(JSONB, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)
