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
- Responsive, accessible desktop and mobile interface
- Latest 100 messages loaded per room

## Stack

- HTML, CSS, JavaScript (ES modules)
- Supabase PostgreSQL and Realtime
- Supabase JavaScript SDK loaded from a pinned ESM CDN version

## Setup

1. Configure `SUPABASE_URL` and the browser-safe `SUPABASE_PUBLISHABLE_KEY` in `supabase/config.js`.
2. Apply the SQL in `supabase/schema.sql` to the Supabase project. The anonymous-chat migration creates `chat_guest_messages`, enables RLS, and grants the `anon` role only the public room/message operations required by this app.
3. In Supabase Dashboard → API → API Settings, ensure the Data API exposes the `public` schema and the `anon` role has the required table grants (the SQL includes explicit grants).
4. Ensure Realtime is enabled for `public.chat_guest_messages` (the schema adds it to `supabase_realtime`).
5. Serve the repository locally:
   ```bash
   python -m http.server 8000
   ```
6. Open http://localhost:8000.

## Privacy and abuse considerations

This is intentionally a **public, anonymous chat**. Messages, display names, room names, and room presence are visible to anyone who can access the app. A display name is not verified identity and can be impersonated. The sender key is a random browser-local identifier used only to distinguish a visitor's own messages; it is not authentication.

Because there is no account identity, this version does not offer private DMs or private file attachments. The database now applies per-sender-key posting/reaction limits and duplicate-message checks. Reports are stored privately and reviewed through a trusted Supabase Edge Function. Anonymous sender keys are still user-controlled and can be reset or spoofed, so rate limits and restrictions are best-effort anti-abuse controls rather than verified identity or IP-level enforcement. Never put a Supabase service-role or secret key in browser code.

## Deployment

GitHub Actions validates JavaScript module syntax, checks required HTML IDs, verifies that no privileged Supabase key is included in the browser configuration, and deploys the static site to GitHub Pages on pushes to `main`.

## Message controls

- Reply to a message to create a lightweight threaded conversation in the room.
- Reply to messages, react with persistent emoji, and see one moderator-pinned message per room.
- Report messages for spam, harassment, hate, personal information, or other concerns. Reports are private to the moderation service.
- Database triggers throttle bursts (5 messages per 15 seconds and 20 reactions per 15 seconds per sender key) and block immediate duplicate-message spam.
- Edit or delete messages from the browser that originally posted them. Each message receives a random 256-bit owner token; only its SHA-256 hash is stored in the database. Clearing browser storage or switching devices means that browser can no longer manage that message.
- Guest chat is public and anonymous. Display names and sender identities are not verified; use moderation and rate limiting before opening this community to a large audience.

### Enable moderator access

The moderation center and public report submission use the deployed `chat-moderation` Supabase Edge Function. To activate moderator-only report review, guest restrictions, message removal, and room pins:

1. Open Supabase Dashboard → **Edge Functions → Secrets** for this project.
2. Add `CHAT_MODERATOR_SECRET` with a randomly generated value of at least 32 characters (use a password manager; do not commit it or send it in chat).
3. Open Commonroom, select **Moderation**, and enter the same secret. It is kept in the current browser tab session and can be locked at any time.

Without this secret, public reporting and database anti-spam protections still work, but privileged moderation actions remain locked. The Edge Function uses the project's server-side Supabase secret key; no privileged key is shipped to the browser.
