"""AI credit ledger.

Invariants (enforced here, by row locks and by database constraints):
  * balances never go negative (CHECK constraints + SELECT ... FOR UPDATE on the account row)
  * every balance change has exactly one ledger row, written in the same transaction
  * every operation is idempotent: (customer, kind, reference) is unique in the ledger and
    reservations are unique per (customer, idempotency_key)
  * credits for a request that was not delivered are released, never settled
"""

import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from sqlalchemy import and_, func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import AiUsage, CreditAccount, CreditLedger, CreditReservation


class InsufficientCredits(Exception):
    pass


class ReservationNotFound(Exception):
    pass


@dataclass(frozen=True, slots=True)
class Balance:
    allowance: int
    available: int
    reserved: int

    @property
    def spendable(self) -> int:
        return self.allowance + self.available


async def _locked_account(db: AsyncSession, customer_id: uuid.UUID) -> CreditAccount:
    await db.execute(pg_insert(CreditAccount).values(customer_id=customer_id).on_conflict_do_nothing())
    account = await db.scalar(
        select(CreditAccount).where(CreditAccount.customer_id == customer_id).with_for_update().execution_options(populate_existing=True)
    )
    assert account is not None
    return account


async def _ledger_exists(db: AsyncSession, customer_id: uuid.UUID, kind: str, reference: str) -> bool:
    return (
        await db.scalar(
            select(CreditLedger.id).where(
                CreditLedger.customer_id == customer_id, CreditLedger.kind == kind, CreditLedger.reference == reference
            )
        )
    ) is not None


async def get_balance(db: AsyncSession, customer_id: uuid.UUID) -> Balance:
    account = await db.get(CreditAccount, customer_id, populate_existing=True)
    if account is None:
        return Balance(0, 0, 0)
    return Balance(account.allowance, account.available, account.reserved)


async def reset_allowance(db: AsyncSession, customer_id: uuid.UUID, amount: int, reference: str) -> bool:
    """Sets the period allowance (subscription renewal). Unused allowance from the previous period expires.

    Runs inside the caller's transaction. Returns False if this reference was already applied.
    """
    account = await _locked_account(db, customer_id)
    if await _ledger_exists(db, customer_id, "grant", reference):
        return False
    previous = account.allowance
    account.allowance = amount
    db.add(CreditLedger(
        customer_id=customer_id, kind="grant", reference=reference,
        delta_allowance=amount - previous, meta={"expired_allowance": previous, "granted": amount},
    ))
    return True


async def revoke_allowance(db: AsyncSession, customer_id: uuid.UUID, reference: str) -> bool:
    """Removes the remaining allowance (refund / revocation). Runs inside the caller's transaction."""
    account = await _locked_account(db, customer_id)
    if await _ledger_exists(db, customer_id, "expire", reference):
        return False
    previous = account.allowance
    account.allowance = 0
    db.add(CreditLedger(customer_id=customer_id, kind="expire", reference=reference, delta_allowance=-previous))
    return True


async def add_purchased(db: AsyncSession, customer_id: uuid.UUID, amount: int, reference: str, kind: str = "purchase") -> bool:
    """Purchased or admin-adjusted credits (never expire). Negative amounts only for admin adjustments."""
    account = await _locked_account(db, customer_id)
    if await _ledger_exists(db, customer_id, kind, reference):
        return False
    if account.available + amount < 0:
        raise InsufficientCredits
    account.available += amount
    db.add(CreditLedger(customer_id=customer_id, kind=kind, reference=reference, delta_available=amount))
    return True


async def reserve(
    db: AsyncSession, customer_id: uuid.UUID, amount: int, idempotency_key: str, ttl_seconds: int = 120
) -> CreditReservation:
    """Holds credits before an AI call. Commits. Replays with the same key return the same reservation."""
    if amount <= 0:
        raise ValueError("amount must be positive")
    existing = await db.scalar(
        select(CreditReservation).where(
            CreditReservation.customer_id == customer_id, CreditReservation.idempotency_key == idempotency_key
        )
    )
    if existing is not None:
        return existing
    account = await _locked_account(db, customer_id)
    # Re-check under the lock: a concurrent request with the same key may have won.
    existing = await db.scalar(
        select(CreditReservation).where(
            CreditReservation.customer_id == customer_id, CreditReservation.idempotency_key == idempotency_key
        )
    )
    if existing is not None:
        await db.commit()
        return existing
    if account.allowance + account.available < amount:
        await db.rollback()
        raise InsufficientCredits
    from_allowance = min(account.allowance, amount)
    from_available = amount - from_allowance
    account.allowance -= from_allowance
    account.available -= from_available
    account.reserved += amount
    reservation = CreditReservation(
        customer_id=customer_id,
        idempotency_key=idempotency_key,
        amount=amount,
        from_allowance=from_allowance,
        from_available=from_available,
        status="held",
        expires_at=datetime.now(UTC) + timedelta(seconds=ttl_seconds),
    )
    db.add(reservation)
    await db.flush()
    db.add(CreditLedger(
        customer_id=customer_id, kind="reserve", reference=str(reservation.id),
        delta_allowance=-from_allowance, delta_available=-from_available, delta_reserved=amount,
    ))
    await db.commit()
    return reservation


