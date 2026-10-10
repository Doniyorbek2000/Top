"""Product catalog: the single definition of what Sado sells and what each product unlocks.

Prices here are reference prices for display and analytics. The amount actually charged is set in
Google Play Console / App Store Connect and is always taken from the verified store transaction.
"""

from dataclasses import dataclass, field
from enum import StrEnum


class Entitlement(StrEnum):
    PRO = "pro"  # premium themes, icons, appearance and local productivity tools (Sado-owned only)
    AI_WRITER = "ai_writer"  # AI writing assistant on user-entered text, with a monthly credit allowance
    BUSINESS = "business"  # Bot API based business tools (web billing, not sold in-app)


class ProductKind(StrEnum):
    SUBSCRIPTION = "subscription"
    ONE_TIME = "one_time"


@dataclass(frozen=True, slots=True)
class Price:
    amount_minor: int  # smallest currency unit (UZS has no minor unit in practice, so tiyin is not used)
    currency: str


@dataclass(frozen=True, slots=True)
class Product:
    id: str
    kind: ProductKind
    entitlements: tuple[Entitlement, ...]
    period_months: int = 0  # subscriptions only
    trial_days: int = 0
    group: str = ""  # subscriptions in one group are mutually exclusive tiers (upgrade/downgrade)
    monthly_ai_credits: int = 0
    asset_id: str = ""  # one-time theme/icon packs
    store_ids: dict[str, str] = field(default_factory=dict)  # provider -> store product id
    prices: dict[str, Price] = field(default_factory=dict)  # region (ISO 3166) or "default" -> price
    in_app: bool = True  # False: sold only through business web billing


# Credits are an internal unit: 1 credit ~ one short AI rewrite. See docs/monetization/AI_COST_MODEL.md.
AI_WRITER_MONTHLY_CREDITS = 300

PRODUCTS: dict[str, Product] = {
    p.id: p
    for p in [
        Product(
            id="sado_pro_monthly",
            kind=ProductKind.SUBSCRIPTION,
            entitlements=(Entitlement.PRO,),
            period_months=1,
            trial_days=7,
            group="pro",
            store_ids={"google_play": "sado_pro:monthly", "app_store": "uz.sado.app.pro.monthly", "mock": "sado_pro_monthly"},
            prices={"UZ": Price(14_900, "UZS"), "default": Price(199, "USD")},
        ),
        Product(
            id="sado_pro_yearly",
            kind=ProductKind.SUBSCRIPTION,
            entitlements=(Entitlement.PRO,),
            period_months=12,
            trial_days=7,
            group="pro",
            store_ids={"google_play": "sado_pro:yearly", "app_store": "uz.sado.app.pro.yearly", "mock": "sado_pro_yearly"},
            prices={"UZ": Price(149_000, "UZS"), "default": Price(1_999, "USD")},
        ),
        Product(
            id="sado_ai_writer_monthly",
            kind=ProductKind.SUBSCRIPTION,
            entitlements=(Entitlement.AI_WRITER,),
            period_months=1,
            group="ai_writer",
            monthly_ai_credits=AI_WRITER_MONTHLY_CREDITS,
            store_ids={"google_play": "sado_ai_writer:monthly", "app_store": "uz.sado.app.aiwriter.monthly", "mock": "sado_ai_writer_monthly"},
            prices={"UZ": Price(19_900, "UZS"), "default": Price(299, "USD")},
        ),
        Product(
            id="sado_business_monthly",
            kind=ProductKind.SUBSCRIPTION,
            entitlements=(Entitlement.BUSINESS, Entitlement.PRO),
            period_months=1,
            group="business",
            in_app=False,
            store_ids={"mock": "sado_business_monthly"},
            prices={"UZ": Price(99_000, "UZS")},
        ),
        Product(
            id="theme_pack_aurora",
            kind=ProductKind.ONE_TIME,
            entitlements=(),
            asset_id="theme:aurora",
            store_ids={"google_play": "theme_pack_aurora", "app_store": "uz.sado.app.theme.aurora", "mock": "theme_pack_aurora"},
            prices={"UZ": Price(9_900, "UZS"), "default": Price(99, "USD")},
        ),
        Product(
            id="icon_pack_classic",
            kind=ProductKind.ONE_TIME,
            entitlements=(),
            asset_id="icons:classic",
            store_ids={"google_play": "icon_pack_classic", "app_store": "uz.sado.app.icons.classic", "mock": "icon_pack_classic"},
            prices={"UZ": Price(7_900, "UZS"), "default": Price(99, "USD")},
        ),
    ]
}


def product_by_store_id(provider: str, store_id: str) -> Product | None:
    for product in PRODUCTS.values():
        if product.store_ids.get(provider) == store_id:
            return product
    return None


def price_for(product: Product, region: str) -> Price | None:
    return product.prices.get(region.upper()) or product.prices.get("default")
