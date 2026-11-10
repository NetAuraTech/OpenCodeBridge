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

## Retry / error lifecycle (provider 429 + terminal failure) — the wire shapes

Probe for issue #154. Every *observed* claim below was verified live against
the running service (`opencode serve --service`, v2.2.7,
`http://127.0.0.1:49374`, Basic auth from `~/.local/state/opencode/service.json`)
on 2026-11-10. What could not be observed live is collected and labelled under
**Assumptions** at the end of the section. Probes ran on throwaway sessions
bound to a real project directory; all deleted afterwards. The model was the
live session's own `amd/Qwen3.8-27B` (the gateway that produces the 429s),
plus one forced-failure session bound to an unavailable model.

Artifacts — raw service JSON, unreshaped (trimmed to the interesting
message(s) only), so slice 02's HTTP-service tests replay them through the real
parser:

| fixture | read | shows |
|---|---|---|
| `app/test/fixtures/retry/message_429_inflight_attempt_2.json` | `GET /message` mid-retry | assistant carrying `retry.attempt: 2` (429), `content: []` |
| `app/test/fixtures/retry/message_429_inflight_attempt_3.json` | `GET /message` mid-retry | **same** assistant message id, now `retry.attempt: 3` |
| `app/test/fixtures/retry/message_429_succeeded.json` | `GET /message` after recovery | same assistant, **no** `retry`/`error`, `finish:"stop"`; `idle` `outcome:"succeeded"` |
| `app/test/fixtures/retry/message_failed_model_unavailable.json` | `GET /message` after a forced failure | `idle` `outcome:"failed"` + `error`; **no assistant row** |
| `app/test/fixtures/retry/event_retry_scheduled.json` | one `/api/event` frame | the `session.retry.scheduled` event payload (see "The app must not depend on a retry event") |

### The shape (from the service's `openapi.json`, confirmed against the live reads)

- **`retry` lives on the assistant message, not in an event.**
  `Session.Message.Assistant.retry = {attempt, at, error}` — all required,
  `attempt > 0`. `at` is a **millisecond epoch** of the *scheduled* next
  attempt.
- **`error` is `Session.StructuredError`**: `{type, message, status?,
  response?: {body}, retryAfterMs?}`. On a 429 the upstream body rides in
  `retry.error.response.body` as a JSON string and `status` is the HTTP status:
  ```json
  { "type": "provider.rate-limit",
    "message": "Provider request failed with HTTP 429: {…}",
    "status": 429,
    "response": { "body": "{\"detail\":{\"error\":{\"message\":\"Model API rate limit exceeded; please retry later\",\"type\":\"rate_limit_error\",\"code\":\"token_concurrency_rate_limit_exceeded\"}}}" },
    "retryAfterMs": 1000 }
  ```
  Two `code`s were observed live on the AMD gateway:
  `token_concurrency_rate_limit_exceeded` and `token_rate_limit_exceeded`.
- **The assistant message also carries an `error` of the same type** for the
  terminal failure; `retry` and `error` are never both set on one message.
- **The `idle` message** (the turn boundary) carries
  `outcome ∈ {succeeded, failed, interrupted}` and an optional `error`.

### Q1 — one message, mutated in place (not one row per attempt)

Verified by polling `GET /message` through a live 429 window. On one session
the assistant message id `msg_1c68f42c7001H8MgETik6BH3y4` was read
consecutively carrying `retry.attempt: 2`, then `retry.attempt: 3` (identical
error payload), then — after recovery — **no** `retry` and `finish:"stop"`. A
second session drove `attempt` 2→3→4→5 on one message. **Verdict: in-place.**
`retry.attempt` climbs N→N+1 on a single assistant row; the app tracks
"attempt N of …" off that one message id, not by counting rows.

### Q2 — retried-then-succeeded

Verified: after a retry lands, the same assistant message is read with **no
`retry` and no `error`**, `finish:"stop"`, populated `content`, and the turn's
`idle` carries `outcome:"succeeded"`. (`message_429_succeeded.json`.)

### Q3 — where the final failure lives (the distinction slice 02 must preserve)

- **Non-retryable** failure (unavailable model — the forced setup): the final
  `error` lands on the **`idle`** message with `outcome:"failed"` and **no
  assistant row is written** (`message_failed_model_unavailable.json`).
- **Exhausted-retry** failure (a 429 that never recovers): **not observed
  live.** **Assumption** (schema-supported): the final `error` lands on the
  **assistant** message (with `retry` cleared once exhausted, since
  `retry`/`error` are never both set), the turn's `idle` carries
  `outcome:"failed"`, and there **is** an assistant row. Slice 02 must not
  conflate the two: an idle-only error means no assistant content was ever
  produced; an assistant error means content was attempted.

### Q4 — the TUI's terminal line

- **In-flight** (a retried turn, while `retry` is set): the TUI's own render
  (confirmed in the opencode v2.2.7 binary) is
  `⚠ ` + (`Retrying in {d}s` while `retry.at - now > 0`, else
  `Retry due`) + ` · attempt ` + `{retry.attempt}` + ` · ` +
  `{retry.error.message}` — e.g. the issue's
  `Retry due · attempt 3 · Provider request failed with HTTP 429: {…}`. The app
  can reproduce this straight from `retry`.
