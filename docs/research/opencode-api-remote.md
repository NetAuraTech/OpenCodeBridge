# Remote Client API: OpenCode v2 HTTP Endpoints

## Summary

This research documents the HTTP API capabilities of OpenCode v2 for remote clients (phone/desktop behind Cloudflare Tunnel). Every endpoint cited is verified against the official OpenAPI spec (`/tmp/opencode/wf/spec.json`).

**Protocol**: All endpoints must appear in `spec['paths']`. Claims backed by spec entries or read-only live probes. Unverified items marked "to verify".

**Sources**:
- OpenAPI Spec: https://opencode.ai/v2/openapi.json (downloaded to `/tmp/opencode/wf/spec.json`)
- Official Docs: https://opencode.ai/v2/docs/
- Live service: http://127.0.0.1:49374 (auth required)

**Server Info** (`GET /api/info`):
```json
{"version":"2.1.4","capabilities":{"persistentPty":true},"urls":["http://127.0.0.1:49374"]}
```

---

## 1. Multiple Simultaneous Clients

**Status**: ✅ **Supported**

- **`GET /api/session/active`** returns list of active sessions
  - Live probe returned 4 running sessions: `ses_e7c87fc15ffelt4TtMDqYQHUip`, `ses_e7c328737ffeRrUrvQHdv6wZZm`, `ses_e7c328736ffeeE4Xc9ShT9DhND`, `ses_e7c328732ffexjkNJkwkyI37lq`
  - Each session has unique ID → multiple clients supported

- **`POST /api/session`** creates new sessions
- No explicit limits in spec (to verify: check `/api/experimental/usage/limits` if accessible)

---

## 2. Event Stream (SSE): `/api/event`

**Status**: ✅ **Specified**

- **Endpoint**: `GET /api/event`
- **Spec entry**: `paths['/api/event']['get']` exists
- **Live probe**: Connection opened, stream active until timeout (no error returned)

**To verify**: Event types (messages, tools in flight, session state, permissions) and re-subscription behavior not documented in spec.

---

## 3. PTY & Persistent PTY

**Status**: ✅ **Supported**

Live terminal streaming for remote clients is implemented via dedicated PTY endpoints:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `GET /api/pty` | GET | List active PTY sessions |
| `POST /api/pty` | POST | Create new PTY session |
| `GET /api/pty/{ptyID}` | GET | Get PTY state |
| `PUT /api/pty/{ptyID}` | PUT | Update PTY |
| `DELETE /api/pty/{ptyID}` | DELETE | Terminate PTY |
| `POST /api/pty/{ptyID}/connect-token` | POST | Generate connect token |
| `GET /api/pty/{ptyID}/connect` | GET | WebSocket endpoint |

**Experimental Persistent PTY** (for long-lived connections):

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `GET /api/experimental/persistent-pty/{ptyID}` | GET | Get persistent PTY state |
| `PUT /api/experimental/persistent-pty/{ptyID}` | PUT | Update persistent PTY |
| `DELETE /api/experimental/persistent-pty/{ptyID}` | DELETE | Terminate persistent PTY |
| `GET /api/experimental/persistent-pty/{ptyID}/connect` | GET | WebSocket connect |
| `POST /api/experimental/persistent-pty/{ptyID}/connect-token` | POST | Generate connect token |
| `GET /api/experimental/persistent-pty/{ptyID}/snapshot` | GET | Get terminal snapshot |
| `POST /api/experimental/persistent-pty/shutdown` | POST | Force shutdown |
| `POST /api/experimental/persistent-pty/handoff` | POST | Handoff to user |

**To verify**: Connection limits (one per PTY?), ticket expiry, rate limits.

---

## 4. Creating a New Conversation

**Status**: ✅ **Supported**

Sessions are created via:

- **`POST /api/session`** - Create new session
- **`POST /api/experimental/voice/session`** - Create voice session
- **`POST /api/experimental/session/import`** - Import existing session

Sessions can be attached to a project via:
- **`POST /api/session/{sessionID}/move`** - Move session to project directory
- **`POST /api/session/{sessionID}/prompt`** - Prompt session (creates conversation)
- **`POST /api/session/{sessionID}/command`** - Send command to session

---

## 5. Permissions

**Status**: ✅ **Supported**

Endpoints for managing permissions:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `GET /api/permission/request` | GET | List pending permission requests |
| `GET /api/permission/saved` | GET | List saved permission presets |
| `PATCH /api/permission/saved/{id}` | PATCH | Update saved preset |
| `DELETE /api/permission/saved/{id}` | DELETE | Delete saved preset |
| `POST /api/session/{sessionID}/permission` | POST | Request permission |
| `GET /api/session/{sessionID}/permission/{requestID}` | GET | Get specific request |
| `POST /api/session/{sessionID}/permission/{requestID}/reply` | POST | Reply with once/always/reject |

**To verify**: Exact response format for reply (`once|always|reject`).

---

## To Verify

- SSE event types and reconnection behavior on `/api/event`
- PTY connection limits and expiry
- Exact permission reply options
- Session/project attachment flow details
- Rate limits on concurrent PTY sessions
- `/api/experimental/usage/limits` endpoint availability

---

**Branch**: `research/opencode-api-remote`  
**File**: `/tmp/opencode/wf/opencode-api-remote/docs/research/opencode-api-remote.md`
