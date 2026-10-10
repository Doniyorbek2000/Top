from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from app.models import AuditLog


def audit(db: AsyncSession, actor: str, action: str, target: str, **details: Any) -> None:
    """Adds an audit row to the current transaction (committed together with the change it records)."""
    db.add(AuditLog(actor=actor, action=action, target=target, details={k: str(v) for k, v in details.items()}))
