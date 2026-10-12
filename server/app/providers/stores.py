"""Google Play and App Store providers.

Status: NOT IMPLEMENTED YET (phase B). They report themselves as unconfigured, so the API answers
503 PROVIDER_NOT_CONFIGURED and never grants access from an unverified purchase. Phase B work:

Google Play
  - verify: androidpublisher v3 `purchases.subscriptionsv2.get` / `purchases.products.get` with a
    service-account OAuth token; check packageName, obfuscatedExternalAccountId, acknowledgementState
  - acknowledge: `purchases.subscriptions.acknowledge` / `purchases.products.acknowledge`
  - notifications: Real-time developer notifications via Pub/Sub push; authenticate the push
    request's Google-signed OIDC token (audience + service account email), then re-fetch state
    with subscriptionsv2.get instead of trusting the message body; voided purchases API for refunds

App Store
  - verify: StoreKit 2 signed transactions (JWS) — verify the x5c chain to Apple Root CA - G3,
    bundleId, environment, appAccountToken; or App Store Server API `GET /inApps/v1/transactions/{id}`
  - notifications: App Store Server Notifications V2 (signedPayload JWS, same chain verification),
    including REFUND, REVOKE, DID_FAIL_TO_RENEW (+ GRACE_PERIOD subtype), EXPIRED, DID_RENEW
"""

from starlette.datastructures import Headers

from app.config import get_settings
from app.providers.base import BillingProvider, NormalizedEvent, ProviderNotConfigured, VerifiedPurchase


class _UnimplementedStore(BillingProvider):
    async def verify_purchase(self, store_product_id: str, token: str) -> VerifiedPurchase:
        raise ProviderNotConfigured(self.name)

    async def acknowledge(self, purchase: VerifiedPurchase, token: str) -> None:
        raise ProviderNotConfigured(self.name)

    async def parse_notification(self, headers: Headers, body: bytes) -> list[NormalizedEvent]:
        raise ProviderNotConfigured(self.name)

    def is_configured(self) -> bool:
        # Credentials alone are not enough: verification code lands in phase B.
        return False


class GooglePlayProvider(_UnimplementedStore):
    name = "google_play"

    def credentials_present(self) -> bool:
        s = get_settings()
        return bool(s.google_package_name and s.google_service_account_file)


class AppStoreProvider(_UnimplementedStore):
    name = "app_store"

    def credentials_present(self) -> bool:
        s = get_settings()
        return bool(s.apple_bundle_id and s.apple_issuer_id and s.apple_key_id and s.apple_private_key_file)
