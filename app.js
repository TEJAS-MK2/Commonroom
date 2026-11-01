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
  typingChannel: null, presence: null, typingTimer: null, typingTimers: new Map(), typers: new Map(),
  lastTypingSentAt: 0, roomsChannel: null, reactionChannel: null, online: new Map(), roomSwitchToken: 0,
  reactions: [], replyTarget: null,
  editTokens: (() => { try { return JSON.parse(storage.get("commonroom-edit-tokens", "{}")) || {}; } catch { return {}; } })(),
};
if (!state.senderKey) {
  state.senderKey = crypto.randomUUID();
  storage.set("commonroom-guest-id", state.senderKey);
}
function escapeHtml(value = "") {
  return String(value).replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
}
function initials(name = "Guest") {
  const words = String(name ?? "Guest").trim().split(/\s+/).filter(Boolean).slice(0, 2);
  return words.map((part) => Array.from(part)[0] || "").join("").toUpperCase() || "G";
}
function setConnectionStatus(label, stateName = "live") {
  const node = $("#connection-status");
  if (!node) return;
  node.innerHTML = '<i class="live-dot"></i>' + escapeHtml(label);
  node.dataset.state = stateName;
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
  const clean = Array.from(String(name ?? "").trim().replace(/\s+/g, " ")).slice(0, 32).join("");
  if (clean.length < 2) throw new Error("Your display name needs at least 2 characters.");
  state.name = clean;
  storage.set("commonroom-name", clean);
  $("#my-name").textContent = clean;
  $("#my-avatar").textContent = initials(clean);
}
function askForName() {
  if (state.name && state.name.trim().length >= 2) {
    setName(state.name);
    return;
  }
  const name = window.prompt("Choose a display name (2–32 characters):", "Guest");
  if (name === null || !name.trim()) {
    setName("Guest");
    return;
  }
  try { setName(name); }
  catch (error) {
    toast(error.message);
    setName("Guest");
  }
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

  const switchToken = ++state.roomSwitchToken;
  const previousChannels = [state.messageChannel, state.typingChannel, state.presence, state.reactionChannel];
  state.messageChannel = null;
  state.typingChannel = null;
  state.presence = null;
  state.reactionChannel = null;
  state.online.clear();
  state.typers.clear();
  for (const timer of state.typingTimers.values()) clearTimeout(timer);
  state.typingTimers.clear();
  clearTimeout(state.typingTimer);
  state.typingTimer = null;
  updateOnline();
  await Promise.allSettled(previousChannels.filter(Boolean).map((channel) => supabase.removeChannel(channel)));
  if (switchToken !== state.roomSwitchToken) return;

  state.activeRoom = room;
  state.messages = [];
  state.reactions = [];
  clearReplyTarget();
  closePopovers();
  setConnectionStatus("Connecting", "pending");
  $("#active-room-name").textContent = room.name;
  $("#room-description").textContent = room.description || "A place to talk.";
  $("#message-input").placeholder = `Write to #${room.name}…`;
  $("#typing-line").textContent = "";
  renderRooms();
  $("#messages").innerHTML = '<div class="loading-state">Loading the conversation…</div>';

  const messageChannel = supabase.channel(`commonroom-messages:${room.id}`);
  state.messageChannel = messageChannel;
  messageChannel
    .on("postgres_changes", {
      event: "INSERT", schema: "public", table: "chat_guest_messages", filter: `room_id=eq.${room.id}`
    }, ({ new: message }) => {
      if (switchToken !== state.roomSwitchToken || state.activeRoom?.id !== room.id || !message?.id) return;
      if (!state.messages.some((item) => item.id === message.id)) {
        state.messages.push(message);
        state.messages.sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
        renderMessages();
      }
    })
    .on("postgres_changes", {
      event: "UPDATE", schema: "public", table: "chat_guest_messages", filter: `room_id=eq.${room.id}`
    }, ({ new: message }) => {
      if (switchToken !== state.roomSwitchToken || state.activeRoom?.id !== room.id || !message?.id) return;
      state.messages = state.messages.map((item) => item.id === message.id ? { ...item, ...message } : item);
      renderMessages();
    })
    .on("postgres_changes", {
      event: "DELETE", schema: "public", table: "chat_guest_messages"
    }, ({ old }) => {
      if (switchToken !== state.roomSwitchToken || state.activeRoom?.id !== room.id || !old?.id) return;
      const exists = state.messages.some((item) => item.id === old.id);
      if (!exists) return;
      state.messages = state.messages.filter((item) => item.id !== old.id);
      pruneMessageTokens(old.id);
      state.reactions = state.reactions.filter((item) => item.message_id !== old.id);
      renderMessages();
    });

  const messagesReady = await waitForSubscription(messageChannel);
  if (switchToken !== state.roomSwitchToken) {
    await supabase.removeChannel(messageChannel);
    return;
  }
  setConnectionStatus(messagesReady ? "Live" : "Reconnecting", messagesReady ? "live" : "warning");
  if (!messagesReady) toast("Live updates are taking longer than expected.");

  const typingChannel = supabase.channel(`commonroom-typing:${room.id}`);
  state.typingChannel = typingChannel;
  typingChannel.on("broadcast", { event: "typing" }, ({ payload }) => {
    if (switchToken === state.roomSwitchToken && state.activeRoom?.id === room.id) showTyping(payload);
  });
  const typingReady = await waitForSubscription(typingChannel);
  if (switchToken !== state.roomSwitchToken) {
    await supabase.removeChannel(typingChannel);
    return;
  }
  if (!typingReady) console.warn("Typing channel unavailable.");

  try {
    await loadMessages(room.id);
  } catch (error) {
    if (switchToken !== state.roomSwitchToken) return;
    $("#messages").innerHTML = '<div class="empty-state"><div class="empty-illustration">!</div><h2>Conversation unavailable</h2><p>We could not load this room. Check your connection and try another channel.</p></div>';
    setConnectionStatus("Connection issue", "warning");
    throw error;
  }
  if (switchToken !== state.roomSwitchToken) return;

  const messageIds = state.messages.map((message) => message.id);
  const reactionResult = messageIds.length
    ? await supabase.from("chat_guest_reactions").select("id,message_id,sender_key,emoji").in("message_id", messageIds)
    : { data: [], error: null };
  if (switchToken !== state.roomSwitchToken) return;
  if (reactionResult.error) console.warn("Reactions unavailable:", reactionResult.error);
  else state.reactions = reactionResult.data || [];
  renderMessages();

  const reactionChannel = supabase.channel("commonroom-reactions:" + room.id);
  state.reactionChannel = reactionChannel;
  reactionChannel.on("postgres_changes", {
    event: "*", schema: "public", table: "chat_guest_reactions"
  }, (payload) => {
    if (switchToken !== state.roomSwitchToken || state.activeRoom?.id !== room.id) return;
    const visibleIds = new Set(state.messages.map((message) => message.id));
    let changed = false;
    if (payload.eventType === "INSERT" && visibleIds.has(payload.new?.message_id)) {
      if (!state.reactions.some((item) => item.id === payload.new.id)) {
        state.reactions.push(payload.new);
        changed = true;
      }
    } else if (payload.eventType === "DELETE" && payload.old?.id) {
      const previous = state.reactions.find((item) => item.id === payload.old.id);
      if (previous && visibleIds.has(previous.message_id)) {
        state.reactions = state.reactions.filter((item) => item.id !== payload.old.id);
        changed = true;
      }
    }
    if (changed) renderMessages();
  });
  reactionChannel.subscribe((status) => {
    if (switchToken !== state.roomSwitchToken) return;
    if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") console.warn("Reaction updates are temporarily unavailable.");
  });
  if (switchToken !== state.roomSwitchToken) return;
  await connectPresence(room.id, switchToken);
  if (switchToken !== state.roomSwitchToken) return;
  setSidebarOpen(false);
}
async function loadMessages(roomId) {
  const { data, error } = await supabase.from("chat_guest_messages")
    .select("id,room_id,sender_key,sender_name,body,created_at,reply_to,edited_at")
    .eq("room_id", roomId).order("created_at", { ascending: false }).limit(100);
  if (error) throw error;
  if (state.activeRoom?.id !== roomId) return;
  const existing = new Map((data || []).map((message) => [message.id, message]));
  for (const message of state.messages) existing.set(message.id, message);
  state.messages = [...existing.values()].sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
  renderMessages();
}
async function connectPresence(roomId, switchToken) {
  if (state.presence) await supabase.removeChannel(state.presence);
  if (switchToken !== state.roomSwitchToken) return;
  state.online.clear();
  const presenceChannel = supabase.channel(`commonroom-presence:${roomId}`, { config: { presence: { key: state.senderKey } } });
  state.presence = presenceChannel;
  presenceChannel.on("presence", { event: "sync" }, updateOnline);
  presenceChannel.on("presence", { event: "join" }, updateOnline);
  presenceChannel.on("presence", { event: "leave" }, updateOnline);
  presenceChannel.subscribe(async (status) => {
    if (status === "SUBSCRIBED" && state.presence === presenceChannel && switchToken === state.roomSwitchToken) {
      await presenceChannel.track({ guest_id: state.senderKey, name: state.name, online_at: new Date().toISOString() });
    }
  });
}
function updateOnline() {
  const presenceState = state.presence?.presenceState() || {};
  const people = Object.values(presenceState).flat();
  const valid = people.filter((person) => person && typeof person === "object" &&
    typeof person.guest_id === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(person.guest_id));
  const unique = [...new Map(valid.map((person) => [person.guest_id, {
    guest_id: person.guest_id,
    name: typeof person.name === "string" ? Array.from(person.name.trim()).slice(0, 32).join("") || "Guest" : "Guest"
  }])).values()].slice(0, 100);
  state.online = new Map(unique.map((person) => [person.guest_id, person]));
  $("#online-count").textContent = `${unique.length} online`;
  $("#online-stack").innerHTML = unique.slice(0, 4).map((person) =>
    `<span class="online-avatar" title="${escapeHtml(person.name)}">${escapeHtml(initials(person.name))}</span>`).join("");
}
function renderTypers() {
  const names = [...state.typers.values()].map((person) => person.name).filter(Boolean);
  $("#typing-line").textContent = names.length === 0 ? "" :
    names.length === 1 ? `${names[0]} is typing…` :
    names.length === 2 ? `${names[0]} and ${names[1]} are typing…` :
    `${names.length} people are typing…`;
}
function showTyping(payload) {
  if (!payload || payload.guest_id === state.senderKey || typeof payload.guest_id !== "string" ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(payload.guest_id)) return;
  const name = typeof payload.name === "string" ? Array.from(payload.name.trim()).slice(0, 32).join("") || "Someone" : "Someone";
  state.typers.set(payload.guest_id, { name });
  const existing = state.typingTimers.get(payload.guest_id);
  if (existing) clearTimeout(existing);
  const timer = setTimeout(() => {
    state.typers.delete(payload.guest_id);
    state.typingTimers.delete(payload.guest_id);
    renderTypers();
  }, 1800);
  state.typingTimers.set(payload.guest_id, timer);
  renderTypers();
}
$("#message-input").addEventListener("input", () => {
  const input = $("#message-input");
  if (!state.typingChannel || !input.value.trim()) return;
  const now = Date.now();
  if (now - state.lastTypingSentAt < 1000) return;
  state.lastTypingSentAt = now;
  state.typingChannel.send({ type: "broadcast", event: "typing", payload: { guest_id: state.senderKey, name: state.name } });
});
$("#message-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const input = $("#message-input");
  const body = input.value.trim();
  if (!body || !state.activeRoom) return;
  const button = $("#send-button"); button.disabled = true;
  try {
    const token = createEditToken();
    const { data, error } = await supabase.rpc("create_guest_message", {
      p_room_id: state.activeRoom.id,
      p_sender_key: state.senderKey,
      p_sender_name: state.name,
      p_body: body,
      p_reply_to: state.replyTarget?.id || null,
      p_token_hash: await hashEditToken(token)
    });
    if (error) throw error;
    const messageId = typeof data === "string" ? data : data?.id;
    if (messageId) {
      state.editTokens[messageId] = token;
      storage.set("commonroom-edit-tokens", JSON.stringify(state.editTokens));
    }
    input.value = ""; clearReplyTarget(); input.focus();
  } catch (error) {
    toast(error.message || "Your message could not be sent.");
  } finally { button.disabled = false; }
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
function setSidebarOpen(open) {
  const sidebar = $("#sidebar");
  const menu = $("#mobile-menu");
  const backdrop = $("#sidebar-backdrop");
  sidebar.classList.toggle("open", open);
  menu.setAttribute("aria-expanded", String(open));
  backdrop.hidden = !open;
}
$("#mobile-menu").addEventListener("click", () => setSidebarOpen(!$("#sidebar").classList.contains("open")));
$("#sidebar-backdrop").addEventListener("click", () => setSidebarOpen(false));
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    closePopovers();
    setSidebarOpen(false);
  }
});
window.addEventListener("pagehide", () => {
  for (const channel of [state.messageChannel, state.typingChannel, state.presence, state.reactionChannel, state.roomsChannel]) {
    if (channel) supabase.removeChannel(channel);
  }
});
askForName();
$("#my-name").textContent = state.name;
$("#my-avatar").textContent = initials(state.name);


