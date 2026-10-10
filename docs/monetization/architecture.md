# Architecture

```
 Sado app (Flutter)                         Stores
  ├─ TDLib ── Telegram (unchanged)           ├─ Google Play ── RTDN (Pub/Sub push) ─┐
  └─ billing client (phase C) ──HTTPS──┐     └─ App Store ──── Server Notif. V2 ────┤
                                       ▼                                             ▼
                              server/ (FastAPI) ── PostgreSQL (source of truth)
                                       └──────── Redis (rate limits, link codes)
```

The app never unlocks anything from a store callback. It sends the purchase token to
`POST /v1/purchases/verify`; the server verifies it with the store, records it, and returns entitlements.
The app renders paid features from `GET /v1/entitlements` only.

## Code map (`server/app`)

| Module | Role |
|---|---|
| `config.py` | Settings (`SADO_BILLING_*`), payments master switch, mock forbidden outside dev/test |
| `catalog.py` | Products, prices, store ids |
| `models.py` | SQLAlchemy models |
| `providers/` | `BillingProvider` interface; `mock` (HMAC-signed, dev/test only); `stores` (Google/Apple stubs, report not configured) |
| `services/billing.py` | Verification apply, notification state machine, transactions |
| `services/entitlements.py` | Pure entitlement computation |
| `services/credits.py` | AI credit ledger |
| `services/metrics.py` | Revenue and subscription metrics |
| `routers/` | Customer, billing, admin APIs |
| `cli.py` | `create-admin`, `release-expired-reservations` |

## Product catalog

| Product | Kind | Entitlement | UZ price | Default price | Notes |
|---|---|---|---|---|---|
| `sado_pro_monthly` | subscription (1 mo) | pro | 14 900 UZS | $1.99 | 7-day trial |
| `sado_pro_yearly` | subscription (12 mo) | pro | 149 000 UZS | $19.99 | same group as monthly |
| `sado_ai_writer_monthly` | subscription (1 mo) | ai_writer | 19 900 UZS | $2.99 | 300 credits/month |
| `sado_business_monthly` | subscription (1 mo) | business, pro | 99 000 UZS | — | not sold in-app |
| `theme_pack_aurora` | one-time | asset `theme:aurora` | 9 900 UZS | $0.99 | |
| `icon_pack_classic` | one-time | asset `icons:classic` | 7 900 UZS | $0.99 | |

Store product ids: Play uses `subscription:basePlan` (`sado_pro:monthly`), App Store uses reverse-DNS
(`uz.sado.app.pro.monthly`). Prices shown in the app come from the store (`ProductDetails`); catalog prices
are reference values for display before the store answers and for metrics.

## Identity

- `POST /v1/customers` creates an anonymous customer + device and returns an access JWT (30 min), a refresh
  token (stored hashed, rotated on every use) and a `store_account_token` UUID.
- The app passes `store_account_token` as Play `obfuscatedAccountId` / StoreKit `appAccountToken`. Stores
  echo it back, so a purchase is bound to the Sado customer that made it. A token presented by another
  customer is rejected (`409 PURCHASE_BELONGS_TO_OTHER_ACCOUNT`) unless it comes through restore, which is
  proven by the store account and audited as a transfer.
- Device linking: `POST /v1/customers/me/link-code` returns an 8-char code (Redis, 5 min, single use);
  `POST /v1/customers/link` on the new device joins the same customer.

## Entitlements

Computed from: active subscriptions (`active`, `cancelled` until expiry, `in_grace` until `grace_until`),
completed one-time purchases, and unexpired, unrevoked admin overrides. `tier` is `business` > `pro` >
`free`. Nothing on the client can create an entitlement; there is no write endpoint for it.

## Subscription state machine

```
            purchased/renewed/recovered
   ┌──────────────────────────────────────────────┐
   ▼                                              │
 active ──auto_renew_off──► cancelled ──expired──► expired
   │  ▲                        │
   │  └──auto_renew_on─────────┘
   ├──grace_period──► in_grace ──► billing_retry ──recovered──► active
   ├──paused──► paused
   └──refunded / revoked (any state, terminal) ──► refunded / revoked
```

