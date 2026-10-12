# AI Writer cost model

AI Writer is not implemented yet (phase D). This page fixes the rules the implementation must follow and
the numbers to re-check once a provider is chosen. Provider prices below are placeholders to be replaced
with the contracted rates; no specific provider is assumed.

## Scope

- Input: only text the user typed or pasted into the AI Writer screen, after an explicit consent screen
  naming the provider. Never chat history, never automatic.
- Output: returned to the user; not stored by Sado. Provider contract must exclude training on inputs.
- Actions: rewrite, shorten, fix grammar, change tone, translate.

## Credits

1 credit = one request with up to ~1 000 input + ~1 000 output tokens. Longer requests cost
`ceil(total_tokens / 2000)` credits, reserved up front from the requested length and settled on actual use.

| Plan | Price (UZ) | Monthly credits |
|---|---|---|
| AI Writer | 19 900 UZS | 300 |

## Unit economics (fill in with contracted rates)

```
net_revenue   = 19 900 UZS × (1 − store_fee)            # store_fee 15% (small business / subscriptions after year 1) or 30%
provider_cost = credits_used × tokens_per_credit × price_per_token
margin        = net_revenue − provider_cost − infra_share
```

Target: provider cost at full allowance use ≤ 40% of net revenue. If a model breaks this, lower the
allowance or route to a cheaper model; do not raise prices silently.

## Controls already built (phase A)

- Per-customer: reservation before the call, settle on success, release on failure/timeout, sweeper for
  abandoned holds, no negative balance, idempotent per request key.
- Server-wide: `SADO_BILLING_AI_MONTHLY_BUDGET_MICROS` monthly cap on recorded provider cost; 0 = off.
- Metrics: `ai_cost_micros_usd`, `ai_credits_used`, `ai_revenue_minor` in `/v1/admin/metrics`.

## Still needed (phase D)

- Provider abstraction with timeouts and one retry on a fallback model.
- Per-customer rate limit (e.g. 10 requests/minute) and maximum input length.
- Abuse detection on usage spikes; cost alerts at 50/80/100% of the monthly budget.
