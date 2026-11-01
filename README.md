# Commonroom

An open, real-time community chat built with HTML, CSS, JavaScript, and Supabase. No accounts, email addresses, passwords, or sign-in screen are required.

**Live app:** https://tejas-mk2.github.io/Chat/

## Features

- Join instantly with a locally remembered display name
- Public channels: General, Coding, and Random
- Create additional public rooms
- Real-time message delivery with Supabase Realtime / Postgres Changes
- Live room presence and online participant count
- Typing indicators with Realtime Broadcast
- Reply to messages and react with persistent emoji
- Edit or delete messages from the browser that originally posted them
- Responsive, accessible desktop and mobile interface
- Latest 100 messages loaded per room

## Stack

- HTML, CSS, JavaScript (ES modules)
- Supabase PostgreSQL and Realtime
- Supabase JavaScript SDK loaded from a pinned ESM CDN version

## Setup

1. Configure `SUPABASE_URL` and the browser-safe `SUPABASE_PUBLISHABLE_KEY` in `supabase/config.js`.
2. Apply the SQL in `supabase/schema.sql` to the Supabase project.
3. In Supabase Dashboard → API → API Settings, ensure the Data API exposes the `public` schema and the `anon` role has the required table grants.
4. Ensure Realtime is enabled for `public.chat_guest_messages` and `public.chat_guest_reactions`.
5. Serve the repository locally:
   ```bash
   python -m http.server 8000
   ```
6. Open http://localhost:8000.

## Privacy and abuse considerations

This is intentionally a **public, anonymous chat**. Messages, display names, room names, and room presence are visible to anyone who can access the app. A display name is not verified identity and can be impersonated. The sender key is a random browser-local identifier used only to distinguish a visitor's own messages; it is not authentication.

Because there is no account identity, this version does not offer private DMs or private file attachments. Database triggers apply per-sender-key posting and reaction limits and block immediate duplicate-message spam. Sender keys can be reset or spoofed, so these limits are best-effort anti-abuse controls rather than verified identity or IP-level enforcement. Never put a Supabase service-role or secret key in browser code.

## Message controls

- Reply to a message to create a lightweight threaded conversation in the room.
- Edit or delete messages from the browser that originally posted them. Each message receives a random 256-bit owner token; only its SHA-256 hash is stored in the database. Clearing browser storage or switching devices means that browser can no longer manage that message.
- Database triggers throttle bursts (5 messages per 15 seconds and 20 reactions per 15 seconds per sender key) and block immediate duplicate-message spam.

## Deployment

GitHub Actions validates JavaScript module syntax, checks required HTML IDs, verifies that no privileged Supabase key is included in the browser configuration, and deploys the static site to GitHub Pages on pushes to `main`.
