import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "https://tejas-mk2.github.io",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-moderator-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
const equalSecret = (a: string, b: string) => {
  const aa = new TextEncoder().encode(a), bb = new TextEncoder().encode(b);
  if (aa.length !== bb.length) return false;
  let diff = 0;
  for (let i = 0; i < aa.length; i++) diff |= aa[i] ^ bb[i];
  return diff === 0;
};
const uuid = (value: unknown): value is string =>
  typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);

const databaseUrl = Deno.env.get("SUPABASE_DB_URL");
if (!databaseUrl) throw new Error("SUPABASE_DB_URL is unavailable.");
const db = postgres(databaseUrl, { max: 1, prepare: false, connect_timeout: 10, idle_timeout: 20 });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);
  const origin = req.headers.get("origin");
  if (origin && origin !== "https://tejas-mk2.github.io") return json({ error: "Origin not allowed." }, 403);
  if (Number(req.headers.get("content-length") || 0) > 16000) return json({ error: "Request is too large." }, 413);
  let payload: Record<string, unknown>;
  try { payload = await req.json(); } catch { return json({ error: "Invalid JSON." }, 400); }

  try {
    if (payload.action === "report") {
      if (!uuid(payload.message_id) || !uuid(payload.reporter_key) ||
          !["spam", "harassment", "hate", "personal-info", "other"].includes(String(payload.reason))) {
        return json({ error: "Please provide a valid report." }, 400);
      }
      const details = typeof payload.details === "string" ? payload.details.trim().slice(0, 500) : "";
      await db`insert into public.chat_guest_reports (message_id, reporter_key, reason, details)
        values (${payload.message_id}, ${payload.reporter_key}, ${String(payload.reason)}, ${details})
        on conflict (message_id, reporter_key) do nothing`;
      return json({ ok: true });
    }

    if (payload.action === "edit-own-message" || payload.action === "delete-own-message") {
      if (!uuid(payload.message_id) || typeof payload.owner_token !== "string" || payload.owner_token.length < 32) {
        return json({ error: "Invalid owner credentials." }, 400);
      }
      const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(payload.owner_token));
      const tokenHash = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
      const owned = await db`select id from public.chat_guest_messages
        where id = ${payload.message_id}::uuid and edit_token_hash = ${tokenHash} limit 1`;
      if (!owned.length) return json({ error: "This browser cannot manage that message." }, 403);
      if (payload.action === "edit-own-message") {
        const body = typeof payload.body === "string" ? payload.body.trim() : "";
        if (!body || body.length > 2000) return json({ error: "Message text must be between 1 and 2000 characters." }, 400);
        await db`update public.chat_guest_messages set body = ${body}, edited_at = now()
          where id = ${payload.message_id}::uuid and edit_token_hash = ${tokenHash}`;
      } else {
        await db`delete from public.chat_guest_messages
          where id = ${payload.message_id}::uuid and edit_token_hash = ${tokenHash}`;
      }
      return json({ ok: true });
    }

    const configured = Deno.env.get("CHAT_MODERATOR_SECRET") ?? "";
    const supplied = req.headers.get("x-moderator-key") ?? "";
    if (configured.length < 32) return json({ error: "Moderator access has not been configured. Add CHAT_MODERATOR_SECRET in Supabase Edge Function secrets." }, 503);
    if (!equalSecret(supplied, configured)) return json({ error: "Moderator key is invalid." }, 401);

    if (payload.action === "list-reports") {
      const reports = await db`select id, message_id, reporter_key, reason, details, status, created_at
        from public.chat_guest_reports where status = 'open'
        order by created_at desc limit 100`;
      const ids = [...new Set(reports.map((item) => item.message_id))];
      const messages = ids.length
        ? await db`select id, body, sender_name, sender_key, room_id, created_at
            from public.chat_guest_messages where id = any(${ids}::uuid[])`
        : [];
      return json({ reports, messages });
    }
    if (payload.action === "list-blocks") {
      const blocks = await db`select sender_key, reason, created_at, expires_at
        from public.chat_guest_moderation_blocks order by created_at desc limit 100`;
      return json({ blocks });
    }
    if (payload.action === "resolve-report") {
      if (!uuid(payload.report_id)) return json({ error: "Invalid report." }, 400);
      const status = payload.status === "dismissed" ? "dismissed" : "reviewed";
      await db`update public.chat_guest_reports set status = ${status} where id = ${payload.report_id}::uuid`;
      return json({ ok: true });
    }
    if (payload.action === "delete-message") {
      if (!uuid(payload.message_id)) return json({ error: "Invalid message." }, 400);
      await db`delete from public.chat_guest_messages where id = ${payload.message_id}::uuid`;
      return json({ ok: true });
    }
    if (payload.action === "ban-guest" || payload.action === "unban-guest") {
      if (!uuid(payload.sender_key)) return json({ error: "Invalid guest." }, 400);
      if (payload.action === "ban-guest") {
        const reason = typeof payload.reason === "string" ? payload.reason.trim().slice(0, 160) : "Community guidelines";
        await db`insert into public.chat_guest_moderation_blocks (sender_key, reason, expires_at)
          values (${payload.sender_key}::uuid, ${reason}, null)
          on conflict (sender_key) do update set reason = excluded.reason, expires_at = null`;
      } else {
        await db`delete from public.chat_guest_moderation_blocks where sender_key = ${payload.sender_key}::uuid`;
      }
      return json({ ok: true });
    }
    if (payload.action === "pin-message") {
      if (!uuid(payload.room_id) || !uuid(payload.message_id)) return json({ error: "Invalid pin request." }, 400);
      const moderatorKey = uuid(payload.moderator_key) ? payload.moderator_key : "00000000-0000-4000-8000-000000000000";
      await db`insert into public.chat_guest_pins (room_id, message_id, pinned_by)
        values (${payload.room_id}::uuid, ${payload.message_id}::uuid, ${moderatorKey}::uuid)
        on conflict (room_id) do update set message_id = excluded.message_id,
          pinned_by = excluded.pinned_by, created_at = now()`;
      return json({ ok: true });
    }
    if (payload.action === "unpin-message") {
      if (!uuid(payload.room_id)) return json({ error: "Invalid room." }, 400);
      await db`delete from public.chat_guest_pins where room_id = ${payload.room_id}::uuid`;
      return json({ ok: true });
    }
    return json({ error: "Unknown action." }, 400);
  } catch (error) {
    console.error("chat-moderation request failed", error);
    return json({ error: "The moderation service could not complete that request." }, 500);
  }
});
