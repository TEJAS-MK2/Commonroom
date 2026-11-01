import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.57.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "https://tejas-mk2.github.io",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-moderator-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
const equalSecret = (a: string, b: string) => {
  const encoder = new TextEncoder();
  const aa = encoder.encode(a), bb = encoder.encode(b);
  if (aa.length !== bb.length) return false;
  let diff = 0;
  for (let i = 0; i < aa.length; i++) diff |= aa[i] ^ bb[i];
  return diff === 0;
};
const uuid = (value: unknown): value is string =>
  typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);
  const origin = req.headers.get("origin");
  if (origin && origin !== "https://tejas-mk2.github.io") {
    return json({ error: "Origin not allowed." }, 403);
  }
  const contentLength = Number(req.headers.get("content-length") || 0);
  if (contentLength > 16000) return json({ error: "Request is too large." }, 413);
  let payload: Record<string, unknown>;
  try { payload = await req.json(); } catch { return json({ error: "Invalid JSON." }, 400); }
  const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
  const serviceKey = keys.default ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const url = Deno.env.get("SUPABASE_URL");
  if (!url || !serviceKey) return json({ error: "Moderation service is not configured." }, 503);
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

  if (payload.action === "report") {
    if (!uuid(payload.message_id) || !uuid(payload.reporter_key) ||
        !["spam", "harassment", "hate", "personal-info", "other"].includes(String(payload.reason))) {
      return json({ error: "Please provide a valid report." }, 400);
    }
    const details = typeof payload.details === "string" ? payload.details.trim().slice(0, 500) : "";
    const { error } = await admin.from("chat_guest_reports").upsert({
      message_id: payload.message_id, reporter_key: payload.reporter_key,
      reason: payload.reason, details, status: "open",
    }, { onConflict: "message_id,reporter_key", ignoreDuplicates: true });
    if (error) return json({ error: "Could not submit the report." }, 500);
    return json({ ok: true });
  }


  if (payload.action === "edit-own-message" || payload.action === "delete-own-message") {
    if (!uuid(payload.message_id) || typeof payload.owner_token !== "string" || payload.owner_token.length < 32) return json({ error: "Invalid owner credentials." }, 400);
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(payload.owner_token));
    const tokenHash = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
    const { data: owned, error: lookupError } = await admin.from("chat_guest_messages").select("id").eq("id", payload.message_id).eq("edit_token_hash", tokenHash).maybeSingle();
    if (lookupError || !owned) return json({ error: "This browser cannot manage that message." }, 403);
    if (payload.action === "edit-own-message") {
      const body = typeof payload.body === "string" ? payload.body.trim() : "";
      if (!body || body.length > 2000) return json({ error: "Message text must be between 1 and 2000 characters." }, 400);
      const { error } = await admin.from("chat_guest_messages").update({ body, edited_at: new Date().toISOString() }).eq("id", payload.message_id).eq("edit_token_hash", tokenHash);
      return error ? json({ error: "Could not update message." }, 500) : json({ ok: true });
    }
    const { error } = await admin.from("chat_guest_messages").delete().eq("id", payload.message_id).eq("edit_token_hash", tokenHash);
    return error ? json({ error: "Could not delete message." }, 500) : json({ ok: true });
  }

  const configured = Deno.env.get("CHAT_MODERATOR_SECRET");
  const supplied = req.headers.get("x-moderator-key") ?? "";
  if (!configured || configured.length < 32) return json({ error: "Moderator access has not been configured yet. Add CHAT_MODERATOR_SECRET in Supabase Edge Function secrets." }, 503);
  if (!equalSecret(supplied, configured)) return json({ error: "Moderator key is invalid." }, 401);

  if (payload.action === "list-reports") {
    const { data, error } = await admin.from("chat_guest_reports")
      .select("id,message_id,reporter_key,reason,details,status,created_at")
      .eq("status", "open").order("created_at", { ascending: false }).limit(100);
    if (error) return json({ error: "Could not load reports." }, 500);
    const ids = [...new Set((data ?? []).map((item) => item.message_id))];
    const { data: messages } = ids.length
      ? await admin.from("chat_guest_messages").select("id,body,sender_name,sender_key,room_id,created_at").in("id", ids)
      : { data: [] };
    return json({ reports: data ?? [], messages: messages ?? [] });
  }

  if (payload.action === "list-blocks") {
    const { data, error } = await admin.from("chat_guest_moderation_blocks").select("sender_key,reason,created_at,expires_at").order("created_at", { ascending: false }).limit(100);
    return error ? json({ error: "Could not load restricted guests." }, 500) : json({ blocks: data ?? [] });
  }
  if (payload.action === "resolve-report") {
    if (!uuid(payload.report_id)) return json({ error: "Invalid report." }, 400);
    const status = payload.status === "dismissed" ? "dismissed" : "reviewed";
    const { error } = await admin.from("chat_guest_reports").update({ status }).eq("id", payload.report_id);
    return error ? json({ error: "Could not update report." }, 500) : json({ ok: true });
  }
  if (payload.action === "delete-message") {
    if (!uuid(payload.message_id)) return json({ error: "Invalid message." }, 400);
    const { error } = await admin.from("chat_guest_messages").delete().eq("id", payload.message_id);
    return error ? json({ error: "Could not delete message." }, 500) : json({ ok: true });
  }
  if (payload.action === "ban-guest" || payload.action === "unban-guest") {
    if (!uuid(payload.sender_key)) return json({ error: "Invalid guest." }, 400);
    if (payload.action === "ban-guest") {
      const reason = typeof payload.reason === "string" ? payload.reason.trim().slice(0, 160) : "Community guidelines";
      const { error } = await admin.from("chat_guest_moderation_blocks").upsert({ sender_key: payload.sender_key, reason, expires_at: null });
      if (error) return json({ error: "Could not restrict this guest." }, 500);
    } else {
      const { error } = await admin.from("chat_guest_moderation_blocks").delete().eq("sender_key", payload.sender_key);
      if (error) return json({ error: "Could not lift this restriction." }, 500);
    }
    return json({ ok: true });
  }
  if (payload.action === "pin-message") {
    if (!uuid(payload.room_id) || !uuid(payload.message_id)) return json({ error: "Invalid pin request." }, 400);
    const { error } = await admin.from("chat_guest_pins").upsert({
      room_id: payload.room_id, message_id: payload.message_id,
      pinned_by: uuid(payload.moderator_key) ? payload.moderator_key : "00000000-0000-4000-8000-000000000000",
    }, { onConflict: "room_id" });
    return error ? json({ error: "Could not pin this message." }, 500) : json({ ok: true });
  }
  if (payload.action === "unpin-message") {
    if (!uuid(payload.room_id)) return json({ error: "Invalid room." }, 400);
    const { error } = await admin.from("chat_guest_pins").delete().eq("room_id", payload.room_id);
    return error ? json({ error: "Could not remove the pin." }, 500) : json({ ok: true });
  }
  return json({ error: "Unknown action." }, 400);
});
