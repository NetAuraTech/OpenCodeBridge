# ADR-0009: The AFK resident session runs the default agent; the standing rules ride the feed

- **Status**: accepted (2026-11-24, ticket #420)

## Context

The resident AFK session (the one per armed project that implements `ready-for-agent` issues into orbs) was created with a custom `afk` agent. Its definition — the **charter**: the standing operational rules (the dispatch discipline, the `implement-spec` discipline, the human boundary, the wiki memory discipline) **plus** the human-boundary permission denials — was a markdown agent file (`afk.md`) that the app **installed into the host's global opencode config** (`~/.config/opencode/agents/afk.md`) at server-mode startup and **refreshed in place** (the app-owned-files refresh contract, issue #141: a stale, untouched copy of a previous materialization is refreshed to the embedded bytes; a hand-edited copy wins; an absent file is written).

The #417 pilots showed the cost of that on-disk agent state:

- A **stale on-disk copy** kept a running agent on outdated rules long after `main` moved on. The whole install/refresh contract — the digest bookkeeping, the refresh-in-place, the reset/replace semantics — exists only to keep that one file honest.
- A defect class: the rules the agent actually runs from are a **second, materialized copy** of a source of truth that lives in the app's reviewed source. Any rework of the rules is only as good as the refresh mechanism reaching the running agent.

The shared opencode service (v2.2.7, probed against its live `GET /openapi.json`) carries a cheaper, always-current mechanism:

- `POST /api/session`'s body has a `permissions` field: a `Permission.Ruleset` — an **array** of `Permission.Rule` `{ "action": string, "resource": string, "effect": "allow" | "deny" | "ask" }`.
- `Session.Info` (the `GET /api/session/{id}` response) **reports** `permissions` — the same `Permission.Ruleset` — so the enforcement fact is readable back.
- The old charter's frontmatter denials are exactly `Permission.Rule` objects (it used `action: shell`, `resource: "git push --force *"`, `effect: deny`), so they map 1:1.

## Decision

1. **The resident AFK session runs the default agent.** There is **no agent override** on the session's create call, and the app installs and references **no custom `afk` agent anywhere**. The on-disk agent file (`~/.config/opencode/agents/afk.md`), the install/refresh contract (the app-owned-files digest bookkeeping), and their tests (`afk_charter.dart`, `afk_charter_test.dart`, the `AfkCharter.install()` call at bridge startup) are deleted. The arming (`AfkSessionManager.ensureSession`) passes only the pinned model and the human-boundary permissions.
2. **The standing rules ride the feed.** Every feed the bridge sends to the resident session — the per-issue availability notice and the bootstrap on session recreation — **begins with the standing operational rules** and then carries the notice (an issue number and title) or, on a recreation, the in-flight run list. The rules are **versioned in the app source** (`app/lib/bridge/afk/afk_rules.dart`, `standingRules`), so they are always the version shipped with the running app, with no on-disk state to go stale. There is no longer a "pure availability notice" — the feed is the rules plus the notice.
3. **The human-boundary denials are enforced on the resident session itself, as per-session permissions at creation.** The create seam (`OpencodeService.createSession` / `createSessionInDirectory`) gains an optional `permissions` argument; the HTTP layer posts it in the `POST /api/session` body; the composite forwards it to the host (creation is host-only); and a new `sessionPermissions(id)` seam method (with a default implementation that throws `UnimplementedError`, mirroring `probe`/`waitIdle`/`canCancelTurn` so the tests' `noSuchMethod`-based fakes keep compiling) reads the reported `Session.Info.permissions` back, making the enforcement fact observable. The words (the "Never …" rules) ride the feed; the denials (the enforcement) ride the create call.

## Consequences

- A rework of the standing rules **ships with the app** and reaches the running session on its **next feed** — there is no refresh contract, no digest bookkeeping, and no stale-agent defect class.
- A resident AFK session is now **indistinguishable from an interactive session** except for its feed and its session-level permission denials. The app no longer needs a bespoke `afk` agent in the host's global opencode config.
- A service that **ignores the create-time `permissions` field** degrades to the feed's words only (the denials are not enforced by the service, only asked of the agent in the rules). This is accepted and noted: the enforcement point is the service's `POST /api/session` `permissions`, which the shared service (v2.2.7) verifiedly carries and reports back; a service that drops it reverts to the words-only guarantee the old charter's body provided.
- The host's `~/.config/opencode/agents/afk.md` is **no longer written by the app**. A pre-existing copy (from a prior install) is left in place; the app no longer reads or refreshes it, and a re-arm creates a default-agent session regardless of it.
- The session's `permissions` are readable back (`GET /api/session/{id}` → `Session.Info.permissions`), so a test or operator can observe that the denials are actually applied to a live resident session.
- The per-session `permissions` field is a general seam capability (the composite forwards it to the host for any create); the AFK arming is its first caller.
