# ADR-0003: Assisted tunnel setup — the bridge writes the app-owned files

- **Status**: accepted (2026-10-31, ticket #34)

## Context

ADR-0002 makes the app the sole owner of the tunnel: the tunnel is one-time and manual, guided by a spec the user follows by hand (auth, `cloudflared tunnel create <NAME>`, a DNS route, a Cloudflare Access application, and writing the config file). The manual steps that are easy to get wrong — and that the guided setup already re-checks — are the two files the tunnel runs on: the credentials `~/.cloudflared/<uuid>.json` (written by the `cloudflared` CLI) and the app-owned config `~/.config/opencodebridge/cloudflared.yml`. The user has to copy the CLI's output and hand-write YAML with the exact ingress and port, then create the DNS route and the Access application in the dashboard by hand.

The app is already the single API the user talks to (ADR-0001) and already runs the precondition pass that names each missing step. Issue #34 asks to turn the remaining manual file-writing into an in-app wizard in the Settings tab (server mode only), so the user pastes what the CLI produced and the app does the rest.

## Decision

- **The bridge is the sole file owner; the wizard is just its input.** A new `POST /api/tunnel/setup` endpoint (server mode) takes the three wizard inputs — tunnel name, public hostname, and the pasted credentials JSON — validates them, and **the bridge writes the two app-owned files on the user's behalf**: the pasted credentials **verbatim** to `~/.cloudflared/<uuid>.json`, and the generated config to `~/.config/opencodebridge/cloudflared.yml`. The user never writes YAML and never touches the credentials file by hand. (This extends ADR-0002's "the app is the sole owner of the tunnel" to the files, not just the process.)
- **Validation is duplicated by design.** The app validates the three inputs before the round trip (the wizard's clear, as-is error line) and the bridge validates them again at the endpoint — the bridge is the file owner and must not trust the app. Both share one validation module. The credentials are accepted when they are valid JSON, carry a `TunnelID` UUID, and a non-empty API key/token (`APIKey`/`APIToken`/`AccessToken`); `OwnerEmail` and `OwnerAccountID` are optional and feed the manual steps and the dashboard deep links.
- **The generated config is the app's, not the user's.** It routes the ingress `hostname` → `http://127.0.0.1:<bridge-port>` and includes the catch-all `- service: http_status:404` that cloudflared requires. The `credentials-file` points at the path the credentials were actually written to (the default `~/.cloudflared/<uuid>.json`), so the precondition pass and cloudflared probe the same file.
- **Setup is idempotent and finishes the setup in place.** Writing over the app-owned files with the same inputs is safe (same result). After writing, the bridge re-runs the precondition pass and, when every step is met, **(re)starts the tunnel child** — no app restart. The endpoint answers with a fresh `TunnelReport` (the same convention as check/start). While manual dashboard steps are still missing, the child is left untouched and the missing-steps list updates on recheck until everything is green.
- **The two dashboard steps stay manual, but are made exact.** The DNS route (CNAME) and the Cloudflare Access application cannot be created by the app (no Cloudflare API token is stored); the wizard displays their exact values with a copy action: the CNAME `<hostname> → <tunnel-uuid>.cfargotunnel.com` and the Access application spec (a self-hosted app for `https://<hostname>` with an email policy — the credentials' `OwnerEmail` when present, otherwise the user's own Cloudflare account email).
- **Dashboard deep link.** Each manual step shows a dashboard link. When the pasted credentials carry an `OwnerAccountID`, the link is the account-scoped short form `https://dash.cloudflare.com/<accountId>/<path>` (`/dns/records` for the CNAME, `/access/apps` for the Access app); without an account id it falls back to the dashboard root `https://dash.cloudflare.com/`. The link is shown as text with a copy action (the app stores no Cloudflare token and has no `url_launcher` dependency; it does not open the browser).
- **Client mode is unchanged.** The wizard is a server-mode feature (client mode only connects to a hostname); the Settings tunnel section only offers it in server mode.

## Consequences

- The user's one-time setup shrinks to: log in (the wizard's app-driven login), give the tunnel a name and a hostname in the wizard, and create the two dashboard steps the wizard spells out exactly. The config file and the credentials file are written by the app, not the user.
- The bridge now has write access to `~/.cloudflared` and `~/.config/opencodebridge` (the app-owned config dir it already owns); an unwriteable path is a distinct `TunnelSetupWriteError` → 500, separate from a bad payload → 400.
- The endpoint answers a fresh `TunnelReport`, so the UI can adopt the post-setup state with the same code path as check/start — no new report shape.
- The app never stores a Cloudflare API token beyond the user's own credentials file (which it writes verbatim from the user's paste, or that the app-driven create writes — see Follow-up); the dashboard steps remain a human-in-the-loop step by design.
- Re-running the wizard over an existing setup is safe and is the supported way to fix a broken or stale app-owned config without touching the user's other cloudflared state.

## Follow-up (ticket #37)

The wizard still required the user to run the two `cloudflared` CLI commands from a terminal — but the only `cloudflared` on the machine is the app-managed binary (ADR-0002), and the Cloudflare dashboard's Create-a-Tunnel flow produces no credentials file. Ticket #37 moves those two commands into the app, driving the same app-managed binary:

- **The app-driven Cloudflare login.** A new `POST /api/tunnel/login` endpoint (server mode) runs the app-managed `cloudflared tunnel login`, which opens the default browser on Cloudflare's OAuth consent page and, on success, stores the session in the user's own `~/.cloudflared/`. The wizard's credentials paste becomes **optional**: while it is empty the wizard offers a **Log in to Cloudflare** button that drives this endpoint.
- **The app-driven create.** When the setup payload carries no pasted credentials, `POST /api/tunnel/setup` drives `cloudflared tunnel create <NAME>` (the login session is required) and uses the `~/.cloudflared/<uuid>.json` the CLI itself writes, instead of writing the paste verbatim.
- **The ADR-0003 boundary is kept.** The app still never touches a Cloudflare token: the login session and the credentials file are written by `cloudflared` itself into the user's home directory; the app only spawns the binary and reads its exit status, and writes the app-owned config as before.
