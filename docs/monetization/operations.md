# Operations

## Local development

```bash
cd server
python3.13 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
cp .env.example .env            # set SADO_BILLING_JWT_SECRET
createdb sado_billing && createdb sado_billing_test   # role sado/sado, or point the URLs elsewhere
.venv/bin/alembic upgrade head
.venv/bin/uvicorn app.main:app --reload
.venv/bin/pytest -q && .venv/bin/ruff check .
```

Tests need PostgreSQL (`sado_billing_test`) and Redis (db 3); override with
`SADO_BILLING_TEST_DATABASE_URL` / `SADO_BILLING_TEST_REDIS_URL`. The suite drops and re-runs migrations.

Admin keys: `python -m app.cli create-admin <name> <viewer|support|finance|owner>` prints the key once;
only its sha256 is stored. Send it as `X-Admin-Key`.

## Configuration

All settings are in [`server/.env.example`](../../server/.env.example). Production rules:

- Secrets come from the platform's secret manager, never from the image or the repo.
- `SADO_BILLING_ENVIRONMENT=production` disables `/docs` and refuses the mock provider at startup.
- `SADO_BILLING_PAYMENTS_ENABLED=false` until phase B passes sandbox testing.

## Google Play Console (phase B)

1. Create subscriptions `sado_pro` (base plans `monthly`, `yearly`; free-trial offer 7 days on monthly),
   `sado_ai_writer` (base plan `monthly`); in-app products `theme_pack_aurora`, `icon_pack_classic`.
2. Set prices per country (UZS 14 900 / 149 000 / 19 900 / 9 900 / 7 900 in Uzbekistan).
3. Enable grace period and account hold.
4. Create a Google Cloud service account, grant it "View financial data" and "Manage orders and
   subscriptions" in Play Console → Users and permissions; mount its JSON as a secret file.
5. Real-time developer notifications: Pub/Sub topic → push subscription to
   `https://<host>/v1/webhooks/google_play` with OIDC authentication (the server will verify the token
   audience and service account email).
6. License testers for sandbox purchases.

## App Store Connect (phase B)

1. Subscription group "Sado Pro" with `uz.sado.app.pro.monthly` (7-day free introductory offer) and
   `uz.sado.app.pro.yearly`; group "Sado AI Writer" with `uz.sado.app.aiwriter.monthly`.
2. Non-consumables `uz.sado.app.theme.aurora`, `uz.sado.app.icons.classic`.
3. Enable billing grace period.
4. App Store Server API key (Users and Access → Integrations → In-App Purchase): issuer id, key id,
   `.p8` file mounted as a secret.
5. App Store Server Notifications V2: production and sandbox URLs `https://<host>/v1/webhooks/app_store`.
6. Sandbox testers.

## Deployment

1. Build the image from `server/Dockerfile` (non-root user, no tests or venv in the image).
2. Run migrations as a release step: `python -m alembic upgrade head`. Migrations are forward-only in
   production; destructive changes ship in two releases (stop using → drop).
3. Run `release-expired-reservations` every minute (cron/scheduler).
4. Health check: `GET /health`.
5. TLS terminates at the load balancer; uvicorn runs with `--proxy-headers`. Set `FORWARDED_ALLOW_IPS`
   to the load balancer's addresses so per-IP rate limits use the real client address; the app itself
   never reads `X-Forwarded-For`.
6. Backups: PostgreSQL point-in-time recovery. Redis holds only rate-limit counters and link codes.

## Rollback

- Application: redeploy the previous image; schema changes are backward-compatible by policy.
- Payments incident: set `SADO_BILLING_PAYMENTS_ENABLED=false`. Existing entitlements stay readable;
  new verifications return `503 PAYMENTS_DISABLED`; stores retry notifications, and the
  `provider_events` dedupe makes the replay safe once re-enabled.
- AI incident: set `SADO_BILLING_AI_MONTHLY_BUDGET_MICROS=0`.
- Customer-level fixes go through admin overrides and credit adjustments, both audited. Financial rows
  are never edited; corrections are new rows.

## Security checklist

- [x] Entitlements only from server-side verification; no client write path
- [x] Purchases bound to the customer via store account token; transfers only through audited restore
- [x] Webhooks authenticated (HMAC for mock; OIDC / JWS for stores in phase B), replay window 300 s, 256 KB limit
- [x] Idempotent event processing and transaction recording
- [x] Credit balances cannot go negative (row locks + CHECK constraints), tested with 25 concurrent spenders
- [x] Append-only financial and audit tables enforced in the database
- [x] Refresh tokens hashed and rotated; devices revocable; admin keys hashed; RBAC with four roles
- [x] Rate limits on customer creation, verify, restore
- [x] Log redaction of tokens and secrets; no Telegram data or AI text stored
- [x] Mock provider refused in staging/production; payments off by default
- [ ] Phase B: store signature/OIDC verification, acknowledgement retry job
- [ ] Admin keys → SSO/OIDC for the dashboard (phase F); IP allow-list for `/v1/admin`
- [ ] External penetration test before enabling payments
