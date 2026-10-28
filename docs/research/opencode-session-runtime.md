# OpenCode Session Runtime Behavior — Research Findings

Verified against the live opencode service (v2.1.4) on the host, 2026-10-28.
All probes ran on throwaway sessions titled `test-*` (created and deleted by the
probe itself); the user's real sessions were read-only (list metadata only).

These facts are inputs to the v1 spec (map #1, ticket #8): multi-client safety,
no-TUI reactivation, SSE event names, and the `--session` resume flag.

## Environment

- Service: `http://127.0.0.1:49374` (process `opencode serve --service`), v2.1.4
- Auth: HTTP Basic, user `opencode`, password from `~/.config/opencode/service.json`
- Probe setup: one throwaway session bound to a real project directory,
  two separate curl connections ("client 1", "client 2"), a global SSE
  subscription started before the first prompt, tiny prompts
  (`Reply with exactly: one` / `two`, local model).

## Probe 1 — Multi-client send (two clients, same session)

Client 1 posted a prompt; while that turn was running, client 2 posted a second
prompt to the **same session**.

- Both requests returned 200 (no 409). Each prompt is an inbox item:
  `{"id":"msg_…","sessionID":"ses_…","type":"user","payload":{"text":"…"},"delivery":"steer"}`
  — default delivery is **`steer`** (queued/steered, not rejected).
- Per-session event sequence (durable `seq` per session aggregate):

```
1 session.inbox.enqueued      (prompt 1)
2 session.execution.started
4 session.inbox.delivered
5 session.step.started
6 session.reasoning.started … 7 text … 11 session.step.ended
12 session.execution.succeeded
13 session.inbox.enqueued     (prompt 2, queued while turn 1 ran)
14 session.execution.started
… 15 delivered … 22 session.step.ended
23 session.execution.succeeded
```

- `GET /api/session/:id/inbox` was empty mid-run (drained into executions).
- Final `GET /api/session/:id/context` (flat list, `type` = `user` / `assistant`
  / `idle{outcome}`): `user, assistant("one"), idle(succeeded),
  user, assistant("two"), idle(succeeded)` — both turns ran **in order, to
  completion, without corruption**.

**Verdict: safe.** Sending from a second client (or the app "at any time")
enqueues a `steer` item; the agent executes turns sequentially. This is the
mechanism behind the #6 decision "input always enabled".

## Probe 2 — Reactivation without a TUI

The probe session was created via `POST /api/session` and **never had a TUI
attached**. Both prompts were processed to completion
(`session.execution.succeeded` ×2, assistant texts `one` / `two`).

**Verdict: confirmed.** The agent resumes and completes turns for a session
with no TUI attached — external/manual sessions remain fully usable after
their TUI window closes (#6 relies on this).

## Probe 3 — SSE events

- Subscription endpoint: **`GET /api/event?types=<csv>`**
  (operationId `event.subscribe`). The `types` query param accepts a CSV of
  event names; the full enum is served in the service's OpenAPI spec.
- Frame format (no `event:` line — the type is inside the JSON):
  `data: {"id":"evt_…","created":…,"type":"<event>","data":{…},"durable":{"aggregateID":"<sessionID>","seq":N,"version":1}}`
- Observed live during the two-turn probe (full list, in order):
  `server.connected`, `session.inbox.enqueued`, `session.execution.started`,
  `session.instructions.updated`, `session.inbox.delivered`,
  `session.step.started`, `session.reasoning.started/.delta/.ended`,
  `session.text.started/.delta/.ended`, `session.step.streamed`,
  `session.step.ended`, `session.usage.updated`, `session.execution.succeeded`.
- Mapping for the three v1 notifications (#6):
  - turn started → `session.execution.started`
  - turn ended → `session.execution.succeeded` / `.failed` / `.interrupted`
    (`.succeeded` observed live; `.failed`/`.interrupted` from the spec enum)
  - permission requested → `permission.asked` (answered via
    `permission.replied`); from the spec enum — a tiny no-tool prompt does not
    raise one live.
- `session.idle` exists in the spec enum but was **not observed** for an
  API-driven session; drive "turn ended" off `session.execution.*`, not idle.
- `durable.seq` increments per session aggregate → the bridge can detect gaps
  per session on a single shared `/api/event` stream.

## Fact — `GET /api/session/active` scope

While the probe session was executing, `/api/session/active` listed **only**
the user's TUI-attached session (`{"ses_…":{"type":"running"}}`); the
API-created session never appeared (mid-run and after).

**Verdict:** the active list reflects foreground (TUI-attached) sessions, not
API-driven ones. For v1 every app-visible session is TUI-based
(app-launched window or manual TUI), so the list-based "active" indicator
works; notifications should still be driven from `session.execution.*` events.

## Probe 4 — `opencode --session <id>`

`opencode --help` (v2.1.4):

```
--continue, -c          Continue the last session
--session, -s string    Session ID to continue, or to create if it does not exist
```

Flag verified in the CLI. The resume-in-a-new-TUI-window behavior is
user-verified (reopening a closed session per #6 = bridge opens
`opencode --session <id>`).

## Session API endpoints (from the live OpenAPI spec, 130 paths)

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/session` | List sessions |
| POST | `/api/session` | Create session (`title`, `location:{directory}`, `agent`, `model`, `permissions`, …) |
| GET | `/api/session/active` | List active (TUI-attached) sessions |
| GET | `/api/session/:sessionID` | Get session |
| DELETE | `/api/session/:sessionID` | Delete session |
| PATCH | `/api/session/:sessionID` | Update session |
| POST | `/api/session/:sessionID/fork` | Fork session |
| POST | `/api/session/:sessionID/agent` | Switch agent |
| POST | `/api/session/:sessionID/model` | Switch model |
| POST | `/api/session/:sessionID/move` | Move session |
| POST | `/api/session/:sessionID/prompt` | Send message (`{text, delivery, resume, files, agents, skills}`) |
| POST | `/api/session/:sessionID/interrupt` | Interrupt execution |
| POST | `/api/session/:sessionID/background` | Background tools |
| POST | `/api/session/:sessionID/shell` | Run shell command |
| POST | `/api/session/:sessionID/compact` | Compact session |
| GET | `/api/session/:sessionID/context` | Get context (messages + idle states) |
| GET | `/api/session/:sessionID/diff` | Get file diffs |
| GET | `/api/session/:sessionID/inbox` | List inbox |
| DELETE | `/api/session/:sessionID/inbox/:inboxID` | Cancel inbox item |
| PATCH | `/api/session/:sessionID/inbox/:inboxID` | Update inbox item |
| GET | `/api/experimental/session/:sessionID/log` | Per-session log (SSE) |
| POST | `/api/session/:sessionID/view` | Mark idle as viewed |
| GET | `/api/event?types=…` | Global SSE subscription (`event.subscribe`) |

## Auth details

```bash
P=$(jq -r .password ~/.config/opencode/service.json)
curl -s -u "opencode:$P" http://127.0.0.1:49374/api/session
```

Bearer auth is rejected (401); use Basic. Session IDs look like
`ses_<base62-ish>`; messages `msg_…`; events `evt_…`.
