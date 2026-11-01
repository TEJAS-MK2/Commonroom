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
- Room creation guardrails (100-room cap and five new rooms per minute globally)
- Token-protected reaction removal; reactions cannot be deleted by arbitrary public requests
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

Enable Realtime for the message and reaction tables used by the client. The `public` schema must be exposed through the Supabase Data API, with the grants and row-level security policies required by the schema.

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
├── styles.css
├── app.js
├── supabase/
│   ├── config.js
│   └── schema.sql
├── CODE_OF_CONDUCT.md
├── CONTRIBUTING.md
├── README.md
└── SECURITY.md
```

## Privacy and security

Commonroom is a **public anonymous chat**, not a private messaging service.

- Messages, display names, room names, reactions, and room presence are visible to people using the public application.
- Display names are not verified identities and can be impersonated.
- A random browser-local sender key distinguishes a visitor's messages. It is not authentication and can be reset or spoofed.
- Message edit/delete ownership uses a random token kept in that browser's local storage; only its SHA-256 hash is stored with the message. Clearing site data or changing browsers can remove the ability to manage an earlier message.
- Database triggers apply best-effort message/reaction limits keyed by a browser-provided sender key; this is still spoofable and is not IP-level enforcement. Do not treat it as a complete anti-abuse system.
- Public room creation is globally capped at 100 rooms and five creations per minute. This is a shared safety ceiling, not per-visitor identity-based quota.
- Reaction removal uses a random browser-held token and a server-side hash check. Older reactions created before this protection may not be removable from the original device.
- Do not use Commonroom to share passwords, financial information, personal records, or other sensitive content.
- There are no private direct messages or private file uploads.

See [SECURITY.md](SECURITY.md) for vulnerability reporting and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community expectations.

## Development checks

Before opening a pull request, run:

```bash
node --input-type=module --check < app.js
node tests/smoke.mjs
python -m http.server 8000
```

Then test the application in a browser at desktop and mobile widths. Verify room switching, sending messages, replies, reactions, edit/delete ownership, presence, and navigation.

GitHub Actions checks JavaScript module syntax, security-sensitive interaction invariants, required HTML IDs, browser configuration, and accidental inclusion of privileged Supabase credentials. Pushes to `main` are deployed to GitHub Pages after the build succeeds.

## Project policies

- [Contributing guide](CONTRIBUTING.md)
- [Code of conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md)

## Acknowledgements

Built with care for simple, open, real-time conversations. Contributions, bug reports, and thoughtful improvements are welcome.
