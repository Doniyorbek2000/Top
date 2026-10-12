# Test plan

Legend: **A** = automated and passing in `server/tests` (35 tests, run with `pytest -q`);
**B–F** = belongs to that phase, not yet implemented; **M** = manual store sandbox test.

## Purchases and subscriptions

| Scenario | Status |
|---|---|
| Free user has no paid entitlements, tier `free` | A |
| Successful subscription purchase grants Pro and records revenue once | A |
| Re-verifying the same token is idempotent (no duplicate revenue or credits) | A |
| Forged / tampered / wrong-product token rejected | A |
| Pending purchase grants nothing | A |
| Cancelled-before-completion purchase grants nothing | A |
| Already-expired subscription grants nothing | A |
| Renewal extends expiry and resets AI allowance | A |
| Expiry removes access | A |
| Auto-renew off keeps access until expiry | A |
| Refund removes access and records negative transaction | A |
| Revocation (family sharing / chargeback) removes access | A |
| Grace period keeps access; billing retry removes it; recovery restores it | A |
| Duplicate webhook delivery processed once | A |
| Out-of-order webhooks do not regress state | A |
| Webhook for a not-yet-verified purchase creates the subscription via account token | A |
| Bad webhook signature / stale timestamp rejected | A |
| Token from another customer rejected (409); restore transfers it with audit | A |
| Restore reports per-item errors without failing the batch | A |
| Second device joins via link code and sees the same entitlements | A |
| One-time theme purchase grants asset; refund removes it | A |
| Business tier not offered through store catalogs | A |
| Payments disabled → 503; unconfigured store provider → 503 | A |
| Mock provider refused in production config | A |
| Unauthenticated and deleted-customer access refused | A |
| Refresh token rotation; old refresh token rejected | A |
| Financial and audit tables reject UPDATE/DELETE | A |
| No endpoint lets a client set its own entitlements | A |
| Upgrade monthly → yearly (proration, single active entitlement) | B, M |
| Downgrade yearly → monthly at period end | B, M |
| Play account hold / pause / resume | B, M |
| App Store family sharing and Ask to Buy (pending) | B, M |
| Play acknowledgement within 3 days, retried on failure | B |
| Store notification signature (OIDC / JWS chain) verification | B |
| Sandbox vs production environment separation | B |
| Price change consent flows | B, M |
| Regional pricing displayed from store | C, M |

## Credits

| Scenario | Status |
|---|---|
| 25 concurrent reservations against 100 credits → exactly 10 succeed, balance never negative | A |
| Same idempotency key reserves once | A |
| Settle charges allowance first, returns remainder, clamps over-charge, idempotent | A |
| Provider timeout releases credits; late settle charges nothing | A |
| Abandoned reservations swept | A |
| Monthly AI budget kill switch | A |
| Ledger sums equal account balances | A |
| End-to-end AI request with consent, metering and failure refund | D |
| Credit pack purchase and refund | D |

## Admin and analytics

| Scenario | Status |
|---|---|
| RBAC: viewer/support/finance/owner boundaries, bad key → 401 | A |
| Overrides grant and revoke access; all admin actions audited | A |
| Credit adjustment idempotent per reference, cannot go negative | A |
| Metrics (MRR, ARR, revenue, conversion, refund rate) from verified transactions only | A |
| Customer detail never exposes full store tokens | A |
| Dashboard UI, cohorts, CSV export | F |

## Security

| Scenario | Status |
|---|---|
| Secrets redacted from logs | A |
| Rate limits on create/verify/restore | A (configured; limit hit not yet tested) |
| Penetration test | Before launch |

## Mobile (phase C)

Paywall in uz/en/ru, restore button, manage-subscription deep links, offline entitlement cache with
expiry, purchase interrupted by app kill, Pro themes/icons gated, no paywall inside conversations,
sponsored messages unaffected by any purchase.