- **Terminal "no automatic retry left" wording: not observed.** No live turn
  exhausted its retries on this model (Q6), so the exact terminal string was
  **not observed**. The forced-failure setup used instead — a session bound to
  an unavailable model (`amd/qwen3.8-flash-next`) that fails before any
  provider request with `provider.no-route` ("Model unavailable: …",
  non-retryable) — produces a terminal `idle {outcome:"failed", error}` that
  the TUI renders from the message's `error`/idle `error` **verbatim**; no
  extra "no automatic retry left" copy is appended. **Assumption:** the app
  therefore renders the terminal failure from `error.message` (as the
  in-flight line does) and does not need to invent a "no automatic retry
  left" string.

### Q5 — the service auto-retries; it does not wait for the user

The 429 is absorbed by the **service's own** retry loop: it schedules the next
attempt itself from `retry.error.retryAfterMs` (observed `1000`; the real gap
to the next attempt was 4–11s including the provider's response time) and no
new user prompt is required. `attempt` climbed 2→3→4→5 with nobody re-prompting.
**Verdict: the service re-attempts on its own** — the TUI's "please retry
later" refers to the *provider's* backoff window, not a manual re-prompt of the
session.

### Q6 — the model does retry (it does not die at once)

The `retry` field is set on the assistant message across many attempts, and
every 429 window observed this session recovered to `succeeded` even under
heavy concurrency (up to 64 simultaneous AMD prompts). **Verdict: it retries.**
The 429s originate upstream at the AMD gateway (a shared API key hit at
concurrency); opencode's retry layer rides them out, so the app's job is to
surface the in-flight retry and the (rare) exhausted case.

### The app must not depend on a retry event

`session.retry.scheduled` **does exist** in the service's full event enum
(`{sessionID, assistantMessageID, attempt, at, error}` — see
`event_retry_scheduled.json`), but it is **not** among the event types the app
consumes (`session.execution.*`, `session.step.*`, `session.text/reasoning.*`,
`session.tool.*`, `session.usage.updated`, `session.compaction.*`, and the
session-lifecycle events). And no `session.idle` event is emitted at all — the
idle boundary only appears in the `/message`/`/context` reads. **Verdict:** the
app drives retry + terminal state from the **message reads**, not from a retry
event. (Confirms the issue's "the app must not depend on one" — and refines it:
`session.retry.scheduled` is a real, usable event if a later slice wants to
*live*-update the attempt counter without re-reading the message.)

### What the bridge discards today (the bug slices 02–04 fix)

`opencode_http_service.dart` → `_messageFrom`:
- for an `assistant` item it keeps only the `content` parts (text / reasoning /
  tool) + `tokens` + `time` — it drops `retry` and `error`;
- for an `idle` item it returns only `{id, role}` — it drops `outcome` and
  `error`.

So a retried turn looks like a slow agent and an exhausted/failed turn looks
like a clean stop — exactly the reported symptom. This section is the reference
those slices cite:

- **Slice 02** (#155, bridge carries `retry` / terminal `error` / idle
  `outcome` in `SessionMessage`): parses `retry` / `error` (assistant) and
  `outcome` / `error` (idle) and replays the fixtures above through
  `_messageFrom`. It must preserve the Q3 distinction — an idle-only error (no
  assistant row) is a different case than an assistant error.
- **Slice 03** (#156, app shows the live provider retry, attempt N): reads
  `retry.attempt` + `retry.error.message` off the retried assistant message and
  renders the in-flight line **verbatim as the TUI does** (Q4) —
  `⚠ {Retrying in Ns|Retry due} · attempt {n} · {error.message}` — so the app
  needs no invented copy.
- **Slice 04** (#157, app reads an exhausted retry as a failed turn, not a
  quiet stop): keys off the turn's terminal state — `idle.outcome:"failed"`
  (with the `error` on the `idle` for the non-retryable case, or on the
  assistant for the exhausted-429 case, assumption A1) — so an exhausted turn
  renders as a failed turn instead of a clean stop.

### Assumptions (labelled, per the probe brief)

- **A1.** A *true* exhausted 429 terminal: `retry` cleared + terminal `error`
  on the assistant, `idle.outcome:"failed"`. (Only the non-retryable terminal
  was forced; the exhausted one was never observed on this model.)
- **A2.** The 429 retry budget is finite (the retry loop eventually gives up).
  A generous budget was observed (≥5 attempts; every window recovered) and the
  opencode v2.2.7 binary shows the provider retry is a bounded Effect
  *suspended retry schedule* with an explicit `…RetrySchedule exhausted`
  terminal path — so an exhausted turn is a real state, it just needs a 429 that
  holds past the budget (which this gateway never produced live). The exact
  attempt cap was not measured.
- **A3.** `session.execution.failed` fires for an exhausted turn. It was
  present in the service's OpenAPI event enum and in prior probes' spec, but
  this probe's event stream showed only `started`/`succeeded` for the 429 turns
  (all recovered), so it was not re-confirmed live here.