- Every event is stored once in `provider_events` (unique `provider, event_id`); duplicates are no-ops.
- Events older than `last_event_at` do not change state (out-of-order delivery), except refund/revoke.
- Money events (purchase, renewal, refund) are recorded in `transactions` even when late. A store
  transaction id is charged once whether it first arrives via client verify or a notification.
- Refund/revoke removes the period's AI allowance; purchased credits are kept unless a separate credit
  pack is refunded.

## AI credit ledger

`credit_accounts` holds three counters, each with `CHECK (>= 0)`:

- `allowance` — subscription credits for the current period; reset on each paid period, removed on refund.
- `available` — purchased credits; never expire.
- `reserved` — held for in-flight AI requests.

Flow: `reserve(amount, idempotency_key)` locks the account row (`SELECT … FOR UPDATE`), takes from
allowance first, then available, and writes a ledger row. `settle(used)` charges at most the reserved
amount and returns the rest to the bucket it came from. `release()` returns everything (provider error,
timeout, cancellation). `release_expired()` sweeps abandoned holds. Settle/release are idempotent and a
settle after release charges nothing. Every change writes an immutable `credit_ledger` row;
`ledger_consistent()` checks that ledger sums equal the account.

Server-wide spend cap: `ai_budget_allows()` refuses new AI work once this month's recorded provider cost
reaches `SADO_BILLING_AI_MONTHLY_BUDGET_MICROS` (0 = AI disabled).

## API

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/v1/customers` | none (rate-limited per IP) | Create anonymous customer |
| POST | `/v1/auth/refresh` | refresh token | Rotate tokens |
| POST | `/v1/customers/me/link-code` | customer | One-time device link code |
| POST | `/v1/customers/link` | none + code | Join customer on a new device |
| DELETE | `/v1/customers/me` | customer | Delete account |
| GET | `/v1/catalog` | none | Products; `provider=google_play|app_store` hides non-IAP items |
| GET | `/v1/entitlements` | customer | Source of truth for paid features |
| POST | `/v1/purchases/verify` | customer | Verify one store purchase |
| POST | `/v1/purchases/restore` | customer | Re-verify history, allow audited transfer |
| POST | `/v1/webhooks/{provider}` | provider signature | Store notifications |
| GET | `/v1/admin/metrics` | viewer | MRR, ARR, churn, refunds, conversion, AI cost |
| GET | `/v1/admin/customers/{id}` | support | Customer detail (audited, store ids truncated) |
| POST | `/v1/admin/customers/{id}/overrides` | support | Time-limited entitlement grant |
| DELETE | `/v1/admin/overrides/{id}` | support | Revoke override |
| POST | `/v1/admin/customers/{id}/credits` | finance | Idempotent credit adjustment |
| GET | `/v1/admin/audit` | owner | Audit log |

Error bodies: `{"detail": {"code": "..."}}`. Notable codes: `PAYMENTS_DISABLED` (503),
`PROVIDER_NOT_CONFIGURED` (503), `MOCK_PROVIDER_FORBIDDEN` (403), `PRODUCT_NOT_SOLD_IN_APP`,
`PURCHASE_BELONGS_TO_OTHER_ACCOUNT` (409), `CREDITS_WOULD_GO_NEGATIVE`.

## Database schema (migration `0001`)

| Table | Key constraints |
|---|---|
| `customers` | `store_account_token` unique |
| `devices` | FK customer; `refresh_hash` unique |
| `subscriptions` | unique `(provider, external_id)`; status enum |
| `purchases` | unique `(provider, external_id)` |
| `provider_events` | unique `(provider, event_id)` |
| `transactions` | unique `(provider, external_txn_id, kind)`; **append-only** |
| `credit_accounts` | `allowance/available/reserved >= 0` |
| `credit_ledger` | unique `(customer_id, kind, reference)`; **append-only** |
| `credit_reservations` | unique `(customer_id, idempotency_key)` |
| `ai_usage` | counts and cost only, no text |
| `entitlement_overrides` | `revoked_at` instead of delete |
| `admin_users` | `key_hash` (sha256), role enum |
| `audit_log` | **append-only** |

Append-only is enforced in PostgreSQL by `BEFORE UPDATE OR DELETE` triggers calling `forbid_mutation()`,
so it holds even against a buggy release or a direct SQL session with the app role.
