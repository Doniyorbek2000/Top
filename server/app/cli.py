"""Operational commands.

    python -m app.cli create-admin <name> <viewer|support|finance|owner>
    python -m app.cli release-expired-reservations
"""

import asyncio
import sys

from app.db import SessionFactory
from app.models import AdminRole, AdminUser
from app.security import new_secret, sha256_hex
from app.services import credits
from app.services.audit import audit


async def create_admin(name: str, role: str) -> None:
    key = new_secret(32)
    async with SessionFactory() as db:
        db.add(AdminUser(name=name, key_hash=sha256_hex(key), role=AdminRole(role)))
        audit(db, "cli", "admin_created", name, role=role)
        await db.commit()
    # Printed once; only the hash is stored.
    print(f"admin key for {name} ({role}): {key}")


async def release_expired() -> None:
    async with SessionFactory() as db:
        released = await credits.release_expired(db)
    print(f"released {released} expired reservations")


def main() -> None:
    match sys.argv[1:]:
        case ["create-admin", name, role]:
            asyncio.run(create_admin(name, role))
        case ["release-expired-reservations"]:
            asyncio.run(release_expired())
        case _:
            print(__doc__)
            sys.exit(2)


if __name__ == "__main__":
    main()
