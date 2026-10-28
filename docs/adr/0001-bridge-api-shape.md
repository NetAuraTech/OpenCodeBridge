# ADR-0001: Shape of the bridge API — wrapper contract, service-owned PTY

- **Status**: accepted (2026-10-28, ticket #7)

## Context

The app needs real-time, interactive access to opencode sessions (terminal and structured views) and to Docker, from any machine, while the opencode service and Docker live on the host. The opencode service is a shared, evolving 130-endpoint API whose PTY surface is experimental. The bridge is the only component on the host that knows the opencode credentials and the Docker socket.

## Decision

- The bridge exposes its own small, stable **wrapper API** (~15 endpoints over the opencode service and Docker). This wrapper is the contract: the app talks **only** to the bridge, in every mode and on every machine, and never to the opencode service directly. opencode credentials stay inside the bridge.
- The terminal is a **service-owned persistent PTY**: the bridge asks the shared opencode service to spawn the TUI in a session-bound PTY (`POST /api/experimental/session/{id}/terminal`) and proxies the attach (connect-token → WebSocket with replay and resumption cursor). Controller/viewer arbitration, takeover, and replay are native service features; the app and the terminal window's attach client attach to the same PTY. The bridge-local-PTY alternative (local `forkpty` + self-managed scrollback) was rejected.
- The bridge listens **localhost-only**, is reachable only through the Cloudflare Access edge, and performs **no JWT verification of its own**. The terminal window's attach client authenticates with a random per-bridge-startup token, passed at spawn time, never persisted; the in-process client (server mode) is implicit.
- **Events**: one SSE endpoint, `GET /api/events`. The bridge holds exactly one upstream `/api/event` subscription and fans out locally to N app connections. Bridge-native events (`docker.container.stopped|crashed`, `terminal.closed`, `session.closed`) are multiplexed with opencode events re-emitted verbatim (durable session seq included).
- **Docker logs**: SSE `?follow=1`, containers addressed by name, keyword filtering client-side.

## Consequences

- The app is insulated from opencode API churn (renames, reshuffles): any break is a bridge-only incident, and the app-facing contract is untouched.
- The bridge inherits replay, scrollback, and multi-viewer control from the service for free — no local PTY management to build or test.
- Risk: the session terminal endpoints sit in opencode's `/api/experimental` family. Pin the opencode service version the bridge is developed against; treat a rename as a bridge-side fix.
- Single upstream subscription means event fan-out is a local concern: the bridge must survive and re-subscribe when the opencode service restarts.
