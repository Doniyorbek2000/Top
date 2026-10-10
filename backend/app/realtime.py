"""Realtime fan-out over Redis pub/sub and presence tracking.

Every WebSocket connection subscribes to its user's channel (`u:{user_id}`) and its auth session channel
(`s:{session_id}`). Any API worker can publish to these channels, so the system scales horizontally.
"""

import json
import logging
import time
from collections.abc import Iterable
from datetime import UTC, datetime
from typing import Any

from app.redis_client import redis

logger = logging.getLogger(__name__)

PRESENCE_TTL_SECONDS = 70


def user_channel(user_id: int) -> str:
    return f"u:{user_id}"


def session_channel(session_id: int) -> str:
    return f"s:{session_id}"


def _encode(event_type: str, data: dict[str, Any]) -> str:
    return json.dumps({"type": event_type, "data": data}, default=_json_default, separators=(",", ":"))


def _json_default(value: Any) -> Any:
    if isinstance(value, datetime):
        return value.isoformat()
    if hasattr(value, "model_dump"):
        return value.model_dump(mode="json")
    raise TypeError(f"not JSON serializable: {type(value)!r}")


async def publish_to_users(user_ids: Iterable[int], event_type: str, data: dict[str, Any]) -> None:
    payload = _encode(event_type, data)
    unique_ids = set(user_ids)
    if not unique_ids:
        return
    async with redis.pipeline(transaction=False) as pipe:
        for uid in unique_ids:
            pipe.publish(user_channel(uid), payload)
        await pipe.execute()


async def publish_to_session(session_id: int, event_type: str, data: dict[str, Any]) -> None:
    await redis.publish(session_channel(session_id), _encode(event_type, data))


async def publish_per_user(payloads: dict[int, tuple[str, dict[str, Any]]]) -> None:
    """Publish a different payload to each user (used when the payload is viewer-specific)."""
    if not payloads:
        return
    async with redis.pipeline(transaction=False) as pipe:
        for uid, (event_type, data) in payloads.items():
            pipe.publish(user_channel(uid), _encode(event_type, data))
        await pipe.execute()


def _presence_key(user_id: int) -> str:
    return f"presence:{user_id}"


async def mark_connection_alive(user_id: int, connection_id: str) -> bool:
    """Refresh a connection heartbeat. Returns True if the user transitioned from offline to online."""
    key = _presence_key(user_id)
    now = time.time()
    async with redis.pipeline(transaction=True) as pipe:
        pipe.zremrangebyscore(key, "-inf", now)
        pipe.zcard(key)
        pipe.zadd(key, {connection_id: now + PRESENCE_TTL_SECONDS})
        pipe.expire(key, PRESENCE_TTL_SECONDS * 2)
        _, live_before, _, _ = await pipe.execute()
    return live_before == 0


async def mark_connection_closed(user_id: int, connection_id: str) -> bool:
    """Remove a connection. Returns True if the user has no remaining live connections."""
    key = _presence_key(user_id)
    now = time.time()
    async with redis.pipeline(transaction=True) as pipe:
        pipe.zrem(key, connection_id)
        pipe.zremrangebyscore(key, "-inf", now)
        pipe.zcard(key)
        _, _, remaining = await pipe.execute()
    return remaining == 0


async def online_user_ids(user_ids: Iterable[int]) -> set[int]:
    ids = list(set(user_ids))
    if not ids:
        return set()
    now = time.time()
    async with redis.pipeline(transaction=False) as pipe:
        for uid in ids:
            pipe.zcount(_presence_key(uid), now, "+inf")
        counts = await pipe.execute()
    return {uid for uid, count in zip(ids, counts, strict=True) if count > 0}


def utcnow() -> datetime:
    return datetime.now(UTC)
