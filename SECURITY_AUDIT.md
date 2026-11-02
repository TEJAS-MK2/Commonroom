# Commonroom production-readiness audit

**Review date:** 2026-11-02  
**Repository:** [TEJAS-MK2/Commonroom](https://github.com/TEJAS-MK2/Commonroom)  
**Reviewed base commit:** `be77164ba94f6ad84724c50d40ccb4c1275d0b4b`

## Executive summary

The repository's latest GitHub Actions run at the time of review (`41389279695`) completed successfully. Both the `build` and `deploy` jobs passed, including the Playwright desktop/mobile suite, and the GitHub Pages URL returned HTTP 200 during a fresh fetch.

The latest database migration visible in Supabase's migration history was `20261102043150_remove_legacy_guest_identity_rpc_overloads`; the server-issued guest-session migration and cleanup migration are recorded as applied.

This is a successful CI/deployment and configuration review, **not** a full live-backend acceptance test. The committed Playwright suite mocks Supabase, so it cannot prove that two real browsers can exchange messages through the production Realtime service.

## Verified

- [x] Latest GitHub Actions build job passed.
- [x] Latest GitHub Pages deploy job passed.
- [x] Fresh GitHub Pages fetch returned HTTP 200 and the expected Commonroom page metadata.
- [x] Supabase migration history includes the server-issued guest-session migration and the removal of legacy client-identity RPC overloads.
- [x] Active database guest-message and guest-reaction RPCs derive sender identity from a server-issued session token.
- [x] The active admin login function uses the gateway-provided `cf-connecting-ip` value, serializes per-IP/global attempts, and persists failed attempts.
- [x] Private token/session/admin tables have RLS enabled and direct grants to `public`, `anon`, and `authenticated` revoked.
- [x] CI runs syntax checks, repository smoke checks, Playwright desktop/mobile checks, HTML checks, and browser-asset secret scans.
- [x] Playwright tests explicitly assert that the browser does not contact the production Supabase project.
- [x] Read-only production SQL checks confirmed three public rooms and Realtime publication membership for rooms, guest messages, and guest reactions.
- [x] Read-only privilege checks confirmed anonymous users cannot read/write moderation reports, cannot insert directly into guest messages, and cannot read private guest sessions or admin configuration; anonymous message reads remain enabled for the public chat.

## Read-only production checks

The live database returned three public rooms, one guest message, and two reactions at the time of inspection. The three chat tables (rooms, guest messages, and guest reactions) were present in the `supabase_realtime` publication. Direct privilege checks returned: anonymous SELECT on public guest messages = allowed; anonymous INSERT on guest messages = denied; anonymous SELECT/INSERT on moderation reports = denied; anonymous SELECT on private guest sessions = denied; anonymous SELECT on private admin configuration = denied. No message bodies, session tokens, PIN hashes, or other private row contents were retrieved for this check.

## Residual risks and follow-up

### 1. Admin credential strength

The current admin credential remains a four-digit PIN. The database enforces a maximum of five failed attempts per client IP per 15 minutes and a global ceiling, and successful sessions expire after 30 minutes. This is useful friction, but a four-digit PIN is not appropriate as the only long-term administrator authentication factor.

**Recommended next step:** replace PIN-only login with Supabase Auth identity-backed administrator roles and MFA. Do not silently change the existing PIN verifier or clear its stored hash during a migration: that could lock the owner out. A credential migration needs a deliberate administrator enrollment/reset flow.

### 2. Network rate-limit transaction semantics

The PostgREST pre-request counter is stored in the same database transaction as the request. A request that later fails can roll back its own counter row. The existing network ceiling therefore provides useful abuse friction for successful writes, but it is not a durable failed-request counter or a DDoS defense.

**Recommended next step:** if stronger abuse protection is required, put the edge rate limit in a service with atomic counters outside the chat write transaction (for example, a gateway/WAF or an appropriately configured edge function and external counter). Preserve the database trigger checks as a second layer.

### 3. Live-backend acceptance test not performed

The committed Playwright tests replace the Supabase SDK with a deterministic mock. This is intentional to keep CI safe and repeatable, but it does not verify production credentials, realtime delivery, database policies, or behavior across two actual user sessions.

**Recommended next step:** run a controlled staging acceptance test with two isolated browser contexts and disposable test identities. Verify message delivery, reconnect behavior, edit/delete ownership, reactions, reporting, and session expiry. Do not run destructive moderation tests against production data.

### 4. Supabase advisor findings outside the Commonroom feature

The project-wide Supabase advisor returned these findings during this review:

- 22 informational `rls_enabled_no_policy` findings, including private-schema tables and the public moderation-report table. These tables are intentionally protected by revoked direct grants; the absence of policies is not by itself proof of public exposure. Recheck grants and function boundaries before changing them.
- One warning for `monitoring.set_updated_at` having a mutable search path.
- One warning that `pg_net` is installed in the `public` schema.
- One warning that leaked-password protection is disabled in Supabase Auth. Commonroom currently uses anonymous guest sessions rather than Supabase Auth passwords, but this setting matters to other Auth-enabled project features.
- Performance findings include unindexed foreign keys in the separate `monitoring` schema, RLS init-plan warnings on `kolkata_puja_user_state`, and unused-index observations. These are project-wide and not automatically Commonroom defects.

Do not bulk-delete indexes or create permissive RLS policies just to silence advisor messages. Confirm workload and intended access first.

## Verification boundaries

- A successful deployment confirms that GitHub Pages accepted the built artifact; it does not prove every runtime integration is healthy.
- A successful mocked browser test confirms the tested client behavior under the mock contract; it does not prove production Supabase behavior.
- This audit did not change the production database, rotate administrator credentials, or run destructive production actions.
