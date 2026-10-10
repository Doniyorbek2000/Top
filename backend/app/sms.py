import logging

import httpx

from app.config import get_settings
from app.redis_client import redis

logger = logging.getLogger(__name__)

ESKIZ_BASE = "https://notify.eskiz.uz/api"
ESKIZ_TOKEN_KEY = "sms:eskiz:token"


class SmsDeliveryError(Exception):
    pass


async def _eskiz_token(client: httpx.AsyncClient, force_refresh: bool = False) -> str:
    if not force_refresh:
        cached = await redis.get(ESKIZ_TOKEN_KEY)
        if cached:
            return cached
    settings = get_settings()
    response = await client.post(
        f"{ESKIZ_BASE}/auth/login",
        data={"email": settings.eskiz_email, "password": settings.eskiz_password},
    )
    if response.status_code != 200:
        raise SmsDeliveryError(f"eskiz auth failed: {response.status_code} {response.text}")
    token = response.json()["data"]["token"]
    # Eskiz tokens live 30 days; refresh well before that.
    await redis.set(ESKIZ_TOKEN_KEY, token, ex=60 * 60 * 24 * 25)
    return token


async def _send_eskiz(phone: str, text: str) -> None:
    settings = get_settings()
    payload = {"mobile_phone": phone.lstrip("+"), "message": text, "from": settings.eskiz_sender}
    async with httpx.AsyncClient(timeout=15) as client:
        token = await _eskiz_token(client)
        response = await client.post(
            f"{ESKIZ_BASE}/message/sms/send", data=payload, headers={"Authorization": f"Bearer {token}"}
        )
        if response.status_code == 401:
            token = await _eskiz_token(client, force_refresh=True)
            response = await client.post(
                f"{ESKIZ_BASE}/message/sms/send", data=payload, headers={"Authorization": f"Bearer {token}"}
            )
        if response.status_code >= 300:
            raise SmsDeliveryError(f"eskiz send failed: {response.status_code} {response.text}")


async def send_otp_sms(phone: str, code: str) -> None:
    settings = get_settings()
    text = f"Sado: tasdiqlash kodi {code}. Kodni hech kimga bermang."
    if settings.sms_provider == "eskiz":
        await _send_eskiz(phone, text)
        return
    logger.warning("OTP for %s: %s (console SMS provider)", phone, code)
