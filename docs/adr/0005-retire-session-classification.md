# ADR-0005: Retirement of the session classification — the home list is composed purely from the shared opencode service

- **Status**: accepted (2026-11-02, ticket #53)

## Context

ADR-0001 positioned the terminal as a first-class surface: the bridge classified sessions (app-launched vs external), persisted the app-launched session ids across bridge restarts, tracked an in-process "live" fact, and reconciled orphaned records at startup. That machinery existed so the bridge could tell the sessions it launched — and therefore could display and attach to terminal windows — apart from the sessions the user started manually.

Since the terminal view left the app (issues #65, #66), nothing consumes the classification: the structured view renders every row identically, and the home list no longer needs to know who launched a session. The persistence file, the live fact, and the startup orphan reconciliation are dead machinery whose only observable effect is a `classification` field on the `GET /api/sessions` rows.

## Decision

- The app-launched/external session classification is retired. The `Session` model, the home-list wire contract, and the app UI carry no classification; the `GET /api/sessions` rows are composed purely from shared opencode service data (the session list and the active ids), with no persistence and no live fact.
- The app-launch persistence (the session-id store), the in-process live-session fact, and the startup orphan reconciliation are removed; a fresh bridge start behaves identically to any other start (rows are what the service reports).
- This explicitly supersedes two decisions of ADR-0001:
  - the **service-owned persistent PTY**: the bridge no longer asks the shared opencode service to spawn the TUI in a session-bound PTY (`POST /api/experimental/session/{id}/terminal`) nor proxies the attach (connect-token → WebSocket with replay and resumption cursor);
  - the **attach endpoint and per-startup window token**: there is no attach client, no attach route, and no random per-bridge-startup window token.
- The rest of ADR-0001 stands: the bridge is a small, stable wrapper API and the only API the app talks to, in every mode; opencode credentials stay inside the bridge; the bridge listens localhost-only, reachable only through the Cloudflare Access edge, performing no JWT verification of its own; one SSE endpoint, `GET /api/events`, holds exactly one upstream `/api/event` subscription and fans out locally, multiplexing bridge-native events (`session.closed`, `docker.container.stopped|crashed`, `llama.speed`) with opencode events re-emitted verbatim — the ADR-0001 `terminal.closed` event is retired with the terminal surface; Docker logs stream over SSE `?follow=1`, containers addressed by name, keyword filtering client-side.

## Consequences

- The home list and the session detail are pure projections of the shared opencode service: there is no bridge-local session state to drift from the service, and nothing to reconcile at startup.
- `session.closed` remains a bridge-native event, emitted when a successful `DELETE /api/sessions/{id}` removes a session from the service.
- If interactive terminal access is ever revived, it is a new decision with a new ADR; the classification does not come back implicitly.
