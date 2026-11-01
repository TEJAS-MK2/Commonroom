import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.4";
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from "./supabase/config.js";

const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);
const $ = (selector) => document.querySelector(selector);
const state = { user: null, profile: null, rooms: [], activeRoom: null, messages: [], channel: null, typingChannel: null, presence: null, typingTimer: null, isSignUp: false, online: new Map() };

const authScreen = $("#auth-screen");
const chatScreen = $("#chat-screen");
const authForm = $("#auth-form");
const authMessage = $("#auth-message");
const messageInput = $("#message-input");

function escapeHtml(value = "") {
  return String(value).replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
}
function initials(name = "U") { return name.trim().split(/\s+/).slice(0, 2).map((part) => part[0]).join("").toUpperCase() || "U"; }
function toast(message) {
  const node = $("#toast"); node.textContent = message; node.classList.add("show");
  window.clearTimeout(toast.timer); toast.timer = window.setTimeout(() => node.classList.remove("show"), 3200);
}
function setAuthMessage(message, error = false) {
  authMessage.textContent = message; authMessage.classList.toggle("error", error);
}
function showApp(signedIn) {
  authScreen.classList.toggle("hidden", signedIn);
  chatScreen.classList.toggle("hidden", !signedIn);
}
function formatTime(date) {
  return new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" }).format(new Date(date));
}
function formatDay(date) {
  return new Intl.DateTimeFormat(undefined, { weekday: "long", month: "long", day: "numeric" }).format(new Date(date));
}

$("#auth-switch").addEventListener("click", () => {
  state.isSignUp = !state.isSignUp;
  $("#name-field").classList.toggle("hidden", !state.isSignUp);
  $("#auth-submit").innerHTML = state.isSignUp ? 'Create account <span>→</span>' : 'Sign in <span>→</span>';
  $("#auth-switch-copy").textContent = state.isSignUp ? "Already have an account?" : "New around here?";
  $("#auth-switch").textContent = state.isSignUp ? "Sign in" : "Create an account";
  $("#password").autocomplete = state.isSignUp ? "new-password" : "current-password";
  setAuthMessage("");
});

authForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const email = $("#email").value.trim();
  const password = $("#password").value;
  const displayName = $("#display-name").value.trim();
  const button = $("#auth-submit");
  button.disabled = true; button.textContent = state.isSignUp ? "Creating account…" : "Signing in…";
  setAuthMessage("");
  try {
    if (state.isSignUp) {
      if (displayName.length < 2) throw new Error("Choose a display name with at least 2 characters.");
      const { data, error } = await supabase.auth.signUp({ email, password, options: { data: { display_name: displayName } } });
      if (error) throw error;
      if (!data.session) {
        setAuthMessage("Check your inbox to confirm your email, then come back to sign in.");
      } else {
        await startApp(data.user);
      }
    } else {
      const { data, error } = await supabase.auth.signInWithPassword({ email, password });
      if (error) throw error;
      await startApp(data.user);
    }
  } catch (error) { setAuthMessage(error.message || "Something went wrong. Please try again.", true); }
  finally {
    button.disabled = false;
    button.innerHTML = state.isSignUp ? 'Create account <span>→</span>' : 'Sign in <span>→</span>';
  }
});

