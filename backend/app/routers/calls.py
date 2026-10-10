from fastapi import APIRouter

from app.config import get_settings
from app.deps import ViewerDep
from app.schemas import CallConfigOut, IceServer

router = APIRouter(prefix="/calls", tags=["calls"])

DEFAULT_STUN = ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]


@router.get("/config", response_model=CallConfigOut)
async def call_config(viewer: ViewerDep) -> CallConfigOut:
    """ICE servers for WebRTC. Configure TURN (e.g. coturn) in production so calls work behind NAT."""
    settings = get_settings()
    servers = [IceServer(urls=DEFAULT_STUN)]
    if settings.turn_urls:
        servers.append(
            IceServer(urls=settings.turn_urls, username=settings.turn_username, credential=settings.turn_credential)
        )
    return CallConfigOut(ice_servers=servers)
