# Commonroom

[![Validate and deploy](https://github.com/TEJAS-MK2/Commonroom/actions/workflows/deploy.yml/badge.svg)](https://github.com/TEJAS-MK2/Commonroom/actions/workflows/deploy.yml)
[![GitHub Pages](https://img.shields.io/badge/demo-live-2f855a?logo=github)](https://tejas-mk2.github.io/Commonroom/)

**A welcoming, real-time public chat for open communities.**

Commonroom is a lightweight browser-based chat built with vanilla JavaScript, HTML, CSS, and Supabase. Visitors can join with a display name—no account, email address, password, or sign-in flow is required.

- **Live application:** https://tejas-mk2.github.io/Commonroom/
- **Source code:** https://github.com/TEJAS-MK2/Commonroom
- **Backend:** Supabase (PostgreSQL and Realtime)

## Product overview

Commonroom keeps the experience intentionally simple: choose a room, meet the people currently there, and join the conversation.

### Features

- Instant entry with a locally remembered display name
- Public rooms, including General, Coding, and Random
- Creation of additional public rooms
- Live message delivery using Supabase Realtime / Postgres Changes
- Room presence and online participant indicators
- Lightweight typing indicators
- Emoji reactions and an emoji picker
- Message replies with jump-to-original context
- Edit and delete controls for messages from the original browser
- Responsive desktop, tablet, and mobile layouts with touch-aware controls
- Room creation guardrails (100-room cap, five per minute globally, and five per network per hour)
- Message and reaction ownership hashes stored in non-exposed private tables; public chat rows contain no edit/reaction token hashes
- Server-issued anonymous guest sessions; write RPCs derive sender/reporter IDs from the session token
- Keyboard focus states and reduced-motion support
- Recent message history, with the latest 100 messages loaded per room

### Technology

| Layer | Implementation |
| --- | --- |
| Interface | HTML5, CSS, vanilla JavaScript (ES modules) |
| Data | Supabase PostgreSQL |
| Live updates | Supabase Realtime |
| Client library | Supabase JavaScript SDK 2.57.4 |
| Hosting | GitHub Pages |
| CI/CD | GitHub Actions |

## Run locally

### Requirements

- A Supabase project
- A browser with modern JavaScript and Web Crypto support
- Python 3 or another static HTTP server

### 1. Configure Supabase

Edit `supabase/config.js`:

```js
export const SUPABASE_URL = "https://YOUR_PROJECT.supabase.co";
export const SUPABASE_PUBLISHABLE_KEY = "YOUR_PUBLISHABLE_KEY";
```

Use only the project's browser-safe publishable key (or legacy `anon` key). **Never place a service-role key, secret key, database password, or other privileged credential in this file or any browser asset.**

### 2. Apply the database schema

Open the Supabase SQL Editor and run `supabase/schema.sql`. Review the SQL and confirm it targets the intended project before applying it.

The schema adds the message, reaction, and room-directory tables to Supabase Realtime as needed. The `public` schema must be exposed through the Supabase Data API, with the grants and row-level security policies required by the schema.

### 3. Start a local server

From the repository root:

```bash
python -m http.server 8000
```

Then open http://localhost:8000.

The project uses ES modules, so opening `index.html` directly as a `file://` URL is not supported.

## Project structure

```text
.
├── .github/
│   └── workflows/
│       └── deploy.yml
├── index.html
├── favicon.svg
├── styles.css
├── app.js
├── supabase/
│   ├── config.js
│   ├── schema.sql
│   └── migrations/
├── tests/
│   ├── browser.mjs
│   └── smoke.mjs
├── CODE_OF_CONDUCT.md
├── CONTRIBUTING.md
├── README.md
└── SECURITY.md
```

## Privacy and security

Commonroom is a **public anonymous chat**, not a private messaging service.

- Messages, display names, room names, reactions, and room presence are visible to people using the public application.
- Display names are not verified identities and can be impersonated.
- Anonymous identities are created by private database functions. The browser receives a random bearer session token; write RPCs hash and validate that token and derive the sender/reporter identity server-side. Legacy RPC overloads that accepted caller-selected sender/reporter UUIDs have been removed.
- The session token is a bearer credential stored in browser local storage, so users should avoid sharing a browser profile on untrusted devices. Clearing site data or changing browsers can remove access to the earlier guest identity.
- Message edit/delete ownership uses a random token kept in that browser's local storage. Only its SHA-256 hash is stored in `private.chat_guest_message_tokens`; reaction hashes are stored in `private.chat_guest_reaction_tokens`. Public rows and their Realtime payloads do not expose those hashes.
- Database triggers apply per-session duplicate and burst checks. A PostgREST pre-request hook uses the gateway's `cf-connecting-ip` header (not caller-controlled left-most `X-Forwarded-For`) for a 100-write / five-minute network ceiling on Commonroom message, reaction, room, and message-management endpoints. Missing or malformed proxy IP values share a fallback bucket. The counter is in the same database transaction as the request, so failed writes can roll back their own counter entry; this is abuse friction, not a standalone DDoS shield. Network-level controls can still be bypassed with distributed IPs or VPNs.
- Public room creation is globally capped at 100 rooms and five creations per minute, with an additional five-per-network-per-hour limit. Admins can delete rooms to free capacity. Anonymous networks are not verified identities.
- Reaction removal uses a random browser-held token and a server-side hash check. Older reactions created before this protection may not be removable from the original device.
- Do not use Commonroom to share passwords, financial information, personal records, or other sensitive content.
- There are no private direct messages or private file uploads.

See [SECURITY.md](SECURITY.md) for vulnerability reporting, [SECURITY_AUDIT.md](SECURITY_AUDIT.md) for the latest verification and residual-risk notes, and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community expectations.

## Development checks

Before opening a pull request, run:

```bash
node --input-type=module --check < app.js
node tests/smoke.mjs
npm install --no-save --no-package-lock playwright@1.64.1
npx playwright install chromium
python -m http.server 4173
```

In another terminal, run `node tests/browser.mjs` while that server is running.

The Playwright browser tests use a mocked Supabase client. They validate client lifecycle, room switching, guest-session handling, admin modal behavior, and desktop/mobile layout without sending writes to the production database. They do **not** replace a separate live-backend acceptance test with two real browser sessions.

GitHub Actions checks JavaScript module syntax, security-sensitive interaction invariants, required HTML IDs, browser configuration, accidental inclusion of privileged Supabase credentials, and desktop/mobile browser behavior against the mocked backend. Pushes to `main` are deployed to GitHub Pages after the build succeeds.

## Project policies

- [Contributing guide](CONTRIBUTING.md)
- [Code of conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md)

## Acknowledgements

Built with care for simple, open, real-time conversations. Contributions, bug reports, and thoughtful improvements are welcome.

## Admin Control Room

The admin console is opened from the control-room button in the sidebar. Admin authentication is verified by private database functions; the PIN verifier, login attempts, sessions, and audit log are stored in the non-exposed `private` schema. The current four-digit PIN is a convenience credential, not a substitute for strong multi-factor authentication. Keep the database owner account protected and migrate to identity-backed authentication with MFA before inviting additional operators. Admin login throttling uses the trusted proxy-provided `cf-connecting-ip` header, not caller-supplied `X-Forwarded-For`. The PIN is never embedded in the browser bundle. Failed PIN attempts are limited to five per IP per 15 minutes (with a global attempt ceiling), and successful sessions expire after 30 minutes.

The control room provides community metrics, recent-message moderation, report review, room editing/deletion (the `general` room is protected), and an admin activity log. Admin sessions are held in memory for the current page only.

Public visitors can report a message using its Report action. Reports are written through a server-side function; direct anonymous access to the reports table remains blocked.
