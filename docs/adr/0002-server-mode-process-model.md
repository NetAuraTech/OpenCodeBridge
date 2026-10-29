# ADR-0002: Server mode process model — app-owned tunnel child, no autostart

- **Status**: accepted (2026-10-28, ticket #11)

## Context

Server mode must run a locally-managed (named) Cloudflare tunnel in front of the bridge's localhost-only listener, on a single host: the user's GNOME Linux desktop. The app is a Flutter desktop app and is the user-visible component; the user launches it manually and does not want it started automatically. cloudflared is not installed on the host. The app targets Linux now and a Windows host later.

## Decision

- **The app is the sole owner of the tunnel.** The user launches the app (mode choice server/client at launch, locked by "App screens and flows"); server mode is the on-switch, quitting the app is the off-switch. There is **no autostart entry and no persistent on/off toggle** (supersedes the GNOME-session-autostart mechanism noted in "Spawning a terminal window from the bridge"; that ticket's spawn-context constraint — inside the user's graphical session — still holds, trivially, for a manually launched app). cloudflared runs as a **child process** of the app, supervised by the bridge.
- The cloudflared binary is **app-managed**: a pinned version downloaded into the app's own directory, updated with the app. `--no-autoupdate` is always passed: cloudflared's self-update (spawns a new process, old process exits) is incompatible with child supervision and with pinned versions.
- **Setup is one-time and manual, guided by the spec**: the user runs the documented commands once (cloudflared auth, `cloudflared tunnel create <NAME>`, DNS route, Access application + policies in the dashboard) and writes the config file. Files: credentials `~/.cloudflared/<uuid>.json` (created by the CLI, stays there), config **`~/.config/opencodebridge/cloudflared.yml`** (app-owned, spawned with `--config`, isolated from the default cloudflared paths). At server-mode start the app verifies every precondition and reports the missing steps.
- **Lifecycle**: unexpected child exit → capped auto-respawn (3 per 60 s), then a visible "tunnel down" error with a manual restart action. At startup, if the metrics port (20241) is held **by a cloudflared process** (an orphan from a force-quit, which kept the tunnel serving) it is SIGTERM'd, then the app's own instance is spawned; if held by anything else, the app falls back to metrics port 20242. Normal quit: SIGTERM, wait 5 s, then SIGKILL.
- **Health**: UI "tunnel up/down" = child liveness plus a scrape of the child's `--metrics` endpoint (registered connections > 0), distinguishing "cloudflared runs" from "actually connected to the edge".
- **Server mode v1 is Linux-host only** (POC first; after a validated POC and a final Linux/Android app, the user moves to managing a Windows host). Host-side capabilities (terminal spawn, startup, binary management, signals, ports) sit behind **per-OS adapters**, so a future Windows host is a new adapter, not a core refactor. Windows runs in client mode until then.

## Consequences

- Remote access is strictly session-scoped to the app's lifetime: nothing runs (no bridge, no tunnel, no pushes) between app launches; reboot/logout/quit all stop everything.
- An app crash leaves an orphaned cloudflared that keeps the tunnel serving until the next app launch cleans it up: remote stays reachable with the app dead — a feature, not a bug.
- A bridge restart (crash, app update) is UX-lossless: service-owned PTY + resumption cursors + durable SSE seqs (ADR-0001) make attach re-attach and event catch-up work without data loss.
- The systemd-user-unit alternative (free Restart=on-failure, tunnel independent of app crashes) was considered and rejected: it splits ownership into two control planes, contradicts the single on/off switch, and does not generalize to Windows.
- A second server-mode instance is detected by the port conflict: the app errors, it never spawns a second tunnel.
