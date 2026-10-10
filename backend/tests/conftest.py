"""End-to-end fixtures: run the real API under uvicorn against PostgreSQL + Redis and talk to it over HTTP/WS."""

import itertools
import os
import socket
import subprocess
import sys
import tempfile
import time
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

import httpx
import pytest

BACKEND_DIR = Path(__file__).resolve().parent.parent
TEST_DATABASE_URL = os.environ.get("SADO_TEST_DATABASE_URL", "postgresql+asyncpg://sado:sado@localhost:5432/sado_test")
TEST_REDIS_URL = os.environ.get("SADO_TEST_REDIS_URL", "redis://localhost:6379/15")
DEV_CODE = "12345"

_phone_counter = itertools.count(1)


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@dataclass
class Server:
    base_url: str
    ws_url: str


@pytest.fixture(scope="session")
def server() -> Iterator[Server]:
    port = _free_port()
    media_dir = tempfile.mkdtemp(prefix="sado-media-")
    env = {
        **os.environ,
        "SADO_ENVIRONMENT": "test",
        "SADO_DATABASE_URL": TEST_DATABASE_URL,
        "SADO_REDIS_URL": TEST_REDIS_URL,
        "SADO_MEDIA_ROOT": media_dir,
        "SADO_PUBLIC_BASE_URL": f"http://127.0.0.1:{port}",
        "SADO_DEV_OTP_CODE": DEV_CODE,
        "SADO_OTP_RESEND_COOLDOWN_SECONDS": "0",
        "SADO_ANTHROPIC_API_KEY": "",
    }
    python = sys.executable
    subprocess.run([python, "-m", "alembic", "downgrade", "base"], cwd=BACKEND_DIR, env=env, check=True, capture_output=True)
    subprocess.run([python, "-m", "alembic", "upgrade", "head"], cwd=BACKEND_DIR, env=env, check=True, capture_output=True)
    subprocess.run(["redis-cli", "-n", "15", "FLUSHDB"], check=True, capture_output=True)

    proc = subprocess.Popen(
        [python, "-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", str(port), "--log-level", "warning"],
        cwd=BACKEND_DIR,
        env=env,
    )
    base_url = f"http://127.0.0.1:{port}"
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            if httpx.get(f"{base_url}/health", timeout=1).status_code == 200:
                break
        except httpx.HTTPError:
            time.sleep(0.2)
    else:
        proc.kill()
        raise RuntimeError("server did not start")
    yield Server(base_url=base_url, ws_url=f"ws://127.0.0.1:{port}/ws")
    proc.terminate()
    proc.wait(timeout=10)


@dataclass
class TestUser:
    id: int
    phone: str
    token: str
    refresh_token: str
    session_id: int
    client: httpx.Client


def _login(server: Server, first_name: str, phone: str | None = None, device: str = "pytest") -> TestUser:
    phone = phone or f"+99890{next(_phone_counter):07d}"
    with httpx.Client(base_url=server.base_url, timeout=30) as anon:
        assert anon.post("/auth/send-code", json={"phone": phone}).status_code == 200
        resp = anon.post(
            "/auth/verify",
            json={"phone": phone, "code": DEV_CODE, "first_name": first_name, "device_name": device, "platform": "test"},
        )
        assert resp.status_code == 200, resp.text
        data = resp.json()
    client = httpx.Client(
        base_url=server.base_url, timeout=30, headers={"Authorization": f"Bearer {data['access_token']}"}
    )
    return TestUser(
        id=data["user"]["id"],
        phone=phone,
        token=data["access_token"],
        refresh_token=data["refresh_token"],
        session_id=data["session_id"],
        client=client,
    )


@pytest.fixture
def make_user(server: Server):
    created: list[TestUser] = []

    def factory(first_name: str = "User", phone: str | None = None, device: str = "pytest") -> TestUser:
        user = _login(server, first_name, phone, device)
        created.append(user)
        return user

    yield factory
    for user in created:
        user.client.close()
