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

/* Interaction layer: persisted reactions, grouped messages, emoji and member cards. */
const reactionEmojis = ["👍","❤️","😂","🎉","🔥","👀","🙌","🤔"];
const pickerEmojis = ["😀","😄","😁","😂","🥹","😊","😍","🤔","😎","😭","🥳","🤯","👍","👎","👏","🙌","🙏","❤️","💚","🔥","✨","🎉","🚀","👀","💯","☕","💻","🧠","⚡","🌱","🎯","🫡"];
state.reactions = state.reactions || [];
state.reactionChannel = null;
state.pickerTarget = null;

function closePopovers() {
  $("#emoji-picker").hidden = true;
  $("#profile-popover").hidden = true;
  state.pickerTarget = null;
}
function reactionMarkup(messageId) {
  const rows = state.reactions.filter((item) => item.message_id === messageId);
  const counts = new Map();
  rows.forEach((item) => {
    const entry = counts.get(item.emoji) || { count: 0, mine: false };
    entry.count += 1;
    entry.mine = entry.mine || item.sender_key === state.senderKey;
    counts.set(item.emoji, entry);
  });
  return Array.from(counts.entries()).map(([emoji, item]) =>
    '<button class="reaction-chip ' + (item.mine ? "reacted" : "") + '" type="button" data-react="' + emoji + '" data-message="' + messageId + '" aria-pressed="' + item.mine + '"><span>' + emoji + '</span><span>' + item.count + '</span></button>'
  ).join("");
}
function renderMessages() {
  const container = $("#messages");
  if (!state.messages.length) {
    container.innerHTML = '<div class="empty-state"><div class="empty-illustration">✳</div><span class="empty-kicker">A FRESH START</span><h2>It’s quiet in here.</h2><p>Be the first to say hello and set the tone.</p></div>';
    return;
  }
  let lastDay = "", previous = null;
  container.innerHTML = state.messages.map((message) => {
    const date = new Date(message.created_at);
    const day = date.toDateString();
    const separator = day !== lastDay ? '<div class="day-divider"><span>' + escapeHtml(formatDay(message.created_at)) + '</span></div>' : "";
    lastDay = day;
    const mine = message.sender_key === state.senderKey;
    const name = message.sender_name || "Guest";
    const grouped = previous && previous.sender_key === message.sender_key &&
      (date - new Date(previous.created_at)) < 300000 && new Date(previous.created_at).toDateString() === day;
    previous = message;
    const avatar = '<button class="avatar message-avatar ' + (mine ? "self-avatar" : "") + '" type="button" data-profile="' + escapeHtml(name) + '" data-sender="' + message.sender_key + '" aria-label="View member profile">' + (grouped ? "" : escapeHtml(initials(name))) + '</button>';
    const meta = grouped ? "" : '<div class="message-meta"><button class="message-author" type="button" data-profile="' + escapeHtml(name) + '" data-sender="' + message.sender_key + '">' + escapeHtml(name) + '</button>' + (mine ? '<span class="you-tag">YOU</span>' : "") + '<time>' + formatTime(message.created_at) + '</time></div>';
    return separator + '<article class="message ' + (mine ? "mine" : "") + (grouped ? " grouped" : "") + '" data-message-card="' + message.id + '">' +
      avatar + '<div class="message-content">' + meta + '<p>' + escapeHtml(message.body).replace(/\n/g, "<br>") + '</p>' +
      '<div class="message-tools"><div class="reaction-list">' + reactionMarkup(message.id) + '</div><button class="add-reaction" type="button" data-add-reaction="' + message.id + '" aria-label="Add reaction" title="Add reaction">☺ <span>React</span></button></div></div></article>';
  }).join("");
  container.scrollTop = container.scrollHeight;
}
async function toggleReaction(messageId, emoji) {
  if (!reactionEmojis.includes(emoji)) return;
  const current = state.reactions.find((item) => item.message_id === messageId && item.sender_key === state.senderKey && item.emoji === emoji);
  if (current) {
    const result = await supabase.from("chat_guest_reactions").delete().eq("id", current.id).eq("sender_key", state.senderKey);
    if (result.error) throw result.error;
    state.reactions = state.reactions.filter((item) => item.id !== current.id);
  } else {
    const result = await supabase.from("chat_guest_reactions").insert({
      message_id: messageId, sender_key: state.senderKey, emoji: emoji
    }).select("id,message_id,sender_key,emoji").single();
    if (result.error && result.error.code !== "23505") throw result.error;
    if (result.data && !state.reactions.some((item) => item.id === result.data.id)) state.reactions.push(result.data);
  }
  renderMessages();
}
function openEmojiPicker(target, anchor) {
  const picker = $("#emoji-picker");
  $("#profile-popover").hidden = true;
  if (!picker.hidden && state.pickerTarget && state.pickerTarget.id === target.id && state.pickerTarget.kind === target.kind) {
    closePopovers(); return;
  }
  state.pickerTarget = target;
  picker.innerHTML = '<div class="emoji-picker-head"><strong>' + (target.kind === "reaction" ? "React to message" : "Add an emoji") + '</strong><button type="button" class="picker-close" aria-label="Close">×</button></div><div class="emoji-grid">' +
    (target.kind === "reaction" ? reactionEmojis : pickerEmojis).map((emoji) => '<button type="button" data-pick-emoji="' + emoji + '" aria-label="' + emoji + '">' + emoji + '</button>').join("") + '</div>';
  const rect = anchor.getBoundingClientRect();
  picker.style.left = Math.max(12, Math.min(rect.left, window.innerWidth - 270)) + "px";
  picker.style.top = Math.max(12, Math.min(rect.top - 245, window.innerHeight - 235)) + "px";
  picker.hidden = false;
}
function openProfile(name, senderKey, anchor) {
  const popover = $("#profile-popover");
  $("#emoji-picker").hidden = true;
  const isMe = senderKey === state.senderKey;
  const rect = anchor.getBoundingClientRect();
  const online = Array.from(state.online.values()).some((person) => person.guest_id === senderKey);
  popover.innerHTML = '<div class="profile-popover-top"><div class="avatar profile-pop-avatar">' + escapeHtml(initials(name)) + '</div><button type="button" class="picker-close" aria-label="Close">×</button></div><strong class="profile-pop-name">' + escapeHtml(name) + '</strong><span class="profile-pop-status"><i class="live-dot"></i>' + (online ? "Online in this room" : "Community member") + '</span><div class="profile-pop-divider"></div><span class="profile-pop-note">' + (isMe ? "This is how others see you in Commonroom." : "A fellow member of the Commonroom community.") + '</span>' + (isMe ? '<button class="profile-edit" type="button" id="popover-edit-name">Edit display name</button>' : "");
  popover.style.left = Math.max(12, Math.min(rect.left, window.innerWidth - 260)) + "px";
  popover.style.top = Math.max(12, Math.min(rect.bottom + 8, window.innerHeight - 220)) + "px";
  popover.hidden = false;
}
const originalSelectRoom = selectRoom;
selectRoom = async function(roomId) {
  if (state.reactionChannel) await supabase.removeChannel(state.reactionChannel);
  state.reactionChannel = null;
  state.reactions = [];
  await originalSelectRoom(roomId);
  const room = state.activeRoom;
  if (!room) return;
  const result = await supabase.from("chat_guest_reactions").select("id,message_id,sender_key,emoji").limit(1000);
  if (result.error) console.warn("Reactions unavailable:", result.error);
  else state.reactions = result.data || [];
  renderMessages();
  state.reactionChannel = supabase.channel("commonroom-reactions:" + room.id)
    .on("postgres_changes", { event: "*", schema: "public", table: "chat_guest_reactions" }, (payload) => {
      if (payload.eventType === "INSERT") {
        if (!state.reactions.some((item) => item.id === payload.new.id)) state.reactions.push(payload.new);
      } else if (payload.eventType === "DELETE") {
        state.reactions = state.reactions.filter((item) => item.id !== payload.old.id);
      }
      renderMessages();
    });
  state.reactionChannel.subscribe((status) => {
    if (status !== "SUBSCRIBED" && status !== "CHANNEL_ERROR") return;
  });
};
$("#messages").addEventListener("click", async (event) => {
  const chip = event.target.closest("[data-react]");
  if (chip) {
    try { await toggleReaction(chip.dataset.message, chip.dataset.react); }
    catch (error) { toast(error.message || "Could not update reaction."); }
    return;
  }
  const add = event.target.closest("[data-add-reaction]");
  if (add) { openEmojiPicker({ kind: "reaction", id: add.dataset.addReaction }, add); return; }
  const profile = event.target.closest("[data-profile]");
  if (profile) openProfile(profile.dataset.profile, profile.dataset.sender, profile);
});
$("#emoji-picker").addEventListener("click", async (event) => {
  if (event.target.closest(".picker-close")) { closePopovers(); return; }
  const button = event.target.closest("[data-pick-emoji]");
  if (!button || !state.pickerTarget) return;
  const target = state.pickerTarget, emoji = button.dataset.pickEmoji;
  if (target.kind === "reaction") {
    try { await toggleReaction(target.id, emoji); }
    catch (error) { toast(error.message || "Could not add reaction."); }
  } else {
    const input = $("#message-input");
    input.setRangeText(emoji, input.selectionStart, input.selectionEnd, "end");
    input.focus(); input.dispatchEvent(new Event("input"));
  }
  closePopovers();
});
$("#profile-popover").addEventListener("click", (event) => {
  if (event.target.closest(".picker-close")) closePopovers();
  if (event.target.closest("#popover-edit-name")) {
    closePopovers();
    const next = window.prompt("Change your display name:", state.name);
    if (next !== null) {
      try {
        const clean = next.trim().replace(/\s+/g, " ").slice(0, 32);
        if (clean.length < 2) throw new Error("Your display name needs at least 2 characters.");
        setName(clean); toast("Display name updated.");
      } catch (error) { toast(error.message); }
    }
  }
});
document.addEventListener("click", (event) => {
  if (!event.target.closest("#emoji-picker,#profile-popover,#emoji-button,[data-add-reaction]")) closePopovers();
});
$("#emoji-button").addEventListener("click", (event) => {
  event.stopPropagation();
  openEmojiPicker({ kind: "composer", id: "composer" }, event.currentTarget);
});
window.addEventListener("resize", closePopovers);

if (state.activeRoom) selectRoom(state.activeRoom.id).catch((error) => toast(error.message || "Could not load reactions."));
