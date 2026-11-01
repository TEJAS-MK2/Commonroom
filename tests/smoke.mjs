import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const app = readFileSync("app.js", "utf8");
const css = readFileSync("styles.css", "utf8");
const html = readFileSync("index.html", "utf8");
const schema = readFileSync("supabase/schema.sql", "utf8");
const workflow = readFileSync(".github/workflows/deploy.yml", "utf8");
const readme = readFileSync("README.md", "utf8");

const count = (value, pattern) => (value.match(pattern) || []).length;

// Client lifecycle / realtime correctness.
assert.equal(count(app, /async function selectRoom\(roomId\)/g), 1, "room selection must have one implementation");
assert.doesNotMatch(app, /originalSelectRoom|selectRoomWithThreads/, "nested room-switch wrappers must be removed");
assert.match(app, /Boot only after every interaction handler has been attached/);
assert.ok(app.indexOf('$("#admin-open").addEventListener') < app.lastIndexOf("await loadRooms()"), "handlers must register before initial room load");
assert.match(app, /event: "DELETE", schema: "public", table: "chat_guest_messages"\s*\}/, "message deletes must not have a room filter");
assert.match(app, /if \(changed\) renderMessages\(\)/, "global reaction events must only re-render visible changes");
assert.match(app, /function updateOnline\(\)[\s\S]*?typeof person\.guest_id === "string"/);
assert.match(app, /function initials\([\s\S]*?Array\.from\(part\)/, "initials should handle supplementary Unicode code points");
assert.match(app, /lastTypingSentAt/);
assert.match(app, /now - state\.lastTypingSentAt < 1000/, "typing broadcasts should be throttled");
assert.match(app, /typingTimers: new Map\(\)/, "typing timers should be tracked per guest");
assert.match(app, /connectRoomsRealtime\(\)/);
assert.match(app, /storeLimitedToken\([\s\S]*?limit = 1000/, "local owner-token maps must be bounded");
assert.match(app, /create_guest_message/);
assert.match(app, /create_guest_reaction/);
assert.doesNotMatch(app, /edit_token_hash|reaction_token_hash/, "private token hashes must not be sent in public row writes");
assert.match(app, /Messages must be 2,000 characters or fewer/);
assert.match(app, /result\.error\?\.code === "23505"/, "reaction duplicate conflicts must not be swallowed");

// Interface / security.
assert.match(css, /Commonroom 3\.0/);
assert.match(css, /\.admin-frame/);
assert.match(css, /@media \(max-width: 700px\)/);
assert.match(css, /prefers-reduced-motion/);
assert.match(html, /Content-Security-Policy/);
assert.match(html, /favicon\.svg/);
assert.match(html, /<noscript>/);
assert.doesNotMatch(html, /unsafe-eval/, "CSP must not allow eval");
assert.match(readme, /Admin Control Room/);
assert.match(readme, /private\.chat_guest_message_tokens/);

// Database boundary / migration invariants.
assert.match(schema, /create table if not exists private\.chat_guest_message_tokens/);
assert.match(schema, /create table if not exists private\.chat_guest_reaction_tokens/);
assert.match(schema, /create or replace function public\.create_guest_message/);
assert.match(schema, /create or replace function public\.create_guest_reaction/);
assert.match(schema, /drop column if exists edit_token_hash/);
assert.match(schema, /drop column if exists reaction_token_hash/);
assert.match(schema, /private\.chat_guest_moderation_blocks/);
assert.match(schema, /chat_guest_reply_room_scope/);
assert.match(schema, /chat_guest_room_creation_ip_limit/);
const limiterStart = schema.lastIndexOf("create or replace function private.enforce_chat_api_rate_limit()");
const activeLimiter = schema.slice(limiterStart);
assert.ok(limiterStart > 0, "active private IP limiter must be defined");
assert.match(activeLimiter, /cf-connecting-ip/);
assert.doesNotMatch(activeLimiter, /x-forwarded-for/, "do not trust a caller-controlled left-most XFF value");
assert.match(activeLimiter, /0\.0\.0\.0/, "missing or invalid proxy IP should use the shared safety bucket");
assert.match(schema, /alter table private\.chat_guest_message_tokens enable row level security/);
assert.match(schema, /revoke all on private\.chat_guest_message_tokens[\s\S]*?from public,anon,authenticated/i);

// Existing Admin Control Room controls.
assert.match(app, /admin_login/);
assert.match(app, /admin_overview/);
assert.match(app, /submit_guest_report/);
assert.doesNotMatch(app, /6780/, "the admin PIN must never appear in browser code");
assert.match(schema, /private\.chat_admin_sessions/);
assert.match(schema, /private\.chat_admin_audit/);
assert.match(schema, /commonroom-admin-global/);

// Deployment artifact must include the newly linked favicon.
assert.match(workflow, /cp favicon\.svg _site\//);
assert.match(workflow, /node tests\/smoke\.mjs/);
assert.match(workflow, /node --input-type=module --check/);
assert.match(workflow, /Path\("favicon\.svg"\)/);
console.log("Commonroom lifecycle, privacy, security, responsive, and deployment smoke checks passed.");
