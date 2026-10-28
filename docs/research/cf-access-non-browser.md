# Cloudflare Access Authentication for a Non-Browser Client

**Date:** 2026-10-28 (revised — supersedes a first pass that cited non-existent pages and a second pass that invented an intermediary "auth bridge")
**Ticket:** https://github.com/NetAuraTech/OpenCodeBridge/issues/4
**Method:** every cited URL verified HTTP 200 at fetch time; claims are quoted from, or directly implied by, the fetched pages.

## TL;DR

Use **Managed OAuth** — Cloudflare's documented mechanism for non-browser clients. The native app **is** the OAuth client and talks to Access **directly**: no intermediary service, no custom auth bridge. Access issues an opaque access token; the app sends it on every request (plain HTTP, SSE, WebSocket). The origin (the bridge) receives the same `Cf-Access-Jwt-Assertion` / `X-Cloudflare-Access-*` headers it would for a browser login, and never sees or verifies the token.

## 1. Recommended flow: Managed OAuth (the app is the OAuth client)

Why this flow: by default, non-browser clients (CLIs, AI agents, SDKs, scripts) hitting an Access-protected app get a `302` redirect with no usable token or authorization endpoint. Enabling Managed OAuth turns the Access application into a standard OAuth 2.0 authorization server (discovery per RFC 8414/9728, dynamic client registration per RFC 8707), and the `302` becomes a `401` with a `WWW-Authenticate` header pointing at the discovery metadata.

Setup (on the Cloudflare side):
1. Create a **self-hosted Access application** on the tunnel (prerequisite for Managed OAuth).
2. App **Advanced settings** → enable **Managed OAuth** (API: `PUT` the app with `oauth_configuration.enabled = true`).
3. Recommended grants for a native app (from the doc's "Recommended configuration for CLI and agent use cases"):
   - `dynamic_client_registration`: allow loopback/localhost redirect URIs (so the app can register itself as the OAuth client);
   - `grant.access_token_lifetime`: **5–15 minutes** (default 15 min);
   - `grant.session_duration`: **1–2 weeks** (how long the refresh token stays valid).

Runtime flow (in the app):
1. `GET https://<app-domain>/.well-known/oauth-authorization-server` → authorization/token endpoints.
2. Register the client dynamically (RFC 8707) and open the authorization endpoint in the user's browser (system browser on mobile).
3. User logs in to the IdP as usual; Access issues an **opaque** access token (`oauth:...`) plus a refresh token.
4. App sends `Authorization: Bearer <opaque token>` on every request. Cloudflare resolves the token and forwards a signed assertion to the origin — from the origin's perspective the request looks exactly like a browser-authenticated one.
5. On expiry the app refreshes silently (no user interaction) until the grant session ends; Access re-evaluates policies on each refresh. The user only re-authenticates when the grant session expires.

## 2. What the bridge (origin) must do

- **Nothing special.** The origin receives the standard Access headers (`Cf-Access-Jwt-Assertion`, `X-Cloudflare-Access-*`) exactly as for browser logins. The opaque token is resolved by Cloudflare; the origin must NOT try to verify it.
- If the bridge later needs to call *another* Access-protected service as the same user: the **Linked App Token** pattern (forward `Cf-Access-Jwt-Assertion` as `Cf-Access-Token`).
- **Service tokens** are a different mechanism (machine identity, no user, no policy evaluation against a person) — not appropriate for a user-facing app.

## 3. SSE / WebSocket through Access

- The docs describe **no special handling** for SSE/WebSocket: they are just authenticated requests. A connection opened with a valid token stays open; when the session/token expires the client re-authenticates (silent refresh via the refresh token) and reconnects.
- Session model (session-management page): Access issues an **application token** (per app; default 24h, range immediate–1 month) and a **global token** (SSO across apps; default 24h, range 15 min–1 month). For a Managed OAuth client the operative knobs are `grant.access_token_lifetime` and `grant.session_duration` instead.
- Failed authentication for non-browser traffic returns **401** (with `WWW-Authenticate` pointing at discovery metadata) rather than the useless `302` — the app should treat a 401 as "re-run the auth flow".
- **To verify:** what happens to an already-established WebSocket exactly when its token expires (server closes it, or connection persists until server-side timeout) — not documented. Design the client to reconnect on 401/disconnect regardless.

## 4. Minimal single-user setup

- 1 Cloudflare account (the user's domain) + 1 **named tunnel** (cloudflared) pointing at the bridge port.
- 1 **self-hosted** Access application on the tunnel domain.
- IdP: the simplest option is Cloudflare's built-in **email one-time passcode** (no external IdP to configure); a Google account/OIDC works too if preferred.
- 1 policy: allow the user's email.
- Managed OAuth enabled with short access token (5–15 min), long grant session (1–2 weeks), loopback redirect allowed.

## Sources (all verified HTTP 200)

- Managed OAuth: https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/managed-oauth/index.md
- Session management: https://developers.cloudflare.com/cloudflare-one/access-controls/access-settings/session-management/index.md
- Authenticate coding agents (covers OpenCode explicitly): https://developers.cloudflare.com/cloudflare-one/access-controls/authenticate-agents/index.md
- Service tokens (machine-to-machine alternative): https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/index.md
- Linked App Token: https://developers.cloudflare.com/cloudflare-one/access-controls/applications/linked-app-token/index.md
