import assert from "node:assert/strict";
import { chromium } from "playwright";

const MOCK_SUPABASE_MODULE = `
const rooms = [
  { id: "11111111-1111-4111-8111-111111111111", slug: "general", name: "general", description: "A place for everyday conversations." },
  { id: "22222222-2222-4222-8222-222222222222", slug: "coding", name: "coding", description: "Share what you are building, learning, and debugging." },
  { id: "33333333-3333-4333-8333-333333333333", slug: "random", name: "random", description: "Anything that does not fit anywhere else." }
];
const calls = [];
export function createClient() {
  const resultFor = (table) => ({ data: table === "chat_rooms" ? rooms : [], error: null });
  return {
    from(table) {
      const query = {
        select() { return this; },
        eq() { return this; },
        order() { return this; },
        limit() { return this; },
        in() { return this; },
        maybeSingle() { return Promise.resolve({ data: null, error: null }); },
        single() { return Promise.resolve({ data: null, error: null }); },
        then(resolve, reject) { return Promise.resolve(resultFor(table)).then(resolve, reject); }
      };
      return query;
    },
    rpc(name, args = {}) {
      calls.push({ type: "rpc", name, args });
      if (name === "create_guest_session") return Promise.resolve({ data: { ok: true, token: "f".repeat(64), sender_key: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", display_name: args.p_display_name, expires_at: "2026-11-09T00:00:00Z" }, error: null });
      if (name === "resume_guest_session") return Promise.resolve({ data: { ok: true, sender_key: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", display_name: "Browser QA", expires_at: "2026-11-09T00:00:00Z" }, error: null });
      if (name === "update_guest_session_name") return Promise.resolve({ data: true, error: null });
      if (name === "create_guest_message") return Promise.resolve({ data: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", error: null });
      return Promise.resolve({ data: true, error: null });
    },
    channel(name) {
      return {
        name,
        on() { return this; },
        subscribe(callback) {
          queueMicrotask(() => callback?.("SUBSCRIBED"));
          return this;
        },
        presenceState() { return {}; },
        track() { return Promise.resolve("ok"); },
        send() { return Promise.resolve({ status: "ok" }); }
      };
    },
    removeChannel() { return Promise.resolve("ok"); }
  };
}
window.__commonroomMockCalls = calls;
`;

async function createAppPage(browser, viewport) {
  const context = await browser.newContext({ viewport });
  await context.addInitScript(() => {
    localStorage.setItem("commonroom-name", "Browser QA");
    localStorage.setItem("commonroom-guest-id", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
  });
  const page = await context.newPage();
  const pageErrors = [];
  const supabaseRequests = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));
  page.on("request", (request) => {
    if (request.url().includes(".supabase.co")) supabaseRequests.push(request.url());
  });
  await page.route("https://esm.sh/@supabase/supabase-js@2.57.4**", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/javascript",
      body: MOCK_SUPABASE_MODULE
    })
  );
  await page.goto("http://127.0.0.1:4173/", { waitUntil: "domcontentloaded" });
  await page.locator("#active-room-name").waitFor({ state: "visible" });
  await page.waitForFunction(() => document.querySelector("#active-room-name")?.textContent === "general");
  await page.waitForFunction(() => document.querySelector("#connection-status")?.dataset.state === "live");
  return { context, page, pageErrors, supabaseRequests };
}