async function ensureProfile(user) {
  const fallback = user.user_metadata?.display_name || user.email?.split("@")[0] || "Member";
  const { data: existing, error: readError } = await supabase.from("chat_profiles").select("*").eq("id", user.id).maybeSingle();
  if (readError) throw readError;
  if (existing) { state.profile = existing; return; }
  const { data, error } = await supabase.from("chat_profiles").insert({ id: user.id, display_name: fallback.slice(0, 32) }).select().single();
  if (error) throw error;
  state.profile = data;
}
async function startApp(user) {
  state.user = user;
  await ensureProfile(user);
  $("#my-name").textContent = state.profile.display_name;
  $("#my-email").textContent = user.email || "online";
  $("#my-avatar").textContent = initials(state.profile.display_name);
  showApp(true);
  await loadRooms();
  await connectPresence();
}
async function loadRooms() {
  const { data, error } = await supabase.from("chat_rooms").select("*").order("name");
  if (error) throw error;
  state.rooms = data || [];
  if (!state.rooms.length) {
    const { data: created, error: createError } = await supabase.from("chat_rooms").insert([
      { slug: "general", name: "general", description: "A place for everyday conversations.", created_by: state.user.id }
    ]).select();
    if (createError) throw createError;
    state.rooms = created || [];
  }
  renderRooms();
  await selectRoom(state.activeRoom?.id && state.rooms.some((room) => room.id === state.activeRoom.id) ? state.activeRoom.id : state.rooms[0].id);
}
function renderRooms() {
  $("#room-list").innerHTML = state.rooms.map((room) => `
    <button class="room-item ${state.activeRoom?.id === room.id ? "active" : ""}" data-room="${room.id}">
      <span class="room-hash">#</span><span>${escapeHtml(room.name)}</span><span class="room-unread"></span>
    </button>`).join("");
  $("#room-list").querySelectorAll("[data-room]").forEach((button) => button.addEventListener("click", () => selectRoom(button.dataset.room)));
}
async function waitForSubscription(channel) {
  return new Promise((resolve) => {
    channel.subscribe((status) => {
      if (status === "SUBSCRIBED") resolve(true);
      if (["CHANNEL_ERROR", "TIMED_OUT", "CLOSED"].includes(status)) resolve(false);
    });
  });
}
async function selectRoom(roomId) {
  const room = state.rooms.find((item) => item.id === roomId);
  if (!room) return;
  if (state.channel) { await supabase.removeChannel(state.channel); state.channel = null; }
  if (state.typingChannel) { await supabase.removeChannel(state.typingChannel); state.typingChannel = null; }
  state.activeRoom = room;
  state.messages = [];
  $("#active-room-name").textContent = room.name;
  $("#room-description").textContent = room.description || "A place to talk.";
  messageInput.placeholder = `Message #${room.name}`;
  renderRooms();
  $("#messages").innerHTML = '<div class="loading-state">Loading conversation…</div>';

  // Postgres Changes uses a public channel; row visibility is still enforced by
  // the chat_messages SELECT policy. Broadcast typing uses a separate private channel.
  state.channel = supabase.channel(`chat-db:${room.id}`);
  state.channel.on("postgres_changes", { event: "INSERT", schema: "public", table: "chat_messages", filter: `room_id=eq.${room.id}` }, (payload) => {
    if (!state.messages.some((message) => message.id === payload.new.id)) {
      state.messages.push(payload.new);
      renderMessages();
      loadSenderForMessage(payload.new);
    }
  });
  const dbReady = await waitForSubscription(state.channel);
  if (!dbReady) toast("Live message updates could not connect. Check your Realtime settings.");

  await supabase.realtime.setAuth();
  state.typingChannel = supabase.channel(`chat-room:${room.id}`, { config: { private: true } });
  state.typingChannel.on("broadcast", { event: "typing" }, ({ payload }) => showTyping(payload));
  const typingReady = await waitForSubscription(state.typingChannel);
  if (!typingReady) toast("Typing indicators are temporarily unavailable.");

  await loadMessages();
}
async function loadMessages() {
  $("#messages").innerHTML = '<div class="loading-state">Loading conversation…</div>';
  const { data, error } = await supabase.from("chat_messages")
    .select("id, room_id, sender_id, body, created_at, chat_profiles(display_name, avatar_url)")
    .eq("room_id", state.activeRoom.id).order("created_at", { ascending: false }).limit(100);
  if (error) { $("#messages").innerHTML = '<div class="empty-state"><h3>Could not load messages.</h3><p>Check your Supabase setup and refresh.</p></div>'; throw error; }
  const fromDatabase = (data || []).reverse().map((message) => ({ ...message, profile: message.chat_profiles, sender_name: message.chat_profiles?.display_name || "Member" }));
  const merged = new Map(fromDatabase.map((message) => [message.id, message]));
  // Preserve inserts received while the initial history query was in flight.
  for (const message of state.messages) if (!merged.has(message.id)) merged.set(message.id, message);
  state.messages = [...merged.values()].sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
  renderMessages();
}
async function loadSenderForMessage(message) {
  const { data } = await supabase.from("chat_profiles").select("display_name").eq("id", message.sender_id).maybeSingle();
  const found = state.messages.find((item) => item.id === message.id);
  if (found && data) { found.sender_name = data.display_name; renderMessages(); }
}
function renderMessages() {
  const container = $("#messages");
  if (!state.messages.length) {
    container.innerHTML = '<div class="empty-state"><div class="empty-icon">✳</div><h3>Make the first move.</h3><p>Say hello and start the conversation.</p></div>';
    return;
  }
  let lastDay = "";
  container.innerHTML = state.messages.map((message) => {
    const day = new Date(message.created_at).toDateString();
    const separator = day !== lastDay ? `<div class="day-divider"><span>${escapeHtml(formatDay(message.created_at))}</span></div>` : "";
    lastDay = day;
    const mine = message.sender_id === state.user.id;
    const name = message.sender_name || message.profile?.display_name || "Member";
    return `${separator}<article class="message ${mine ? "mine" : ""}">
      <div class="avatar message-avatar">${escapeHtml(initials(name))}</div>
      <div class="message-content"><div class="message-meta"><strong>${escapeHtml(name)}</strong><time>${formatTime(message.created_at)}</time></div><p>${escapeHtml(message.body).replace(/\n/g, "<br>")}</p></div>
    </article>`;
  }).join("");
  container.scrollTop = container.scrollHeight;
}
async function connectPresence() {
  if (state.presence) await supabase.removeChannel(state.presence);
  await supabase.realtime.setAuth();
  state.presence = supabase.channel("chat-presence", { config: { private: true, presence: { key: state.user.id } } });
  state.presence.on("presence", { event: "sync" }, updateOnline);
  state.presence.on("presence", { event: "join" }, updateOnline);
  state.presence.on("presence", { event: "leave" }, updateOnline);
  state.presence.subscribe(async (status) => {
    if (status === "SUBSCRIBED") {
      await state.presence.track({ user_id: state.user.id, name: state.profile.display_name, online_at: new Date().toISOString() });
    }
  });
}
function updateOnline() {
  const presenceState = state.presence?.presenceState() || {};
  const people = Object.values(presenceState).flat().filter((person) => person.user_id !== state.user.id);
  $("#online-count").textContent = `${people.length + 1} online`;
  $("#online-stack").innerHTML = people.slice(0, 4).map((person) => `<span class="online-avatar" title="${escapeHtml(person.name)}">${escapeHtml(initials(person.name))}</span>`).join("");
}
function showTyping(payload) {
  if (!payload || payload.user_id === state.user.id) return;
  $("#typing-line").textContent = `${payload.name || "Someone"} is typing…`;
  clearTimeout(state.typingTimer);
  state.typingTimer = setTimeout(() => { $("#typing-line").textContent = ""; }, 1800);
}
messageInput.addEventListener("input", () => {
  if (!state.channel || !messageInput.value.trim()) return;
  state.typingChannel?.send({ type: "broadcast", event: "typing", payload: { user_id: state.user.id, name: state.profile.display_name } });
});
$("#message-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const body = messageInput.value.trim();
  if (!body || !state.activeRoom) return;
  const button = $("#send-button"); button.disabled = true;
  const { error } = await supabase.from("chat_messages").insert({ room_id: state.activeRoom.id, sender_id: state.user.id, body });
  button.disabled = false;
  if (error) { toast(error.message); return; }
  messageInput.value = ""; messageInput.focus();
});
$("#emoji-button").addEventListener("click", () => {
  messageInput.value += " 🙂"; messageInput.focus(); messageInput.dispatchEvent(new Event("input"));
});
$("#new-room").addEventListener("click", async () => {
  const raw = window.prompt("Give your new room a name (letters, numbers and hyphens):");
  if (!raw) return;
  const slug = raw.trim().toLowerCase().replace(/[^a-z0-9-]+/g, "-").replace(/^-|-$/g, "").slice(0, 40);
  if (slug.length < 2) { toast("Room names need at least 2 characters."); return; }
  const { data, error } = await supabase.from("chat_rooms").insert({ slug, name: slug, description: "A new place to connect.", created_by: state.user.id }).select().single();
  if (error) { toast(error.code === "23505" ? "That room already exists." : error.message); return; }
  state.rooms.push(data); renderRooms(); await selectRoom(data.id);
});
$("#sign-out").addEventListener("click", async () => {
  if (state.channel) await supabase.removeChannel(state.channel);
  if (state.typingChannel) await supabase.removeChannel(state.typingChannel);
  if (state.presence) await supabase.removeChannel(state.presence);
  await supabase.auth.signOut(); state.user = null; state.profile = null; state.activeRoom = null; showApp(false);
});
$("#mobile-menu").addEventListener("click", () => $(".sidebar").classList.toggle("open"));

supabase.auth.onAuthStateChange((event) => {
  if (event === "SIGNED_OUT") {
    state.user = null;
    state.profile = null;
    showApp(false);
  }
});
const { data: { session } } = await supabase.auth.getSession();
if (session?.user) {
  try { await startApp(session.user); }
  catch (error) { console.error(error); toast(error.message || "Unable to start chat."); }
} else showApp(false);
