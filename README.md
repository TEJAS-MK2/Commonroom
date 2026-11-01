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

Because there is no account identity, this version does not offer private DMs or private file attachments. Public anonymous posting can attract spam or abuse; before sharing widely, add server-side rate limiting, moderation/reporting, and retention controls (for example through a trusted Edge Function or another server-side boundary). Never put a Supabase service-role or secret key in browser code.

## Deployment

GitHub Actions validates JavaScript module syntax, checks required HTML IDs, verifies that no privileged Supabase key is included in the browser configuration, and deploys the static site to GitHub Pages on pushes to `main`.