async def _locked_reservation(db: AsyncSession, reservation_id: uuid.UUID) -> CreditReservation:
    reservation = await db.scalar(
        select(CreditReservation).where(CreditReservation.id == reservation_id).with_for_update().execution_options(populate_existing=True)
    )
    if reservation is None:
        raise ReservationNotFound
    return reservation


async def settle(db: AsyncSession, reservation_id: uuid.UUID, used: int, usage: AiUsage | None = None) -> CreditReservation:
    """Charges `used` credits (clamped to the reserved amount) and returns the rest. Commits; idempotent."""
    reservation = await _locked_reservation(db, reservation_id)
    if reservation.status != "held":
        await db.commit()  # ends the locking transaction without expiring the loaded row
        return reservation
    account = await _locked_account(db, reservation.customer_id)
    used = max(0, min(used, reservation.amount))
    # Charge the allowance part first; refund the remainder to the buckets it came from.
    used_allowance = min(used, reservation.from_allowance)
    used_available = used - used_allowance
    back_allowance = reservation.from_allowance - used_allowance
    back_available = reservation.from_available - used_available
    account.allowance += back_allowance
    account.available += back_available
    account.reserved -= reservation.amount
    reservation.status = "settled"
    reservation.settled_amount = used
    db.add(CreditLedger(
        customer_id=reservation.customer_id, kind="settle", reference=str(reservation.id),
        delta_allowance=back_allowance, delta_available=back_available, delta_reserved=-reservation.amount,
        meta={"used": used},
    ))
    if usage is not None:
        usage.reservation_id = reservation.id
        usage.customer_id = reservation.customer_id
        usage.credits = used
        db.add(usage)
    await db.commit()
    return reservation


async def release(db: AsyncSession, reservation_id: uuid.UUID, reason: str = "not_delivered") -> CreditReservation:
    """Returns all held credits (provider failure, timeout, cancellation). Commits; idempotent."""
    reservation = await _locked_reservation(db, reservation_id)
    if reservation.status != "held":
        await db.commit()  # ends the locking transaction without expiring the loaded row
        return reservation
    account = await _locked_account(db, reservation.customer_id)
    account.allowance += reservation.from_allowance
    account.available += reservation.from_available
    account.reserved -= reservation.amount
    reservation.status = "released"
    db.add(CreditLedger(
        customer_id=reservation.customer_id, kind="release", reference=str(reservation.id),
        delta_allowance=reservation.from_allowance, delta_available=reservation.from_available,
        delta_reserved=-reservation.amount, meta={"reason": reason},
    ))
    await db.commit()
    return reservation


async def release_expired(db: AsyncSession, now: datetime | None = None) -> int:
    """Sweeper: releases reservations whose AI call never reported back (crash, lost connection)."""
    now = now or datetime.now(UTC)
    ids = list(await db.scalars(
        select(CreditReservation.id).where(and_(CreditReservation.status == "held", CreditReservation.expires_at < now))
    ))
    await db.rollback()
    for reservation_id in ids:
        await release(db, reservation_id, reason="expired")
    return len(ids)


async def month_ai_cost_micros(db: AsyncSession, now: datetime | None = None) -> int:
    now = now or datetime.now(UTC)
    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    return int(await db.scalar(select(func.coalesce(func.sum(AiUsage.cost_micros), 0)).where(AiUsage.created_at >= start)) or 0)


async def ai_budget_allows(db: AsyncSession, monthly_budget_micros: int, now: datetime | None = None) -> bool:
    """Server-wide kill switch: AI calls stop once the month's provider spend reaches the budget."""
    if monthly_budget_micros <= 0:
        return False
    return await month_ai_cost_micros(db, now) < monthly_budget_micros


async def ledger_consistent(db: AsyncSession, customer_id: uuid.UUID) -> bool:
    """Audit check: the balance equals the sum of its ledger entries."""
    sums = (await db.execute(
        select(
            func.coalesce(func.sum(CreditLedger.delta_allowance), 0),
            func.coalesce(func.sum(CreditLedger.delta_available), 0),
            func.coalesce(func.sum(CreditLedger.delta_reserved), 0),
        ).where(CreditLedger.customer_id == customer_id)
    )).one()
    balance = await get_balance(db, customer_id)
    return (balance.allowance, balance.available, balance.reserved) == tuple(int(x) for x in sums)