async function testDesktop(browser) {
  const { context, page, pageErrors, supabaseRequests } = await createAppPage(browser, { width: 1440, height: 900 });
  try {
    assert.equal(await page.locator("#active-room-name").textContent(), "general");
    await page.getByRole("button", { name: "# coding" }).click();
    await page.waitForFunction(() => document.querySelector("#active-room-name")?.textContent === "coding");
    assert.equal(await page.locator("#connection-status").getAttribute("data-state"), "live");

    await page.locator("#message-input").fill("This is a local browser test; it will not be sent.");
    assert.match(await page.locator("#message-input").inputValue(), /local browser test/);
    await page.locator("#send-button").click();
    await page.waitForFunction(() => document.querySelector("#message-input")?.value === "");
    const writeCalls = await page.evaluate(() => window.__commonroomMockCalls);
    const sessionCall = writeCalls.find((call) => call.name === "create_guest_session");
    const messageCall = writeCalls.find((call) => call.name === "create_guest_message");
    assert.ok(sessionCall, "browser must obtain a server-issued guest session");
    assert.ok(messageCall, "message composer must use the session-backed RPC");
    assert.equal(messageCall.args.p_session_token, "f".repeat(64));
    assert.equal(Object.hasOwn(messageCall.args, "p_sender_key"), false, "client must not choose the sender identity");

    await page.locator("#admin-open").click();
    await page.locator("#admin-login-view").waitFor({ state: "visible" });
    assert.equal(await page.locator("#admin-pin").getAttribute("maxlength"), "4");
    assert.equal(await page.locator("#admin-pin").getAttribute("type"), "password");
    await page.locator("#admin-close").click();
    await page.locator("#admin-overlay").waitFor({ state: "hidden" });

    await page.reload({ waitUntil: "domcontentloaded" });
    await page.waitForFunction(() => document.querySelector("#connection-status")?.dataset.state === "live");
    const resumedCalls = await page.evaluate(() => window.__commonroomMockCalls);
    assert.ok(resumedCalls.some((call) => call.name === "resume_guest_session"), "reload must resume the server-issued session");
    assert.equal(resumedCalls.some((call) => call.name === "create_guest_session"), false, "reload must not create a second guest identity");
    assert.deepEqual(supabaseRequests, [], "browser smoke tests must not contact the production Supabase project");
    assert.deepEqual(pageErrors, [], "desktop page must not throw runtime errors");
    console.log("PASS desktop: session issue/resume, room switching, composer RPC payload, admin modal, isolated backend");
  } finally {
    await context.close();
  }
}

async function testMobile(browser) {
  const { context, page, pageErrors, supabaseRequests } = await createAppPage(browser, { width: 375, height: 812 });
  try {
    await page.locator("#mobile-menu").click();
    assert.equal(await page.locator("#mobile-menu").getAttribute("aria-expanded"), "true");
    assert.equal(await page.locator("#sidebar").evaluate((node) => node.classList.contains("open")), true);

    await page.getByRole("button", { name: "# random" }).click();
    await page.waitForFunction(() => document.querySelector("#active-room-name")?.textContent === "random");
    assert.equal(await page.locator("#connection-status").getAttribute("data-state"), "live");

    await page.locator("#mobile-menu").click();
    await page.locator("#admin-open").click();
    await page.locator("#admin-login-view").waitFor({ state: "visible" });
    const adminWidth = await page.locator(".admin-frame").evaluate((node) => node.getBoundingClientRect().width);
    assert.ok(adminWidth <= 375, `mobile admin dialog overflows viewport: ${adminWidth}px`);
    await page.locator("#admin-close").click();

    const dimensions = await page.evaluate(() => ({
      viewport: window.innerWidth,
      body: document.body.scrollWidth,
      app: document.querySelector(".app-shell").scrollWidth
    }));
    assert.ok(dimensions.body <= dimensions.viewport + 1, `mobile body overflows: ${JSON.stringify(dimensions)}`);
    assert.ok(dimensions.app <= dimensions.viewport + 1, `mobile app shell overflows: ${JSON.stringify(dimensions)}`);
    const mobileCalls = await page.evaluate(() => window.__commonroomMockCalls);
    assert.deepEqual(mobileCalls.map((call) => call.name), ["create_guest_session"]);
    assert.deepEqual(supabaseRequests, [], "mobile browser smoke tests must not contact the production Supabase project");
    assert.deepEqual(pageErrors, [], "mobile page must not throw runtime errors");
    console.log("PASS mobile: navigation, room switching, admin modal, 375px overflow check, no writes");
  } finally {
    await context.close();
  }
}

const browser = await chromium.launch({ headless: true });
try {
  await testDesktop(browser);
  await testMobile(browser);
} finally {
  await browser.close();
}
