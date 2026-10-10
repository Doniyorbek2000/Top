import asyncio
import contextlib
import json
import logging
import time
import uuid
from typing import Any

from fastapi import APIRouter, WebSocket, WebSocketDisconnect, status
from sqlalchemy import select, update

from app.db import SessionFactory
from app.deps import authenticate_token
from app.errors import ApiError
from app.models import Chat, ChatMember, ChatType, Contact, User, Visibility
from app.realtime import (
    mark_connection_alive,
    mark_connection_closed,
    publish_to_users,
    session_channel,
    user_channel,
    utcnow,
)
from app.redis_client import redis
from app.routers.users import related_user_ids
from app.services.chats import is_blocked_between, member_ids

logger = logging.getLogger(__name__)
router = APIRouter()

HEARTBEAT_SECONDS = 30
TYPING_FANOUT_MAX_MEMBERS = 500
MEMBERSHIP_CACHE_SECONDS = 60
CALL_EVENTS = {"call.offer", "call.answer", "call.ice", "call.hangup", "call.reject", "call.accept", "call.busy", "call.ringing"}
TYPING_ACTIONS = {"typing", "recording_voice", "recording_video", "uploading_photo", "uploading_video", "uploading_file", "cancel"}


async def _presence_targets(user_id: int) -> list[int]:
    async with SessionFactory() as db:
        user = await db.get(User, user_id)
        if user is None or user.last_seen_visibility == Visibility.NOBODY:
            return []
        related = await related_user_ids(db, user_id)
        if user.last_seen_visibility == Visibility.CONTACTS:
            my_contacts = set(await db.scalars(select(Contact.contact_id).where(Contact.owner_id == user_id)))
            related &= my_contacts
        return list(related)


async def _broadcast_presence(user_id: int, online: bool, last_seen_at: str | None) -> None:
    targets = await _presence_targets(user_id)
    await publish_to_users(targets, "presence", {"user_id": user_id, "online": online, "last_seen_at": last_seen_at})


class Connection:
    def __init__(self, websocket: WebSocket, user_id: int, session_id: int) -> None:
        self.websocket = websocket
        self.user_id = user_id
        self.session_id = session_id
        self.connection_id = uuid.uuid4().hex
        self._chat_access: dict[int, tuple[float, ChatType, int]] = {}
        self._send_lock = asyncio.Lock()

    async def send_raw(self, text: str) -> None:
        async with self._send_lock:
            await self.websocket.send_text(text)

    async def send(self, event_type: str, data: dict[str, Any]) -> None:
        await self.send_raw(json.dumps({"type": event_type, "data": data}, separators=(",", ":")))

    async def chat_info(self, chat_id: int) -> tuple[ChatType, int] | None:
        cached = self._chat_access.get(chat_id)
        if cached and cached[0] > time.monotonic():
            return cached[1], cached[2]
        async with SessionFactory() as db:
            row = (
                await db.execute(
                    select(Chat.type, Chat.member_count)
                    .join(ChatMember, ChatMember.chat_id == Chat.id)
                    .where(Chat.id == chat_id, ChatMember.user_id == self.user_id)
                )
            ).first()
        if row is None:
            return None
        self._chat_access[chat_id] = (time.monotonic() + MEMBERSHIP_CACHE_SECONDS, row[0], row[1])
        return row[0], row[1]

    async def handle(self, event: dict[str, Any]) -> None:
        event_type = event.get("type")
        if event_type == "ping":
            await mark_connection_alive(self.user_id, self.connection_id)
            await self.send("pong", {"ts": event.get("ts")})
        elif event_type == "typing":
            await self._handle_typing(event)
        elif event_type in CALL_EVENTS:
            await self._relay_call(event_type, event)
        else:
            await self.send("error", {"code": "UNKNOWN_EVENT", "event": str(event_type)[:32]})

    async def _handle_typing(self, event: dict[str, Any]) -> None:
        chat_id = event.get("chat_id")
        action = event.get("action", "typing")
        if not isinstance(chat_id, int) or action not in TYPING_ACTIONS:
            return
        info = await self.chat_info(chat_id)
        if info is None:
            return
        chat_type, member_count = info
        if chat_type in (ChatType.CHANNEL, ChatType.SAVED) or member_count > TYPING_FANOUT_MAX_MEMBERS:
            return
        async with SessionFactory() as db:
            recipients = [uid for uid in await member_ids(db, chat_id) if uid != self.user_id]
        await publish_to_users(recipients, "typing", {"chat_id": chat_id, "user_id": self.user_id, "action": action})

    async def _relay_call(self, event_type: str, event: dict[str, Any]) -> None:
        target = event.get("to_user_id")
        call_id = event.get("call_id")
        if not isinstance(target, int) or not isinstance(call_id, str) or target == self.user_id:
            return
        async with SessionFactory() as db:
            if await db.get(User, target) is None:
                return
            if event_type == "call.offer" and await is_blocked_between(db, self.user_id, target):
                await self.send("call.reject", {"call_id": call_id, "from_user_id": target, "reason": "blocked"})
                return
        payload = {k: v for k, v in event.items() if k not in ("type", "to_user_id")}
        payload["from_user_id"] = self.user_id
        payload["from_session_id"] = self.session_id
        await publish_to_users([target], event_type, payload)
        if event_type in ("call.accept", "call.reject", "call.hangup"):
            # Tell the user's other devices to stop ringing.
            await publish_to_users([self.user_id], event_type, {**payload, "from_self": True, "peer_user_id": target})


@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket, token: str | None = None) -> None:
    async with SessionFactory() as db:
        try:
            viewer = await authenticate_token(db, token)
        except ApiError:
            await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
            return
        user_id, session_id = viewer.id, viewer.session_id

    await websocket.accept()
    connection = Connection(websocket, user_id, session_id)
    pubsub = redis.pubsub()
    await pubsub.subscribe(user_channel(user_id), session_channel(session_id))

    if await mark_connection_alive(user_id, connection.connection_id):
        await _broadcast_presence(user_id, True, None)
    await connection.send("ready", {"user_id": user_id, "session_id": session_id, "server_time": utcnow().isoformat()})

    async def pump_pubsub() -> None:
        async for message in pubsub.listen():
            if message.get("type") != "message":
                continue
            data = message["data"]
            await connection.send_raw(data)
            if message["channel"] == session_channel(session_id) and '"session.terminated"' in data:
                await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
                return

    async def receive_loop() -> None:
        while True:
            raw = await websocket.receive_text()
            try:
                event = json.loads(raw)
            except json.JSONDecodeError:
                await connection.send("error", {"code": "INVALID_JSON"})
                continue
            if isinstance(event, dict):
                await connection.handle(event)

    async def heartbeat() -> None:
        while True:
            await asyncio.sleep(HEARTBEAT_SECONDS)
            await mark_connection_alive(user_id, connection.connection_id)

    tasks = [asyncio.create_task(pump_pubsub()), asyncio.create_task(receive_loop()), asyncio.create_task(heartbeat())]
    try:
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            exc = task.exception()
            if exc is not None and not isinstance(exc, WebSocketDisconnect):
                logger.warning("websocket task failed for user %s: %r", user_id, exc)
    finally:
        for task in tasks:
            task.cancel()
        for task in tasks:
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task
        with contextlib.suppress(Exception):
            await pubsub.unsubscribe()
            await pubsub.aclose()
        if await mark_connection_closed(user_id, connection.connection_id):
            now = utcnow()
            async with SessionFactory() as db:
                await db.execute(update(User).where(User.id == user_id).values(last_seen_at=now))
                await db.commit()
            await _broadcast_presence(user_id, False, now.isoformat())
