import io
import json

from PIL import Image

from tests.conftest import DEV_CODE


def test_auth_flow_and_sessions(server, make_user):
    alice = make_user("Alice")
    me = alice.client.get("/users/me").json()
    assert me["first_name"] == "Alice"
    assert me["phone"] == alice.phone

    # Second device for the same phone, then terminate it from the first.
    second = make_user("ignored", phone=alice.phone, device="tablet")
    assert second.id == alice.id
    sessions = alice.client.get("/auth/sessions").json()
    assert len(sessions) == 2
    assert sum(1 for s in sessions if s["is_current"]) == 1
    assert alice.client.delete(f"/auth/sessions/{second.session_id}").status_code == 204
    assert second.client.get("/users/me").status_code == 401

    # Refresh rotates the token; the old refresh token stops working.
    resp = alice.client.post("/auth/refresh", json={"refresh_token": alice.refresh_token})
    assert resp.status_code == 200
    assert alice.client.post("/auth/refresh", json={"refresh_token": alice.refresh_token}).status_code == 401


def test_wrong_otp_rejected(server):
    import httpx

    with httpx.Client(base_url=server.base_url) as anon:
        anon.post("/auth/send-code", json={"phone": "+998935550000"})
        resp = anon.post("/auth/verify", json={"phone": "+998935550000", "code": "00000"})
        assert resp.status_code == 400
        assert resp.json()["detail"]["code"] == "OTP_INVALID"
        assert anon.post("/auth/send-code", json={"phone": "12"}).status_code == 422
        assert DEV_CODE


