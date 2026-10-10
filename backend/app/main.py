import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import HTMLResponse

from app.config import get_settings
from app.db import engine
from app.redis_client import redis
from app.routers import ai as ai_router
from app.routers import auth, calls, chats, contacts, folders, media, messages, search, users, ws
from app.services import ai

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    get_settings().media_root.mkdir(parents=True, exist_ok=True)
    await ai.ensure_bot_user()
    yield
    await redis.aclose()
    await engine.dispose()


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(title="Sado API", version="1.0.0", lifespan=lifespan)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_methods=["*"],
        allow_headers=["*"],
    )
    app.add_middleware(GZipMiddleware, minimum_size=1024)
    for module in (auth, users, contacts, chats, messages, media, folders, search, calls, ai_router, ws):
        app.include_router(module.router)

    @app.get("/health", tags=["system"])
    async def health() -> dict[str, str]:
        await redis.ping()
        return {"status": "ok"}

    @app.get("/join/{invite_hash}", response_class=HTMLResponse, include_in_schema=False)
    async def invite_landing(invite_hash: str) -> str:
        deep_link = f"sado://join/{invite_hash}"
        return (
            "<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'>"
            f"<meta http-equiv='refresh' content='0;url={deep_link}'><title>Sado</title></head>"
            f"<body style='font-family:sans-serif;text-align:center;padding:48px'>"
            f"<h2>Sado</h2><p><a href='{deep_link}'>Sado ilovasida ochish</a></p></body></html>"
        )

    return app


app = create_app()
