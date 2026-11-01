# Chat

A clean, responsive real-time messaging app built with HTML, CSS, JavaScript, and Supabase.

## Features

- Email/password authentication with Supabase Auth
- Public chat rooms: General, Coding, and Random
- Create additional public rooms
- Private one-to-one direct messages
- Private file sharing in direct messages (images, PDFs, and text files up to 10 MB)
- Real-time message delivery with Supabase Realtime / Postgres Changes
- Online user count with Realtime Presence
- Typing indicators with Realtime Broadcast
- Responsive desktop and mobile interface
- Row Level Security on every application table

## Stack

- HTML, CSS, JavaScript (ES modules)
- Supabase Auth, PostgreSQL, Realtime
- Supabase JavaScript SDK loaded from a pinned ESM CDN version

## Setup

The connected Supabase project is already configured in `supabase/config.js`.

1. In Supabase Dashboard → Authentication → Providers, make sure Email authentication is enabled.
2. The schema is in `supabase/schema.sql`. It has been applied to the connected project using isolated `chat_*` tables, so existing project tables are not overwritten.
3. Serve the repository with a local static web server:

   ```bash
   python -m http.server 8000
   ```

4. Open http://localhost:8000 and create an account.
5. If email confirmation is enabled, confirm your email before signing in. Add local and deployed URLs to the Supabase Auth URL configuration.

## Security

The browser uses only a Supabase publishable key, which is intended for client-side use. Never add a `service_role` or secret key to frontend code. All application tables have Row Level Security enabled. Users can only create messages with their own authenticated user ID.

## Deployment

A GitHub Actions workflow validates the JavaScript module syntax, checks required HTML elements and verifies that no privileged Supabase key is included in the browser bundle. On pushes to `main`, it assembles and deploys the static site to GitHub Pages. The workflow uses the GitHub Pages Actions deployment flow; ensure Pages is enabled for the repository and configured to use GitHub Actions.

## Current scope

Public rooms are visible to authenticated users. Direct messages are restricted to their two participants. Attachments use a private Storage bucket with membership-based access policies and one-hour signed download URLs. Message editing, moderation, and push notifications are not included yet.