from functools import lru_cache

from app.config import get_settings
from app.errors import ApiError, not_found, unavailable
from app.providers.base import BillingProvider
from app.providers.mock import MockProvider
from app.providers.stores import AppStoreProvider, GooglePlayProvider


@lru_cache
def _all() -> dict[str, BillingProvider]:
    return {p.name: p for p in (MockProvider(), GooglePlayProvider(), AppStoreProvider())}


def get_provider(name: str) -> BillingProvider:
    """Returns a provider only if payments are switched on, it is enabled and fully configured."""
    settings = get_settings()
    provider = _all().get(name)
    if provider is None:
        raise not_found("PROVIDER_UNKNOWN")
    if not settings.payments_enabled:
        raise unavailable("PAYMENTS_DISABLED")
    if name not in settings.enabled_providers or not provider.is_configured():
        raise unavailable("PROVIDER_NOT_CONFIGURED")
    if name == "mock" and not settings.mock_allowed:
        raise ApiError(403, "MOCK_PROVIDER_FORBIDDEN")
    return provider


def provider_status() -> dict[str, str]:
    settings = get_settings()
    result = {}
    for name, provider in _all().items():
        if name == "mock" and not settings.mock_allowed:
            continue
        if not settings.payments_enabled:
            result[name] = "disabled"
        elif name in settings.enabled_providers and provider.is_configured():
            result[name] = "active"
        else:
            result[name] = "not_configured"
    return result
