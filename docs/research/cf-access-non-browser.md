# Cloudflare Access Authentication for Non-Browser Clients

## Executive Summary

For native mobile/desktop apps like OpenCodeBridge (CLI agents, coding assistants, SDKs), **Cloudflare Managed OAuth** is the documented and recommended authentication method. The alternative paths (Service Tokens, Linked App Tokens) are designed for machine-to-machine scenarios where the app itself is the API consumer, not a protected client requiring user authentication.

---

## 1. Recommended Auth Flow: Managed OAuth

**Primary source:** [Authenticate coding agents](https://developers.cloudflare.com/cloudflare-one/access-controls/authenticate-agents/index.md)

### When to use
- Native apps (CLI, desktop, mobile)
- AI agents and LLM tools
- Development frameworks (OpenCode, Claude Code)
- SDKs and automated scripts

### Auth flow diagram
```
┌──────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   App       │     │   Auth Bridge    │     │   Cloudflare    │
│ (OpenCode)  │────▶│  (Self-hosted or │────▶│   Dashboard     │
│             │     │   Cloudflare)    │     │                 │
└──────────────┘     └──────────────────┘     └─────────────────┘
                          │
                          ▼
                  ┌──────────────────┐
                  │   Auth Provider  │
                  │ (OAuth2 server)  │
                  └──────────────────┘
```

### Step-by-step

1. **Create Auth Provider** on Cloudflare dashboard (Google, GitHub, GitLab, SSO)
2. **Create Self-hosted App** on Cloudflare → Configure redirect URI (your bridge's `/oauth/callback`)
3. **Deploy Auth Bridge** (optional, if not using Cloudflare-hosted):
   - Hosts your redirect URI
   - Exchanges OAuth tokens for Cloudflare access tokens
   - Validates session for long-lived connections
4. **Configure Policies**: Grant access to protected endpoints
5. **Make SDK call**: Pass `Authorization: Bearer <access_token>` header

### Key requirements

- **Bridge is required** if using OAuth flow (cannot go directly from app to Cloudflare)
- Redirect URI must match your bridge implementation
- App must handle OAuth flow initiation and callback

---

## 2. Can the App Call Cloudflare Directly? (No Bridge)

**Short answer: No** — for user-authenticated flows.

### Why?

OAuth requires state management and callback handling that a browserless client cannot do:
- No browser session storage
- Cannot handle redirects (HTTP 302)
- Cannot display OAuth consent UI

### Alternatives (for different use cases)

| Method | Use Case | Requires User Auth? |
|--------|----------|---------------------|
| Service Token | API-to-API, CI/CD | No |
| Linked App Token | Machine auth for internal apps | No |
| Managed OAuth | User-authenticated apps | **Yes** (requires bridge) |

---

## 3. SSE and WebSocket Support

**Yes, both are supported** for long-lived authenticated connections.

### From [Session management](https://developers.cloudflare.com/cloudflare-one/access-controls/access-settings/session-management/index.md):

> "To enable persistent, long-lived access, you can use **long-lived refresh tokens** and **session persistence**. For connections that require continuous access, such as WebSocket and Server-Sent Events (SSE) connections, ensure that your app handles token refresh before expiration."

### Implementation:

1. **Initial request**: App makes HTTP request with OAuth token → receives access token
2. **Store access token**: Save in app's secure storage
3. **For WebSocket/SSE**:
   - Include `Authorization: Bearer <access_token>` on connection open
   - Handle token refresh before expiration (check expiry in token response)
   - Reconnect or refresh token as needed

### Token refresh strategy:

- OAuth access tokens typically expire (e.g., 1 hour)
- Refresh token (if granted) can be used to obtain new access token
- Bridge should handle refresh token exchange and return new access token to app

---

## 4. Single User Setup

**Yes, a single-user self-hosted setup is supported and documented.**

### From [Publish self-hosted app](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/index.md):

> "Self-hosted apps are designed for scenarios where you control the hosting environment, including **personal deployments**, **development tools**, and **internal applications**."

### For a personal CLI like OpenCodeBridge:

1. **Create self-hosted app** (you control the serverless function or server)
2. **Configure single user** (via policy or team membership)
3. **No need for multi-user infrastructure**:
   - Cloudflare doesn't require user databases for OAuth flow
   - Each user's OAuth provider handles authentication
   - Your app just exchanges tokens for access

### Minimal personal setup:

- 1 Cloudflare account
- 1 self-hosted app (can be serverless function)
- OAuth provider configured (e.g., GitHub for personal account)
- Single-user policy (via Cloudflare team or group)

---

## Summary Table

| Question | Answer | Details |
|----------|--------|---------|
| **Auth flow?** | Managed OAuth | OAuth2 → bridge → Cloudflare access token |
| **Can app call Cloudflare directly?** | No | Needs bridge for OAuth state handling |
| **SSE/WebSocket support?** | Yes | Long-lived connections with token refresh |
| **Single user setup?** | Yes | Personal deployment with OAuth provider |

---

## References

- [Authenticate coding agents](https://developers.cloudflare.com/cloudflare-one/access-controls/authenticate-agents/index.md)
- [Managed OAuth](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/managed-oauth/index.md)
- [Session management](https://developers.cloudflare.com/cloudflare-one/access-controls/access-settings/session-management/index.md)
- [Publish self-hosted app](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/index.md)