def test_profile_username_and_privacy(make_user):
    alice = make_user("Alice")
    bob = make_user("Bob")
    uname = f"alice_{alice.id}"
    resp = alice.client.patch("/users/me", json={"username": uname, "bio": "hi", "phone_visibility": "nobody"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["username"] == uname
    assert bob.client.patch("/users/me", json={"username": uname.upper()}).status_code == 409
    assert bob.client.get(f"/users/check-username?username={uname}").json()["available"] is False

    seen_by_bob = bob.client.get(f"/users/by-username/{uname}").json()
    assert seen_by_bob["id"] == alice.id
    assert seen_by_bob["phone"] is None

    # Contacts see the phone number they saved.
    bob.client.post("/contacts/import", json={"contacts": [{"phone": alice.phone, "first_name": "Ali"}]})
    contacts = bob.client.get("/contacts").json()
    assert [c["id"] for c in contacts] == [alice.id]
    assert contacts[0]["contact_first_name"] == "Ali"
    assert contacts[0]["phone"] == alice.phone


def test_private_chat_messaging(make_user):
    alice = make_user("Alice")
    bob = make_user("Bob")
    chat = alice.client.post("/chats/private", json={"user_id": bob.id}).json()
    assert chat["type"] == "private"
    assert chat["peer"]["id"] == bob.id
    assert chat["title"] == "Bob"

    # Idempotent send by client_id.
    first = alice.client.post(f"/chats/{chat['id']}/messages", json={"text": "Salom!", "client_id": "c-1"}).json()
    again = alice.client.post(f"/chats/{chat['id']}/messages", json={"text": "Salom!", "client_id": "c-1"}).json()
    assert first["id"] == again["id"]

    reply = bob.client.post(
        f"/chats/{chat['id']}/messages", json={"text": "Va alaykum", "reply_to_id": first["id"]}
    ).json()
    assert reply["reply_to"]["id"] == first["id"]

    bob_chats = bob.client.get("/chats").json()
    bob_view = next(c for c in bob_chats if c["id"] == chat["id"])
    assert bob_view["title"] == "Alice"
    assert bob_view["last_message"]["id"] == reply["id"]
    assert bob_view["unread_count"] == 0  # replying marks the chat as read

    alice_view = next(c for c in alice.client.get("/chats").json() if c["id"] == chat["id"])
    assert alice_view["unread_count"] == 1
    assert alice_view["read_outbox_max_id"] >= first["id"]

    assert alice.client.post(f"/chats/{chat['id']}/read", json={"message_id": reply["id"]}).status_code == 204
    alice_view = alice.client.get(f"/chats/{chat['id']}").json()
    assert alice_view["unread_count"] == 0

    # Edit, react, delete for me, delete for everyone.
    edited = alice.client.patch(f"/messages/{first['id']}", json={"text": "Assalomu alaykum!"}).json()
    assert edited["edited_at"] is not None
    assert bob.client.patch(f"/messages/{first['id']}", json={"text": "hack"}).status_code == 403

    reacted = bob.client.post(f"/messages/{first['id']}/reactions", json={"emoji": "❤️"}).json()
    assert reacted["reactions"] == [{"emoji": "❤️", "count": 1, "me": True}]
    toggled = bob.client.post(f"/messages/{first['id']}/reactions", json={"emoji": "❤️"}).json()
    assert toggled["reactions"] == []

    bob.client.post(f"/chats/{chat['id']}/messages/delete", json={"message_ids": [first["id"]]})
    bob_history = bob.client.get(f"/chats/{chat['id']}/messages").json()
    assert first["id"] not in [m["id"] for m in bob_history]
    alice_history = alice.client.get(f"/chats/{chat['id']}/messages").json()
    assert first["id"] in [m["id"] for m in alice_history]

    alice.client.post(
        f"/chats/{chat['id']}/messages/delete", json={"message_ids": [reply["id"]], "for_everyone": True}
    )
    assert reply["id"] not in [m["id"] for m in alice.client.get(f"/chats/{chat['id']}/messages").json()]

    # Pagination.
    ids = [
        alice.client.post(f"/chats/{chat['id']}/messages", json={"text": f"m{i}"}).json()["id"] for i in range(5)
    ]
    page = alice.client.get(f"/chats/{chat['id']}/messages?before_id={ids[3]}&limit=2").json()
    assert [m["id"] for m in page] == ids[1:3]
    after = alice.client.get(f"/chats/{chat['id']}/messages?after_id={ids[2]}").json()
    assert [m["id"] for m in after] == ids[3:]


def test_blocking_prevents_messages(make_user):
    alice = make_user("Alice")
    bob = make_user("Bob")
    chat = alice.client.post("/chats/private", json={"user_id": bob.id}).json()
    assert bob.client.post(f"/users/{alice.id}/block").status_code == 204
    resp = alice.client.post(f"/chats/{chat['id']}/messages", json={"text": "hey"})
    assert resp.status_code == 403
    assert resp.json()["detail"]["code"] == "USER_BLOCKED"
    assert [u["id"] for u in bob.client.get("/users/blocked").json()] == [alice.id]
    bob.client.delete(f"/users/{alice.id}/block")
    assert alice.client.post(f"/chats/{chat['id']}/messages", json={"text": "hey"}).status_code == 201


def test_groups_roles_and_system_messages(make_user):
    owner = make_user("Owner")
    member = make_user("Member")
    outsider = make_user("Outsider")
    group = owner.client.post("/chats/group", json={"title": "Oila", "member_ids": [member.id]}).json()
    assert group["member_count"] == 2
    assert group["my_role"] == "owner"
    assert group["invite_link"]

    history = member.client.get(f"/chats/{group['id']}/messages").json()
    assert history[0]["type"] == "system"
    assert history[0]["extra"]["action"] == "group_created"

    # Members cannot rename; owner can.
    assert member.client.patch(f"/chats/{group['id']}", json={"title": "X"}).status_code == 403
    assert owner.client.patch(f"/chats/{group['id']}", json={"title": "Oila 2"}).json()["title"] == "Oila 2"

    # Join via invite link.
    invite_hash = group["invite_link"].rsplit("/", 1)[1]
    preview = outsider.client.get(f"/chats/invite/{invite_hash}").json()
    assert preview["is_member"] is False
    joined = outsider.client.post("/chats/join", json={"invite_hash": invite_hash}).json()
    assert joined["member_count"] == 3

    # Promote, then admin kicks, owner restricts sending.
    assert owner.client.patch(f"/chats/{group['id']}/members/{member.id}", json={"role": "admin"}).status_code == 200
    assert member.client.delete(f"/chats/{group['id']}/members/{outsider.id}").status_code == 204
    assert outsider.client.get(f"/chats/{group['id']}").status_code == 404
    owner.client.patch(f"/chats/{group['id']}", json={"members_can_send": False})
    assert member.client.post(f"/chats/{group['id']}/messages", json={"text": "admin ok"}).status_code == 201

    members = owner.client.get(f"/chats/{group['id']}/members").json()
    assert {m["user"]["id"] for m in members} == {owner.id, member.id}

    # Owner leaves: ownership passes on.
    assert owner.client.delete(f"/chats/{group['id']}/members/{owner.id}").status_code == 204
    assert member.client.get(f"/chats/{group['id']}").json()["my_role"] == "owner"


def test_channel_permissions_and_views(make_user):
    admin = make_user("Admin")
    reader = make_user("Reader")
    uname = f"news{admin.id}"
    channel = admin.client.post("/chats/channel", json={"title": "Yangiliklar", "username": uname}).json()
    assert channel["type"] == "channel"

    # Public channel is readable before joining.
    assert reader.client.get(f"/chats/{channel['id']}/messages").status_code == 200
    reader.client.post("/chats/join", json={"username": uname})
    assert reader.client.post(f"/chats/{channel['id']}/messages", json={"text": "x"}).status_code == 403
    post = admin.client.post(f"/chats/{channel['id']}/messages", json={"text": "Birinchi post"}).json()
    reader.client.post(f"/chats/{channel['id']}/read", json={"message_id": post["id"]})
    refreshed = reader.client.get(f"/chats/{channel['id']}/messages").json()
    assert next(m for m in refreshed if m["id"] == post["id"])["views"] == 1

    found = reader.client.get(f"/search?q={uname}").json()
    assert channel["id"] in [c["id"] for c in found["chats"]]


def test_forward_poll_pin_and_folders(make_user):
    alice = make_user("Alice")
    bob = make_user("Bob")
    group = alice.client.post("/chats/group", json={"title": "Team", "member_ids": [bob.id]}).json()
    saved = alice.client.get("/chats/saved").json()
    assert saved["type"] == "saved"

    poll = alice.client.post(
        f"/chats/{group['id']}/messages",
        json={"type": "poll", "poll": {"question": "Qachon?", "options": ["Bugun", "Ertaga"]}},
    ).json()
    assert poll["poll"]["counts"] == [0, 0]
    voted = bob.client.post(f"/messages/{poll['id']}/vote", json={"options": [1]}).json()
    assert voted["poll"] == {"counts": [0, 1], "total_voters": 1, "my_votes": [1]}
    assert bob.client.post(f"/messages/{poll['id']}/vote", json={"options": [0, 1]}).status_code == 400

    msg = bob.client.post(f"/chats/{group['id']}/messages", json={"text": "Muhim xabar"}).json()
    forwarded = alice.client.post(
        "/messages/forward",
        json={"from_chat_id": group["id"], "message_ids": [msg["id"]], "to_chat_ids": [saved["id"]]},
    ).json()
    assert forwarded[0]["forward"]["from_user_id"] == bob.id
    assert forwarded[0]["chat_id"] == saved["id"]

    pinned = alice.client.post(f"/chats/{group['id']}/pin", json={"message_id": msg["id"]}).json()
    assert pinned["pinned_message_id"] == msg["id"]
    assert bob.client.post(f"/chats/{group['id']}/pin", json={"message_id": None}).status_code == 403

    folder = alice.client.post("/folders", json={"title": "Ish", "include_types": ["groups"]}).json()
    assert folder["include_types"] == ["groups"]
    assert len(alice.client.get("/folders").json()) == 1
    assert alice.client.post("/folders", json={"title": "Bo'sh"}).status_code == 400

    settings = alice.client.patch(f"/chats/{group['id']}/settings", json={"is_pinned": True, "draft": "qoralama"}).json()
    assert settings["is_pinned"] is True and settings["draft"] == "qoralama"
    assert alice.client.get("/chats").json()[0]["id"] == group["id"]

    results = alice.client.get("/search?q=Muhim").json()
    assert msg["id"] in [m["id"] for m in results["messages"]]


def test_media_upload_and_access(make_user):
    alice = make_user("Alice")
    bob = make_user("Bob")
    eve = make_user("Eve")
    buf = io.BytesIO()
    Image.new("RGB", (800, 600), (200, 30, 30)).save(buf, "PNG")
    resp = alice.client.post(
        "/media",
        data={"kind": "photo"},
        files={"file": ("pic.png", buf.getvalue(), "image/png")},
    )
    assert resp.status_code == 201, resp.text
    media = resp.json()
    assert (media["width"], media["height"]) == (800, 600)
    assert media["thumb_url"]

    voice = alice.client.post(
        "/media",
        data={"kind": "voice", "duration_ms": "3200", "waveform": json.dumps([0, 5, 31, 12])},
        files={"file": ("v.m4a", b"\x00" * 2048, "audio/mp4")},
    ).json()
    assert voice["waveform"] == [0, 5, 31, 12]

    chat = alice.client.post("/chats/private", json={"user_id": bob.id}).json()
    sent = alice.client.post(
        f"/chats/{chat['id']}/messages", json={"type": "photo", "media_id": media["id"], "text": "rasm"}
    ).json()
    assert sent["media"]["id"] == media["id"]
    assert bob.client.post(
        f"/chats/{chat['id']}/messages", json={"type": "photo", "media_id": media["id"]}
    ).status_code == 400  # not the uploader

    assert bob.client.get(f"/media/{media['id']}").status_code == 200
    assert bob.client.get(f"/media/{media['id']}?thumb=1").headers["content-type"] == "image/jpeg"
    assert eve.client.get(f"/media/{media['id']}").status_code == 404
    ranged = bob.client.get(f"/media/{voice['id']}", headers={"Range": "bytes=0-99"})
    assert ranged.status_code == 404  # voice not shared in any chat yet
    alice.client.post(f"/chats/{chat['id']}/messages", json={"type": "voice", "media_id": voice["id"]})
    ranged = bob.client.get(f"/media/{voice['id']}", headers={"Range": "bytes=0-99"})
    assert ranged.status_code == 206 and len(ranged.content) == 100

    shared = bob.client.get(f"/chats/{chat['id']}/media?kind=media").json()
    assert [m["id"] for m in shared] == [sent["id"]]


def test_ai_disabled_without_key(make_user):
    alice = make_user("Alice")
    status = alice.client.get("/ai/status").json()
    assert status["enabled"] is False
    assert status["bot_user_id"]
    resp = alice.client.post("/ai/translate", json={"text": "hello", "target_language": "uz"})
    assert resp.status_code == 503
    assert resp.json()["detail"]["code"] == "AI_DISABLED"