/* Interaction layer: persisted reactions, grouped messages, emoji and member cards. */
const reactionEmojis = ["👍","❤️","😂","🎉","🔥","👀","🙌","🤔"];
const pickerEmojis = ["😀","😄","😁","😂","🥹","😊","😍","🤔","😎","😭","🥳","🤯","👍","👎","👏","🙌","🙏","❤️","💚","🔥","✨","🎉","🚀","👀","💯","☕","💻","🧠","⚡","🌱","🎯","🫡"];
state.reactions = state.reactions || [];
try { state.reactionTokens = JSON.parse(storage.get("commonroom-reaction-tokens", "{}")) || {}; }
catch { state.reactionTokens = {}; }
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
async function toggleReaction(messageId, emoji) {
  if (!reactionEmojis.includes(emoji)) return;
  const current = state.reactions.find((item) => item.message_id === messageId && item.sender_key === state.senderKey && item.emoji === emoji);
  const tokenKey = messageId + ":" + emoji;
  if (current) {
    const token = state.reactionTokens[tokenKey];
    if (!token) {
      toast("This older reaction has no saved removal token on this device.");
      return;
    }
    const { data, error } = await supabase.rpc("delete_guest_reaction", { p_reaction_id: current.id, p_token: token });
    if (error || data !== true) throw error || new Error("This reaction can no longer be removed from this device.");
    delete state.reactionTokens[tokenKey];
    storage.set("commonroom-reaction-tokens", JSON.stringify(state.reactionTokens));
    state.reactions = state.reactions.filter((item) => item.id !== current.id);
  } else {
    const token = createEditToken();
    const result = await supabase.rpc("create_guest_reaction", {
      p_message_id: messageId,
      p_sender_key: state.senderKey,
      p_emoji: emoji,
      p_token_hash: await hashEditToken(token)
    });
    const created = typeof result.data === "string"
      ? { id: result.data, message_id: messageId, sender_key: state.senderKey, emoji }
      : result.data;
    if (result.error?.code === "23505") {
      toast("That reaction already exists for this device key. Refresh the room before trying again.");
      return;
    }
    if (result.error) throw result.error;
    if (created) {
      state.reactionTokens[tokenKey] = token;
      storage.set("commonroom-reaction-tokens", JSON.stringify(state.reactionTokens));
      if (!state.reactions.some((item) => item.id === created.id)) state.reactions.push(created);
    }
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
        setName(clean);
        state.presence?.track({ guest_id: state.senderKey, name: state.name, online_at: new Date().toISOString() });
        toast("Display name updated.");
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
/* Layout follows the live viewport rather than a user-agent guess. */
const mobileLayoutQuery = window.matchMedia("(max-width: 700px)");
const tabletLayoutQuery = window.matchMedia("(min-width: 701px) and (max-width: 1100px)");
function syncResponsiveLayout() {
  document.documentElement.dataset.layout = mobileLayoutQuery.matches ? "mobile" : tabletLayoutQuery.matches ? "tablet" : "desktop";
}
mobileLayoutQuery.addEventListener("change", syncResponsiveLayout);
tabletLayoutQuery.addEventListener("change", syncResponsiveLayout);
syncResponsiveLayout();

/* Threads and owner-token message editing/deletion. */
state.replyTarget = null;
try { state.editTokens = JSON.parse(storage.get("commonroom-edit-tokens", "{}")) || {}; } catch { state.editTokens = {}; }
function createEditToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
async function hashEditToken(token) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}
function pruneMessageTokens(messageId) {
  if (Object.prototype.hasOwnProperty.call(state.editTokens, messageId)) {
    delete state.editTokens[messageId];
    storage.set("commonroom-edit-tokens", JSON.stringify(state.editTokens));
  }
  const prefix = messageId + ":";
  let changed = false;
  for (const key of Object.keys(state.reactionTokens || {})) {
    if (key.startsWith(prefix)) { delete state.reactionTokens[key]; changed = true; }
  }
  if (changed) storage.set("commonroom-reaction-tokens", JSON.stringify(state.reactionTokens));
}
function clearReplyTarget() {
  state.replyTarget = null;
  $("#reply-context").hidden = true;
  $("#reply-context").innerHTML = "";
}
function setReplyTarget(message) {
  state.replyTarget = message;
  $("#reply-context").innerHTML = '<span>Replying to <strong>' + escapeHtml(message.sender_name) + '</strong><small>' + escapeHtml(message.body.slice(0, 110)) + '</small></span><button type="button" id="cancel-reply" aria-label="Cancel reply">×</button>';
  $("#reply-context").hidden = false;
  $("#message-input").focus();
}
function renderMessages() {
  const container = $("#messages");
  const stickToBottom = container.scrollHeight - container.scrollTop - container.clientHeight < 140;
  if (!state.messages.length) {
    container.innerHTML = '<div class="empty-state"><div class="empty-illustration">✳</div><span class="empty-kicker">A FRESH START</span><h2>It’s quiet in here.</h2><p>Be the first to say hello and set the tone.</p></div>';
    return;
  }
  let lastDay = "", previous = null;
  container.innerHTML = state.messages.map((message) => {
    const date = new Date(message.created_at), day = date.toDateString();
    const separator = day !== lastDay ? '<div class="day-divider"><span>' + escapeHtml(formatDay(message.created_at)) + '</span></div>' : "";
    lastDay = day;
    const mine = message.sender_key === state.senderKey, name = message.sender_name || "Guest";
    const grouped = previous && previous.sender_key === message.sender_key && (date - new Date(previous.created_at)) < 300000 && new Date(previous.created_at).toDateString() === day;
    previous = message;
    const parent = message.reply_to ? state.messages.find((item) => item.id === message.reply_to) : null;
    const replies = state.messages.filter((item) => item.reply_to === message.id).length;
    const canManage = mine && !!state.editTokens[message.id];
    const meta = grouped ? "" : '<div class="message-meta"><button class="message-author" type="button" data-profile="' + escapeHtml(name) + '" data-sender="' + message.sender_key + '">' + escapeHtml(name) + '</button>' + (mine ? '<span class="you-tag">YOU</span>' : '') + '<time>' + formatTime(message.created_at) + '</time>' + (message.edited_at ? '<span class="edited-tag">edited</span>' : '') + '</div>';
    const actions = '<div class="message-actions"><button type="button" data-reply="' + message.id + '">↩ Reply' + (replies ? ' · ' + replies : '') + '</button><button type="button" data-add-reaction="' + message.id + '">☺ React</button>' +
      (!mine ? '<button type="button" data-report="' + message.id + '">⚑ Report</button>' : '') +
      (canManage ? '<button type="button" data-edit="' + message.id + '">Edit</button><button type="button" data-delete="' + message.id + '">Delete</button>' : '') + '</div>';
    return separator + '<article class="message ' + (mine ? 'mine ' : '') + (grouped ? 'grouped' : '') + '" id="message-' + message.id + '" data-message-card="' + message.id + '">' +
      '<button class="avatar message-avatar ' + (mine ? 'self-avatar' : '') + '" type="button" data-profile="' + escapeHtml(name) + '" data-sender="' + message.sender_key + '">' + (grouped ? '' : escapeHtml(initials(name))) + '</button>' +
      '<div class="message-content">' + meta + (parent ? '<button class="reply-quote" type="button" data-jump="' + parent.id + '"><b>↪ ' + escapeHtml(parent.sender_name) + '</b><span>' + escapeHtml(parent.body.slice(0, 90)) + '</span></button>' : '') +
      '<p>' + escapeHtml(message.body).replace(/\n/g, '<br>') + '</p><div class="message-tools"><div class="reaction-list">' + reactionMarkup(message.id) + '</div><button class="add-reaction" type="button" data-add-reaction="' + message.id + '">☺ <span>React</span></button></div>' + actions + '</div></article>';
  }).join("");
  if (stickToBottom) container.scrollTop = container.scrollHeight;
}
$("#messages").addEventListener("click", async (event) => {
  const reply = event.target.closest("[data-reply]");
  if (reply) {
    const message = state.messages.find((item) => item.id === reply.dataset.reply);
    if (message) setReplyTarget(message);
    return;
  }
  const jump = event.target.closest("[data-jump]");
  if (jump) { $("#message-" + jump.dataset.jump)?.scrollIntoView({ behavior: "smooth", block: "center" }); return; }
  const edit = event.target.closest("[data-edit]");
  if (edit) {
    const message = state.messages.find((item) => item.id === edit.dataset.edit);
    const next = window.prompt("Edit your message:", message?.body || "");
    if (next === null || !next.trim()) return;
    if (next.trim().length > 2000) { toast("Messages must be 2,000 characters or fewer."); return; }
    const { data, error } = await supabase.rpc("edit_guest_message", { p_message_id: edit.dataset.edit, p_token: state.editTokens[edit.dataset.edit], p_body: next.trim() });
    if (error || data !== true) toast(error?.message || "The message was not updated. It may have been removed or your edit token is unavailable.");
    else {
      state.messages = state.messages.map((item) => item.id === edit.dataset.edit ? { ...item, body: next.trim(), edited_at: new Date().toISOString() } : item);
      renderMessages(); toast("Message updated.");
    }
    return;
  }
  const del = event.target.closest("[data-delete]");
  if (del) {
    if (!window.confirm("Delete this message? This cannot be undone.")) return;
    const id = del.dataset.delete;
    const { data, error } = await supabase.rpc("delete_guest_message", { p_message_id: id, p_token: state.editTokens[id] });
    if (error || data !== true) toast(error?.message || "This message cannot be deleted on this device.");
    else {
      delete state.editTokens[id]; storage.set("commonroom-edit-tokens", JSON.stringify(state.editTokens));
      state.messages = state.messages.filter((item) => item.id !== id); renderMessages(); toast("Message deleted.");
    }
    return;
  }

});

$("#reply-context").addEventListener("click", (event) => { if (event.target.closest("#cancel-reply")) clearReplyTarget(); });




/* Admin Control Room — all privileged reads/writes go through session-checked RPCs. */
const adminUi = { token: null, data: null, tab: "overview", search: "" };
const adminSections = {
  overview: ["Command overview", "A live snapshot of your community."],
  messages: ["Message moderation", "Review recent conversation activity and remove harmful content."],
  reports: ["Report queue", "Investigate community reports and record moderation outcomes."],
  rooms: ["Room management", "Manage public spaces and keep the community organised."],
  audit: ["Admin activity", "A traceable record of control-room actions."]
};
function adminEscape(value) { return escapeHtml(value == null ? "" : String(value)); }
function adminDate(value) {
  if (!value) return "—";
  return new Intl.DateTimeFormat(undefined,{dateStyle:"medium",timeStyle:"short"}).format(new Date(value));
}
function adminSetView(unlocked) {
  $("#admin-login-view").hidden = unlocked;
  $("#admin-dashboard").hidden = !unlocked;
  if (!unlocked) setTimeout(() => $("#admin-pin").focus(), 50);
}
function adminOpen() {
  $("#admin-overlay").hidden = false;
  document.body.classList.add("admin-open");
  adminSetView(!!adminUi.token);
  if (adminUi.token) adminLoad();
}
async function adminClose() {
  if (adminUi.token) {
    const token = adminUi.token;
    adminUi.token = null; adminUi.data = null;
    try { await supabase.rpc("admin_logout",{p_token:token}); } catch { /* Session expires server-side even if logout cannot reach the API. */ }
  }
  $("#admin-overlay").hidden = true;
  document.body.classList.remove("admin-open");
  $("#admin-pin").value = "";
  $("#admin-login-error").textContent = "";
}
function adminSetTab(tab) {
  if (!adminSections[tab]) return;
  adminUi.tab = tab;
  document.querySelectorAll("[data-admin-tab]").forEach((button)=>button.classList.toggle("active",button.dataset.adminTab===tab));
  $("#admin-page-title").textContent = adminSections[tab][0];
  $("#admin-page-subtitle").textContent = adminSections[tab][1];
  $("#admin-current-section").textContent = tab.toUpperCase();
  adminRender();
}
async function adminLoad() {
  if (!adminUi.token) return;
  $("#admin-content").innerHTML = '<div class="admin-loading"><span></span> Syncing live community data…</div>';
  const {data,error}=await supabase.rpc("admin_overview",{p_token:adminUi.token});
  if (error) {
    if (error.message?.toLowerCase().includes("session expired") || error.code==="28000") {
      adminUi.token=null; adminUi.data=null; adminSetView(false);
      $("#admin-login-error").textContent="Your admin session expired. Sign in again.";
      return;
    }
    $("#admin-content").innerHTML='<div class="admin-empty-state">Could not load the control room: '+adminEscape(error.message)+'</div>';
    return;
  }
  adminUi.data=data;
  $("#admin-report-count").textContent=String(data.stats?.open_reports||0);
  adminRender();
}
function adminRender() {
  const d=adminUi.data;
  if (!d) return;
  const messages=d.messages||[], reports=d.reports||[], rooms=d.rooms||[], audit=d.audit||[];
  const term=adminUi.search.trim().toLowerCase();
  const metric=(label,value,sub,icon)=>'<article class="admin-metric"><div class="admin-metric-top"><span>'+label+'</span><i>'+icon+'</i></div><strong>'+Number(value||0).toLocaleString()+'</strong><small>'+sub+'</small></article>';
  if(adminUi.tab==="overview") {
    $("#admin-content").innerHTML='<div class="admin-metrics">'+
      metric("Total messages",d.stats.messages,"Across all public rooms","▤")+
      metric("Messages today",d.stats.messages_today,"Since local database day start","↗")+
      metric("Public rooms",d.stats.rooms,"Community spaces","▦")+
      metric("Open reports",d.stats.open_reports,"Awaiting moderation","⚑")+
      '</div><div class="admin-two-column"><section class="admin-panel"><div class="admin-panel-head"><div><span class="admin-eyebrow">COMMUNITY PULSE</span><h3>Recent messages</h3></div><button data-admin-tab="messages" class="admin-text-button">View all ↗</button></div>'+
      (messages.slice(0,6).map(m=>'<article class="admin-activity-row"><div class="admin-activity-avatar">'+adminEscape(initials(m.sender_name))+'</div><div class="admin-activity-copy"><b>'+adminEscape(m.sender_name)+' <span>in #'+adminEscape(m.room_name)+'</span></b><p>'+adminEscape(m.body)+'</p></div><time>'+adminEscape(adminDate(m.created_at))+'</time></article>').join("")||'<div class="admin-empty-state">No messages yet.</div>')+
      '</section><section class="admin-panel"><div class="admin-panel-head"><div><span class="admin-eyebrow">NEEDS ATTENTION</span><h3>Moderation queue</h3></div><button data-admin-tab="reports" class="admin-text-button">Open queue ↗</button></div>'+
      (reports.slice(0,5).map(r=>'<article class="admin-report-mini"><span class="admin-report-mark">⚑</span><div><b>'+adminEscape(r.reason)+'</b><p>'+adminEscape(r.sender_name||"Deleted message")+' · '+adminEscape(r.room_name||"Unknown room")+'</p></div></article>').join("")||'<div class="admin-empty-state">All clear. No open reports.</div>')+
      '</section></div><section class="admin-panel admin-wide-panel"><div class="admin-panel-head"><div><span class="admin-eyebrow">ROOM DIRECTORY</span><h3>Community spaces</h3></div><button data-admin-tab="rooms" class="admin-text-button">Manage rooms ↗</button></div><div class="admin-room-chips">'+rooms.map(r=>'<span># '+adminEscape(r.name)+'</span>').join("")+'</div></section>';
  } else if(adminUi.tab==="messages") {
    const rows=messages.filter(m=>!term||[m.sender_name,m.room_name,m.body].join(" ").toLowerCase().includes(term));
    $("#admin-content").innerHTML='<div class="admin-panel"><div class="admin-panel-head"><div><span class="admin-eyebrow">CONTENT MODERATION</span><h3>Recent public messages</h3></div><label class="admin-search"><span>⌕</span><input id="admin-search" value="'+adminEscape(adminUi.search)+'" placeholder="Search messages…" /></label></div>'+
      (rows.map(m=>'<article class="admin-message-row"><div class="admin-message-meta"><b>'+adminEscape(m.sender_name)+'</b><span># '+adminEscape(m.room_name)+'</span><time>'+adminEscape(adminDate(m.created_at))+'</time></div><p>'+adminEscape(m.body)+'</p><button class="admin-danger-button" data-admin-delete-message="'+m.id+'">Delete message</button></article>').join("")||'<div class="admin-empty-state">No matching messages.</div>')+'</div>';
  } else if(adminUi.tab==="reports") {
    $("#admin-content").innerHTML='<div class="admin-panel"><div class="admin-panel-head"><div><span class="admin-eyebrow">COMMUNITY SAFETY</span><h3>Open reports <span class="admin-inline-count">'+reports.length+'</span></h3></div></div>'+
      (reports.map(r=>'<article class="admin-report-row"><div class="admin-report-head"><span class="admin-report-tag">'+adminEscape(r.reason)+'</span><time>'+adminEscape(adminDate(r.created_at))+'</time></div><div class="admin-report-context"><b>'+adminEscape(r.sender_name||"Message unavailable")+' · #'+adminEscape(r.room_name||"unknown")+'</b><p>'+adminEscape(r.body||"The reported message is no longer available.")+'</p>'+(r.details?'<small>Reporter note: '+adminEscape(r.details)+'</small>':'')+'</div><div class="admin-row-actions"><button class="admin-secondary-button" data-admin-resolve="'+r.id+'" data-status="dismissed">Dismiss</button><button class="admin-primary-button compact" data-admin-resolve="'+r.id+'" data-status="reviewed">Mark reviewed</button>'+(r.message_id?'<button class="admin-danger-button" data-admin-delete-message="'+r.message_id+'">Remove message</button>':'')+'</div></article>').join("")||'<div class="admin-empty-state">Nothing in the queue. Nice work keeping things civil.</div>')+'</div>';
  } else if(adminUi.tab==="rooms") {
    $("#admin-content").innerHTML='<div class="admin-room-grid">'+rooms.map(r=>'<article class="admin-room-card"><div class="admin-room-card-top"><span class="admin-room-icon">#</span><span class="admin-room-slug">'+adminEscape(r.slug)+'</span></div><h3>'+adminEscape(r.name)+'</h3><p>'+adminEscape(r.description||"No description yet.")+'</p><small>Created '+adminEscape(adminDate(r.created_at))+'</small><div class="admin-row-actions"><button class="admin-secondary-button" data-admin-edit-room="'+r.id+'" data-name="'+adminEscape(r.name)+'" data-description="'+adminEscape(r.description||"")+'">Edit details</button>'+(r.slug==="general"?'':'<button class="admin-danger-button" data-admin-delete-room="'+r.id+'">Delete</button>')+'</div></article>').join("")+'</div>';
  } else {
    $("#admin-content").innerHTML='<div class="admin-panel"><div class="admin-panel-head"><div><span class="admin-eyebrow">SECURITY & ACCOUNTABILITY</span><h3>Recent admin actions</h3></div></div>'+
      (audit.map(a=>'<article class="admin-audit-row"><span class="admin-audit-dot"></span><div><b>'+adminEscape(a.action.replace(/_/g," "))+'</b><small>'+adminEscape(a.target_id||"Control room session")+'</small></div><time>'+adminEscape(adminDate(a.created_at))+'</time></article>').join("")||'<div class="admin-empty-state">No admin actions recorded yet.</div>')+'</div>';
  }
  const search=$("#admin-search");
  if(search) search.addEventListener("input",()=>{adminUi.search=search.value;const pos=search.selectionStart;adminRender();const next=$("#admin-search");next?.focus();next?.setSelectionRange(pos,pos);});
}
async function adminAction(name,args,successMessage) {
  const {data,error}=await supabase.rpc(name,{p_token:adminUi.token,...args});
  if(error) {
    if(error.code==="28000" || error.message?.toLowerCase().includes("session expired")) {
      adminUi.token=null; adminUi.data=null; adminSetView(false);
      $("#admin-login-error").textContent="Your admin session expired. Sign in again.";
    }
    toast(error.message||"Admin action failed."); return false;
  }
  if(data!==true) { toast("The requested change was not applied."); return false; }
  toast(successMessage); await adminLoad(); return true;
}
function connectRoomsRealtime() {
  if (state.roomsChannel) supabase.removeChannel(state.roomsChannel);
  state.roomsChannel = supabase.channel("commonroom-room-directory")
    .on("postgres_changes", { event: "INSERT", schema: "public", table: "chat_rooms" }, ({ new: room }) => {
      if (!room?.id || state.rooms.some((item) => item.id === room.id)) return;
      state.rooms.push({ id: room.id, slug: room.slug, name: room.name, description: room.description });
      state.rooms.sort((a, b) => a.name.localeCompare(b.name));
      renderRooms();
    })
    .on("postgres_changes", { event: "UPDATE", schema: "public", table: "chat_rooms" }, ({ new: room }) => {
      if (!room?.id) return;
      state.rooms = state.rooms.map((item) => item.id === room.id ? { ...item, ...room } : item);
      if (state.activeRoom?.id === room.id) {
        state.activeRoom = { ...state.activeRoom, ...room };
        $("#active-room-name").textContent = room.name;
        $("#room-description").textContent = room.description || "A place to talk.";
      }
      renderRooms();
    })
    .on("postgres_changes", { event: "DELETE", schema: "public", table: "chat_rooms" }, async ({ old }) => {
      if (!old?.id) return;
      const removedActiveRoom = state.activeRoom?.id === old.id;
      state.rooms = state.rooms.filter((item) => item.id !== old.id);
      if (removedActiveRoom) {
        const fallback = state.rooms.find((item) => item.slug === "general") || state.rooms[0];
        if (fallback) await selectRoom(fallback.id);
      } else renderRooms();
    });
  state.roomsChannel.subscribe();
}

$("#admin-open").addEventListener("click",adminOpen);
$("#admin-close").addEventListener("click",adminClose);
$("#admin-overlay").addEventListener("click",(event)=>{if(event.target===$("#admin-overlay"))adminClose();});
$("#admin-login-form").addEventListener("submit",async(event)=>{
  event.preventDefault();
  const button=event.currentTarget.querySelector("button[type=submit]");
  const pin=$("#admin-pin").value;
  $("#admin-login-error").textContent="";
  button.disabled=true;button.classList.add("loading");
  const {data,error}=await supabase.rpc("admin_login",{p_pin:pin});
  button.disabled=false;button.classList.remove("loading");
  if(error||!data?.ok) {
    $("#admin-login-error").textContent=data?.error||error?.message||"Could not verify the PIN.";
    $("#admin-pin").value="";$("#admin-pin").focus();return;
  }
  adminUi.token=data.token;adminUi.search="";adminSetView(true);adminSetTab("overview");await adminLoad();
});
document.querySelectorAll("[data-admin-tab]").forEach(button=>button.addEventListener("click",()=>adminSetTab(button.dataset.adminTab)));
$("#admin-refresh").addEventListener("click",adminLoad);
$("#admin-export").addEventListener("click",()=>{
  if(!adminUi.data)return;
  const blob=new Blob([JSON.stringify(adminUi.data,null,2)],{type:"application/json"});
  const url=URL.createObjectURL(blob);const link=document.createElement("a");
  link.href=url;link.download="commonroom-admin-snapshot-"+new Date().toISOString().slice(0,10)+".json";
  link.click();URL.revokeObjectURL(url);toast("Admin snapshot exported.");
});
$("#admin-content").addEventListener("click",async(event)=>{
  const tab=event.target.closest("[data-admin-tab]");
  if(tab){adminSetTab(tab.dataset.adminTab);return;}
  const delMessage=event.target.closest("[data-admin-delete-message]");
  if(delMessage){
    if(!confirm("Permanently delete this public message and its attached reports?"))return;
    await adminAction("admin_delete_message",{p_message_id:delMessage.dataset.adminDeleteMessage},"Message removed.");return;
  }
  const resolve=event.target.closest("[data-admin-resolve]");
  if(resolve){await adminAction("admin_resolve_report",{p_report_id:resolve.dataset.adminResolve,p_status:resolve.dataset.status},"Report updated.");return;}
  const delRoom=event.target.closest("[data-admin-delete-room]");
  if(delRoom){
    if(!confirm("Delete this room and all of its messages? This cannot be undone."))return;
    await adminAction("admin_delete_room",{p_room_id:delRoom.dataset.adminDeleteRoom},"Room deleted.");return;
  }
  const editRoom=event.target.closest("[data-admin-edit-room]");
  if(editRoom){
    const name=prompt("Room name (2–40 characters):",editRoom.dataset.name);if(name===null)return;
    const description=prompt("Room description (up to 180 characters):",editRoom.dataset.description);if(description===null)return;
    await adminAction("admin_update_room",{p_room_id:editRoom.dataset.adminEditRoom,p_name:name,p_description:description},"Room updated.");
  }
});
document.addEventListener("keydown",(event)=>{
  if(event.key==="Escape"&&!$("#admin-overlay").hidden)adminClose();
});
$("#messages").addEventListener("click",async(event)=>{
  const report=event.target.closest("[data-report]");
  if(!report)return;
  const reason=prompt("Report reason: spam, harassment, hate, personal-info, or other","spam");
  if(reason===null)return;
  const cleanReason=reason.trim().toLowerCase();
  if(!["spam","harassment","hate","personal-info","other"].includes(cleanReason)){toast("Choose spam, harassment, hate, personal-info, or other.");return;}
  const details=prompt("Optional note (up to 300 characters):","")||"";
  const {data,error}=await supabase.rpc("submit_guest_report",{p_message_id:report.dataset.report,p_reporter_key:state.senderKey,p_reason:cleanReason,p_details:details.slice(0,300)});
  if(error)toast(error.message||"Could not submit report.");
  else toast(data?"Report sent to the moderation team.":"You have already reported this message.");
});

// Boot only after every interaction handler has been attached.
connectRoomsRealtime();
try {
  await loadRooms();
} catch (error) {
  console.error(error);
  $("#messages").innerHTML = '<div class="empty-state"><div class="empty-illustration">!</div><h2>We couldn’t connect.</h2><p>Check your connection and try refreshing the page.</p></div>';
  setConnectionStatus("Connection issue", "warning");
  toast(error.message || "Unable to connect to chat.");
}
