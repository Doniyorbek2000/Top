# Compliance

This is an engineering checklist, not legal advice. "Verified" means the primary text was read for this
work; "unverified" means it came from secondary summaries and must be confirmed before launch.

## Requirement matrix

| Requirement | Source | Verification | How Sado meets it | Open before release |
|---|---|---|---|---|
| Core Telegram messaging stays free | Telegram API ToS | Unverified (core.telegram.org unreachable from build env) | No messaging, chat, media, call or navigation feature is gated. Paid items are Sado-owned extras only | Read ToS primary text |
| Show official sponsored messages in channels | Telegram API ToS §3.3 | Unverified | Implemented in `mobile/lib/features/chat/sponsored_bubble.dart`; views reported on full visibility, ghost mode does not suppress them | Confirm placement rules against ToS text |
| Disclose monetization in store listings | Telegram API ToS §3.1/3.2 | Unverified | Listing copy below | Publish copy with the listing |
| Not presented as official Telegram; uses Telegram API | Telegram API ToS §2.2 | Unverified | Name "Sado", own logo; "Sado Pro" never called "Premium"; listing states it is an unofficial client built on the Telegram API | Review all store screenshots |
| No sale/exploitation of Telegram user data; no AI training on it | Telegram API ToS, product rule | Unverified | Billing service stores no Telegram identifiers, no messages, no contacts. AI usage table stores token counts only | — |
| In-app purchase for digital content | Apple 3.1.1 | Verified | Pro, AI Writer, theme/icon packs are IAP products | — |
| Purchased consumables / credits do not expire | Apple 3.1.1 | Verified | Purchased credits live in the `available` bucket and never expire; only the monthly subscription allowance resets | — |
| Restore purchases | Apple 3.1.1 | Verified | `POST /v1/purchases/restore` (server); UI is phase C | Phase C |
| Subscriptions ≥ 7 days, on all user's devices, terms disclosed | Apple 3.1.2 | Verified | Monthly/yearly only; device linking via one-time code; paywall copy in phase C | Phase C paywall review |
| Business/enterprise tools may bill outside IAP | Apple 3.1.3(c) | Verified | Business tier is not sold in-app (`in_app=False`, filtered from store catalogs) | Legal review that Business fits the exception |
| Explicit consent before sending personal data to third-party AI | Apple 5.1.2(i) | Verified | AI Writer (phase D) only takes text the user typed or pasted, after a consent screen. Chat history is never sent automatically | Phase D |
| Google Play Billing for digital goods | Play Payments policy | Unverified (sections 3, 8, 9 not read) | Same IAP products on Play | Read policy text; confirm Business tier treatment |
| Uzbekistan consumer/tax/personal-data rules | Local law | Not researched | — | Local counsel |

## Store listing disclosure (draft)

> Sado is an unofficial messaging app built on the Telegram API. It is not affiliated with Telegram.
> All Telegram messaging features are free. Sado offers optional paid extras: Sado Pro (themes, app icons
> and customization, monthly or yearly subscription), AI Writer (a subscription with a monthly allowance
> of writing-assistant credits that works only on text you enter), and one-time theme and icon packs.
> Channels may show official Telegram sponsored messages, as required by Telegram.

## Privacy and data processing

Data the billing service holds:

| Data | Why | Retention |
|---|---|---|
| Random customer UUID, random store account token | Identity for entitlements; tied to store purchases | Until account deletion |
| Device rows (platform, hashed refresh token) | Session management and revocation | Until revoked/deleted |
| Store external ids, transaction ids, prices, currency, country | Entitlement verification, refunds, accounting | Financial records: per accounting law (tables are append-only) |
| Credit ledger, AI usage (counts, model, cost) | Metering and billing disputes | Same as financial records |
| Audit log | Admin accountability | Append-only |

Not stored: Telegram user id, phone number, API id/hash, sessions, messages, contacts, AI prompts or
outputs, card data (stores and processors hold payment instruments).

A Telegram numeric id is never used as identity proof. Customers are anonymous and device-bound;
cross-device access is granted by a one-time link code generated on an authenticated device, or by the
store account itself during restore.

`DELETE /v1/customers/me` revokes all devices, zeroes credits and marks the customer deleted; financial
rows are retained (anonymous) because they are append-only and needed for accounting and refunds.

Logs pass through `RedactingFilter`, which masks bearer tokens, purchase tokens, API hashes, secrets and
similar fields.

## Telegram compliance checklist (release gate)

- [ ] ToS primary text read and this matrix updated
- [x] Sponsored messages shown in channels and bot chats, views reported, report flow present
- [x] Ghost mode does not suppress sponsored message views
- [x] No core messaging feature behind a paywall
- [ ] Store listings carry the disclosure above
- [x] No "Premium" naming; no claim of being official
- [x] No Telegram data in the billing service; no AI processing of chat history
- [ ] Own `api_id` registered for production builds and stored outside the repo
