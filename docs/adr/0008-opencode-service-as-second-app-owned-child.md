# ADR-0008: The host opencode service — second app-owned child, app writes the descriptor

- **Status**: accepted (2026-11-12, ticket #153)

## Context

ADR-0002 makes the app the sole owner of the tunnel: server mode is the on-switch, the cloudflared child is spawned and supervised by the bridge, and a second server-mode instance is detected by the port conflict. The opencode service has no such owner: nothing starts `opencode serve` unless the user boots it by hand, and the bridge's sessions/events backends and the orb credential lookup all read the descriptor `~/.local/state/opencode/service.json` — so a host that never ran `opencode serve` answers `opencode_unavailable` on every session endpoint and the bridge is useless.

Two facts, verified against the host CLI (v2.1.4), shape the design:

- `opencode serve` **without** `--service` prints `server listening on http://127.0.0.1:<port>` and `server password <pw>` to stdout and writes **no** `service.json`; with `--service` it writes `{id,version,url,pid,password}` to `~/.local/state/opencode/service.json` (removed on exit) and prints no password.
- The bridge's readers (`OpencodeHttpService.fromHost`, `OpencodeHttpEventService.fromHost`, the orb credential lookup) need only `url` and `password` from that file.

Server mode is already the app's on-switch for the tunnel (ADR-0002); making it the on-switch for opencode too keeps the mental model — "launch the app, everything is up; quit the app, everything stops" — and avoids a second manual step the user would otherwise have to perform (and re-perform after a reboot).

## Decision

- **The app boots the host's shared opencode service in server mode, in `BridgeServer.start`, after the bridge port is bound and before the sessions/events backends and the tunnel are built.** A second server-mode instance therefore fails on the port conflict *before* any second `opencode serve` is spawned (the same guarantee ADR-0002 gives the tunnel). A failed boot degrades, never kills: the bridge still serves (sessions/events answer `opencode_unavailable`; tunnel and orbs are unchanged), and the outcome is visible on the health report (`opencode: unreachable`) and the unified event stream (`opencode.boot` lines). Client mode never starts opencode.
- **Resolution, in order — an already-running service is always attached to, never replaced:**
  1. a service this app instance already started → reuse it (idempotent);
  2. a service started by a previous app instance and still alive (marker `~/.local/state/opencode/opencodebridge-child.json`, `{url, password}`) → **attach**; it stays the app's and is stopped on exit. A stale marker (the previous child is gone) is removed and resolution continues;
  3. an existing `service.json` whose service answers an authenticated Basic `GET /api/session` → **attach** and **never stop it** (the user's or a TUI's service);
  4. otherwise → the app runs `opencode serve --hostname 127.0.0.1 --port <port>` (no `--service`), waits (`startTimeout`) for the service to answer, marks the service as its own, then returns.
- **The app writes the descriptor.** Because the no-`--service` form writes no `service.json` (issue #83), the app itself writes `{url, password}` to `~/.local/state/opencode/service.json` — and the marker — **only after** the credentials are parsed from the child's stdout *and* the service answers an authenticated probe. Files are only ever deleted when they point at the app's own service (a concurrent owner's descriptor is never touched). This makes the shared descriptor the single source of truth the rest of the bridge (and any co-resident tool) reads, while the marker disambiguates "the app owns this service" from "somebody else's service happens to be here".
- **The opencode binary is the CLI's, resolved in order:** the `OPENCODE_CLI` environment override, then `opencode` on the PATH (the existing `findHostOpencode`), then an app-managed pinned install in the app's data directory — the ADR-0002 app-owned binary pattern (`CloudflaredBinary`), pinned to the orb base image's `OPENCODE_VERSION` so the client/service mix does not drift. Pinning is the update mechanism: bump the version in the app source and the next app start re-downloads.
- **Ownership and quit mirror ADR-0002's tunnel lifecycle:** a service the app started (case 4) or re-attached to (case 2) is stopped in `BridgeServer.stop()` — SIGTERM, ~5 s grace, then SIGKILL; a service attached to in case 3 is never touched. The child's stdout/stderr are always drained (an undrained pipe would stall the service), and its output is the boot log, surfaced as `opencode.boot` events on the unified stream.
- **The stop and the attach are identity-checked, not just port-checked.** The case-2 stop resolves the service's pid from the port it answers on and verifies that pid is an opencode process before signalling it (the port may have been freed and re-assigned since the attach; a foreign holder is never signalled — the tunnel supervisor's orphan handling does the same). The case-3 attach re-runs its liveness probe once before giving up: a single transient probe failure (the probe times out after 3 s on a busy host) must not fall through to case 4 and spawn a second service over the user's, whose descriptor it would then replace.
- **The port is not a user-facing concern:** opencode's default (4096) with a bounded increment when taken; the actual URL is taken from the child's `server listening on …` line and written to the descriptor, which is where every reader looks anyway.

## Consequences

- Launching the app in server mode with no opencode service running boots one, writes the descriptor, and the app displays its sessions with no manual step — the "server mode is the on-switch" invariant now holds for opencode as well as the tunnel.
- A user-launched `opencode serve` (which is what `--service` produces) is adopted, never touched, and still running after the app closes; a stale marker from a force-quit is cleaned up on the next launch.
- The app crash orphan case extends to opencode: a force-quit leaves the app-owned service running, and the next app launch re-attaches to it (case 2) instead of spawning a second one.
- A host with no opencode at all (no PATH install, the app-managed download failing) starts the app fine and degrades to `opencode_unavailable` with the reason on the log surface.
- The descriptor's ownership is now split by convention: the app writes the no-`--service` form's descriptor (and removes it only for its own URL); opencode's `--service` form owns its own descriptor (removes it on exit). The marker is the app's file, always.
- The opencode pin and the orb image's `OPENCODE_VERSION` must be kept in step; a drift is visible (the orb boots a different client than the host service).
