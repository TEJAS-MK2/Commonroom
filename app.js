import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.4";
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from "./supabase/config.js";

const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false }
});
const $ = (selector) => document.querySelector(selector);
const storage = {
  get(key, fallback = "") { try { return localStorage.getItem(key) || fallback; } catch { return fallback; } },
  set(key, value) { try { localStorage.setItem(key, value); } catch { /* Private browsing can disable storage. */ } }
};
const state = {
  name: storage.get("commonroom-name", ""),
  senderKey: storage.get("commonroom-guest-id", ""),
  rooms: [], activeRoom: null, messages: [], messageChannel: null,
  typingChannel: null, presence: null, typingTimer: null, online: new Map()
};
if (!state.senderKey) {
  state.senderKey = crypto.randomUUID();
  storage.set("commonroom-guest-id", state.senderKey);
}
function escapeHtml(value = "") {
  return String(value).replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
}
function initials(name = "Guest") {
  return name.trim().split(/\s+/).slice(0, 2).map((part) => part[0]).join("").toUpperCase() || "G";
}
function toast(message) {
  const node = $("#toast"); node.textContent = message; node.classList.add("show");
  clearTimeout(toast.timer); toast.timer = setTimeout(() => node.classList.remove("show"), 3000);
}
function formatTime(date) {
  return new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" }).format(new Date(date));
}
function formatDay(date) {
  return new Intl.DateTimeFormat(undefined, { weekday: "long", month: "long", day: "numeric" }).format(new Date(date));
}
function setName(name) {
  const clean = name.trim().replace(/\s+/g, " ").slice(0, 32);
  if (clean.length < 2) throw new Error("Your display name needs at least 2 characters.");
  state.name = clean;
  storage.set("commonroom-name", clean);
  $("#my-name").textContent = clean;
  $("#my-avatar").textContent = initials(clean);
}
function askForName() {
  let name = window.prompt("Choose a display name (2–32 characters):", state.name || "Guest");
  if (name === null && !state.name) name = "Guest";
  if (name !== null) {
    try { setName(name); }
    catch (error) { toast(error.message); if (!state.name) setName("Guest"); }
  }
  if (!state.name) setName("Guest");
}
function renderRooms() {
  $("#room-count").textContent = String(state.rooms.length).padStart(2, "0");
  $("#room-list").innerHTML = state.rooms.map((room) => `
    <button class="room-item ${state.activeRoom?.id === room.id ? "active" : ""}" data-room="${room.id}">
      <span class="room-hash">#</span><span class="room-name">${escapeHtml(room.name)}</span>
      ${state.activeRoom?.id === room.id ? '<span class="active-mark"></span>' : ""}
    </button>`).join("");
  $("#room-list").querySelectorAll("[data-room]").forEach((button) => button.addEventListener("click", () => {
    selectRoom(button.dataset.room).catch((error) => toast(error.message || "Could not open this room."));
  }));
}
async function loadRooms() {
  const { data, error } = await supabase.from("chat_rooms").select("id,slug,name,description").order("name");
  if (error) throw error;
  state.rooms = data || [];
  if (!state.rooms.length) throw new Error("No chat rooms are available yet.");
  renderRooms();
  const preferred = state.rooms.find((room) => room.slug === "general") || state.rooms[0];
  await selectRoom(preferred.id);
}
async function waitForSubscription(channel) {
  return new Promise((resolve) => {
    const timeout = setTimeout(() => resolve(false), 10000);
    channel.subscribe((status) => {
      if (status === "SUBSCRIBED") { clearTimeout(timeout); resolve(true); }
      if (["CHANNEL_ERROR", "TIMED_OUT", "CLOSED"].includes(status)) { clearTimeout(timeout); resolve(false); }
    });
  });
}
async function selectRoom(roomId) {
  const room = state.rooms.find((item) => item.id === roomId);
  if (!room) return;
  if (state.messageChannel) await supabase.removeChannel(state.messageChannel);
  if (state.typingChannel) await supabase.removeChannel(state.typingChannel);
  state.activeRoom = room;
  state.messages = [];
  $("#active-room-name").textContent = room.name;
  $("#room-description").textContent = room.description || "A place to talk.";
  $("#message-input").placeholder = `Write to #${room.name}…`;
  $("#typing-line").textContent = "";
  renderRooms();
  $("#messages").innerHTML = '<div class="loading-state">Loading the conversation…</div>';

  state.messageChannel = supabase.channel(`commonroom-messages:${room.id}`);
  state.messageChannel.on("postgres_changes", {
    event: "INSERT", schema: "public", table: "chat_guest_messages", filter: `room_id=eq.${room.id}`
  }, ({ new: message }) => {
    if (!state.messages.some((item) => item.id === message.id)) {
      state.messages.push(message);
      state.messages.sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
      renderMessages();
    }
  });
  const messageReady = await waitForSubscription(state.messageChannel);
  if (!messageReady) toast("Live updates are taking longer than expected.");

  state.typingChannel = supabase.channel(`commonroom-typing:${room.id}`);
  state.typingChannel.on("broadcast", { event: "typing" }, ({ payload }) => showTyping(payload));
  const typingReady = await waitForSubscription(state.typingChannel);
  if (!typingReady) console.warn("Typing channel unavailable.");

  await loadMessages(room.id);
  await connectPresence(room.id);
  $("#sidebar").classList.remove("open");
}
async function loadMessages(roomId) {
  const { data, error } = await supabase.from("chat_guest_messages")
    .select("id,room_id,sender_key,sender_name,body,created_at")
    .eq("room_id", roomId).order("created_at", { ascending: false }).limit(100);
  if (error) throw error;
  if (state.activeRoom?.id !== roomId) return;
  const existing = new Map((data || []).map((message) => [message.id, message]));
  for (const message of state.messages) existing.set(message.id, message);
  state.messages = [...existing.values()].sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
  renderMessages();
}
function renderMessages() {
  const container = $("#messages");
  if (!state.messages.length) {
    container.innerHTML = '<div class="empty-state"><div class="empty-illustration">✳</div><span class="empty-kicker">A FRESH START</span><h2>It’s quiet in here.</h2><p>Be the first to say hello and set the tone.</p></div>';
    return;
  }
  let lastDay = "";
  container.innerHTML = state.messages.map((message) => {
    const day = new Date(message.created_at).toDateString();
    const separator = day !== lastDay ? `<div class="day-divider"><span>${escapeHtml(formatDay(message.created_at))}</span></div>` : "";
    lastDay = day;
    const mine = message.sender_key === state.senderKey;
    const name = message.sender_name || "Guest";
    return `${separator}<article class="message ${mine ? "mine" : ""}">
      <div class="avatar message-avatar ${mine ? "self-avatar" : ""}">${escapeHtml(initials(name))}</div>
      <div class="message-content"><div class="message-meta"><strong>${escapeHtml(name)}</strong>${mine ? '<span class="you-tag">YOU</span>' : ""}<time>${formatTime(message.created_at)}</time></div><p>${escapeHtml(message.body).replace(/\n/g, "<br>")}</p></div>
    </article>`;
  }).join("");
  container.scrollTop = container.scrollHeight;
}
async function connectPresence(roomId) {
  if (state.presence) await supabase.removeChannel(state.presence);
  state.online.clear();
  state.presence = supabase.channel(`commonroom-presence:${roomId}`, { config: { presence: { key: state.senderKey } } });
  state.presence.on("presence", { event: "sync" }, updateOnline);
  state.presence.on("presence", { event: "join" }, updateOnline);
  state.presence.on("presence", { event: "leave" }, updateOnline);
  state.presence.subscribe(async (status) => {
    if (status === "SUBSCRIBED") {
      await state.presence.track({ guest_id: state.senderKey, name: state.name, online_at: new Date().toISOString() });
    }
  });
}
function updateOnline() {
  const presenceState = state.presence?.presenceState() || {};
  const people = Object.values(presenceState).flat();
  const unique = [...new Map(people.map((person) => [person.guest_id, person])).values()];
  $("#online-count").textContent = `${unique.length} online`;
  $("#online-stack").innerHTML = unique.slice(0, 4).map((person) =>
    `<span class="online-avatar" title="${escapeHtml(person.name)}">${escapeHtml(initials(person.name))}</span>`).join("");
}
function showTyping(payload) {
  if (!payload || payload.guest_id === state.senderKey) return;
  $("#typing-line").textContent = `${payload.name || "Someone"} is typing…`;
  clearTimeout(state.typingTimer);
  state.typingTimer = setTimeout(() => { $("#typing-line").textContent = ""; }, 1800);
}
$("#message-input").addEventListener("input", () => {
  if (!state.typingChannel || !$("#message-input").value.trim()) return;
  state.typingChannel.send({ type: "broadcast", event: "typing", payload: { guest_id: state.senderKey, name: state.name } });
});
$("#message-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const input = $("#message-input");
  const body = input.value.trim();
  if (!body || !state.activeRoom) return;
  const button = $("#send-button"); button.disabled = true;
  try {
    const { error } = await supabase.from("chat_guest_messages").insert({
      room_id: state.activeRoom.id, sender_key: state.senderKey, sender_name: state.name, body
    });
    if (error) throw error;
    input.value = ""; input.focus();
  } catch (error) {
    toast(error.message || "Your message could not be sent.");
  } finally { button.disabled = false; }
});
$("#emoji-button").addEventListener("click", () => {
  const input = $("#message-input");
  input.value += " 🙂"; input.focus(); input.dispatchEvent(new Event("input"));
});
$("#new-room").addEventListener("click", async () => {
  const raw = window.prompt("Name your new public room (letters, numbers and hyphens):");
  if (!raw) return;
  const slug = raw.trim().toLowerCase().replace(/[^a-z0-9-]+/g, "-").replace(/^-|-$/g, "").slice(0, 40);
  if (slug.length < 2) { toast("Room names need at least 2 characters."); return; }
  const { data, error } = await supabase.from("chat_rooms")
    .insert({ slug, name: slug, description: "A new place to connect.", created_by: null })
    .select("id,slug,name,description").single();
  if (error) { toast(error.code === "23505" ? "That room already exists." : error.message); return; }
  state.rooms.push(data); state.rooms.sort((a, b) => a.name.localeCompare(b.name));
  renderRooms(); await selectRoom(data.id);
});
$("#change-name").addEventListener("click", () => {
  const next = window.prompt("Change your display name:", state.name);
  if (next === null) return;
  try { setName(next); state.presence?.track({ guest_id: state.senderKey, name: state.name, online_at: new Date().toISOString() }); toast("Display name updated."); }
  catch (error) { toast(error.message); }
});
$("#mobile-menu").addEventListener("click", () => $("#sidebar").classList.toggle("open"));
window.addEventListener("pagehide", () => {
  if (state.presence) supabase.removeChannel(state.presence);
});
askForName();
$("#my-name").textContent = state.name;
$("#my-avatar").textContent = initials(state.name);
try { await loadRooms(); }
catch (error) {
  console.error(error);
  $("#messages").innerHTML = '<div class="empty-state"><div class="empty-illustration">!</div><h2>We couldn’t connect.</h2><p>Check the Supabase project settings and try refreshing.</p></div>';
  toast(error.message || "Unable to connect to chat.");
}
