# Sado monetization

Status: **Phase A (server foundation) implemented and tested. Payments are disabled.** No real store is
connected and no real money can move. This page indexes the docs and tracks the phased plan.

| Document | Contents |
|---|---|
| [compliance.md](compliance.md) | Telegram / Apple / Google requirements, verification status, privacy and data processing, Telegram checklist |
| [architecture.md](architecture.md) | Components, product catalog, entitlement model, subscription state machine, credit ledger, API, database schema |
| [operations.md](operations.md) | Configuration, Play Console / App Store Connect setup, deployment, rollback, security checklist |
| [ai-cost-model.md](ai-cost-model.md) | AI Writer unit economics, quotas, budget kill switch |
| [test-plan.md](test-plan.md) | Full scenario list, with what is automated today |

## Audit summary (before this work)

- `mobile/` is a Flutter + TDLib Telegram client. Users sign in with their own Telegram account; there was
  no Sado backend, no account system and no billing code of any kind.
- The client did **not** display Telegram's mandatory sponsored messages in channels. Fixed in commit
  `80acfe9` (`getChatSponsoredMessages`, `viewMessages` on full visibility, click and report flows,
  independent of ghost mode).
- Existing "AI" actions in the chat screen call Telegram's own TDLib functions (translation/summary) and do
  not send content to any third-party AI service. They are not part of Sado's paid AI Writer.

Server-side purchase verification is mandatory for any paid feature, so one small service (`server/`) was
added. It is the only backend; it never sees Telegram credentials, sessions or messages.

## Phased plan

| Phase | Scope | Status |
|---|---|---|
| A | Billing service: identity, catalog, entitlements, state machine, idempotent webhooks, credit ledger, admin RBAC + audit, metrics, mock provider, migrations, tests | **Done** (this commit) |
| B | Real Google Play (`purchases.subscriptionsv2`, acknowledge, RTDN via Pub/Sub with OIDC) and App Store (JWS verification against Apple Root CA G3, Server Notifications V2, App Store Server API) | Not started; needs store accounts and credentials |
| C | Mobile billing client (`in_app_purchase`), paywall, subscription management, restore, Pro themes/icons gated by `/v1/entitlements` | Not started |
| D | AI Writer endpoint on user-authored text only, explicit consent screen, provider abstraction, metering through the ledger | Not started; needs AI provider contract and DPA |
| E | Business tier (Bot API tooling) and web billing abstraction (provider-agnostic; Payme/Click/Stripe not assumed) | Not started; needs legal entity and payment processor |
| F | Admin dashboard UI, cohorts, exports | Not started (API exists) |

Production payments must stay off (`SADO_BILLING_PAYMENTS_ENABLED=false`) until phase B is complete,
tested against store sandboxes, and the open items in [compliance.md](compliance.md) are closed.
