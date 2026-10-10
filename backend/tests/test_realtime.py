import asyncio
import json

import pytest
import websockets


async def _next_event(ws, event_type: str, timeout: float = 5.0) -> dict:
    async def wait() -> dict:
        while True:
            event = json.loads(await ws.recv())
            if event["type"] == event_type:
                return event["data"]

    return await asyncio.wait_for(wait(), timeout)


@pytest.mark.asyncio
async def test_realtime_messages_typing_presence_and_calls(server, make_user):
    alice = make_user("Alice")
    bob = make_user("Bob")
    alice.client.post("/contacts", json={"user_id": bob.id})
    bob.client.post("/contacts", json={"user_id": alice.id})
    chat = alice.client.post("/chats/private", json={"user_id": bob.id}).json()

    async with websockets.connect(f"{server.ws_url}?token={bob.token}") as bob_ws:
        ready = await _next_event(bob_ws, "ready")
        assert ready["user_id"] == bob.id

        async with websockets.connect(f"{server.ws_url}?token={alice.token}") as alice_ws:
            await _next_event(alice_ws, "ready")
            presence = await _next_event(bob_ws, "presence")
            assert presence == {"user_id": alice.id, "online": True, "last_seen_at": None}
            assert bob.client.get(f"/users/{alice.id}").json()["online"] is True

            await alice_ws.send(json.dumps({"type": "typing", "chat_id": chat["id"], "action": "typing"}))
            typing = await _next_event(bob_ws, "typing")
            assert typing == {"chat_id": chat["id"], "user_id": alice.id, "action": "typing"}

            sent = await asyncio.to_thread(
                alice.client.post, f"/chats/{chat['id']}/messages", json={"text": "realtime!"}
            )
            event = await _next_event(bob_ws, "message.new")
            assert event["message"]["id"] == sent.json()["id"]
            assert event["message"]["text"] == "realtime!"

            await asyncio.to_thread(bob.client.post, f"/chats/{chat['id']}/read", json={"message_id": sent.json()["id"]})
            read = await _next_event(alice_ws, "chat.read")
            assert read == {"chat_id": chat["id"], "user_id": bob.id, "message_id": sent.json()["id"]}

            await alice_ws.send(json.dumps({"type": "call.offer", "to_user_id": bob.id, "call_id": "c1", "sdp": "v=0", "video": True}))
            offer = await _next_event(bob_ws, "call.offer")
            assert offer["from_user_id"] == alice.id and offer["sdp"] == "v=0" and offer["video"] is True

            await alice_ws.send(json.dumps({"type": "ping", "ts": 1}))
            assert (await _next_event(alice_ws, "pong"))["ts"] == 1

        offline = await _next_event(bob_ws, "presence")
        assert offline["user_id"] == alice.id and offline["online"] is False and offline["last_seen_at"]


@pytest.mark.asyncio
async def test_terminated_session_closes_socket(server, make_user):
    alice = make_user("Alice")
    tablet = make_user("x", phone=alice.phone, device="tablet")
    async with websockets.connect(f"{server.ws_url}?token={tablet.token}") as ws:
        await _next_event(ws, "ready")
        await asyncio.to_thread(alice.client.delete, f"/auth/sessions/{tablet.session_id}")
        await _next_event(ws, "session.terminated")
        with pytest.raises(websockets.ConnectionClosed):
            await asyncio.wait_for(ws.recv(), 5)


@pytest.mark.asyncio
async def test_invalid_token_rejected(server):
    with pytest.raises(websockets.InvalidStatus):
        async with websockets.connect(f"{server.ws_url}?token=garbage"):
            pass
