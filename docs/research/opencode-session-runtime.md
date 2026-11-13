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

## Session list ordering (position / pin)

Probe for issue #204 — where a user-controlled display order for the home list
can live. Every *observed* claim below was verified live against the running
service (`opencode serve --service`, v2.2.7, `http://127.0.0.1:49374`, Basic
auth from `~/.local/state/opencode/service.json`) on 2026-11-12, on a throwaway
session titled `test-order-204` (created, probed, deleted). The service's own
`openapi.json` confirms the event-type names; no other probe re-derived what
#204 already established. The deliverable is this section only — no UI, no
runtime behaviour change.

### The service offers no order field (re-stated from #204)

`Session.Info` has no `position`/`order`/`rank`/`pin`; the only ordering knob on
`GET /api/session` is its pagination (`limit` defaulting to the newest 50,
`order: asc|desc`, `search`, `parentID`, `archived`, `directory`, `project`,
`subpath`, `cursor`). The service's default page order is **`time.updated`
desc**, not `created`; the bridge requests `order=desc` and re-sorts the merged
rows by `created` (`SessionsBackend.list()`), which is the sort the app sees
today. The free hook is `Session.Metadata` — an unconstrained
`{"type":"object"}` the service does not itself use for ordering (the TUI sorts
its own list independently and is unaffected).

### Q1 — PATCH `metadata` replaces the whole object (not a merge)

A session's `metadata` is **replaced on every PATCH**, not deep-merged. The
probe session was stepped through:

```
PATCH {"metadata":{"position":7}}      -> 204 ; GET metadata -> {"position":7}
PATCH {"metadata":{"other":1}}         -> 204 ; GET metadata -> {"other":1}
PATCH {"metadata":{"position":8}}      -> 204 ; GET metadata -> {"position":8}
```

The second PATCH dropped `position` and the third dropped `other` — each PATCH
is the **entire** new object. **Verdict: last-write-wins on the whole object.**
Consequence: a `position` write from the bridge must read-modify-write (read the
current metadata, set `position`, PATCH the whole object back), and two
concurrent writers (two app instances in client mode, or the app and any future
non-app consumer of `metadata`) clobber each other's keys. The bridge owns the
only real consumer today, so this is a non-issue in practice — but it rules out
"coexisting keys" assumptions and is the single reason option A's write path
must be read-modify-write.

### Q2 — no practical metadata size cap

Metadata of every size probed was accepted (204) and read back intact:

| payload size | HTTP | readback |
|---|---|---|
| ~0.5 KiB | 204 | `pad_len=512` |
| ~1 KiB | 204 | `pad_len=1024` |
| ~4 KiB | 204 | `pad_len=4096` |
| ~10 KiB | 204 | `pad_len=10240` |
| ~64 KiB | 204 | `pad_len=65536` |
| ~1 MiB | 204 | `pad_len=1048576` |
| ~4 MiB | 204 | `pad_len=4194304` |

**Verdict: no cap in the working range.** A position int (or a whole per-session
order block) is trivially small; size is a non-factor. (No artificial limit was
observed, so a future service version adding one is an unverified assumption,
not a fact.)

### Q3 — metadata is persisted in the durable store (survives a restart)

The service's state is a WAL-backed SQLite database
(`~/.local/share/opencode/opencode.db`, the file held open by the service
process), table `session_v2` with a dedicated `metadata` column. Immediately
after `PATCH {"metadata":{"position":7}}`, a **read-only** read of the store on
disk shows the exact value, alongside the session's `event_sequence` row (the
durable seq the event stream advances):

```
table=session_v2
  id        = ses_e2f38210cffewmhZbBK6WCbQVq
  title     = test-order-204
  metadata  = {"position":7}
  time_updated = 1794504320780
  ...
table=event_sequence
  aggregate_id = ses_e2f38210cffewmhZbBK6WCbQVq
  seq          = 16
```

**Verdict: persisted.** Metadata lives in the same durable store as the rest of
the session (the row is on disk the moment the PATCH lands, before any WAL
checkpoint), so it survives a service restart. The live restart itself was not
run against this host's shared service (it hosts real, in-flight sessions) — the
on-disk store read is the verification, per the ticket's "verify against the
state dir".

### Q4 — `search` does not reach into metadata

`GET /api/session?search=` searches the session's **title**, not its metadata.
With a distinctive token stored *only* in `metadata`:

| query | rows | our session present |
|---|---|---|
| `search=<token in metadata>` | 0 | no |
| `search=<session title>` | 1 | yes |
| `search=<nonsense>` | 0 | no |

**Verdict: no.** `position` in metadata is invisible to search — expected, and
it means an ordered list can't be reached through the `search` param (the bridge
re-sorts the full page it already fetches, so this is irrelevant to the design).

### The live event (Q6 context — how the app learns of an order change)

A metadata PATCH emits `session.metadata.updated`, already in the bridge's
upstream event subscription (the bridge subscribes to the **full** type enum of
`GET /api/event`; this type is simply ignored by the hub today). Observed live:

```json
{
  "id": "evt_1d0cd88c9001FAgB4kEIYOCFzX",
  "created": 1794504493257,
  "type": "session.metadata.updated",
  "data": {
    "sessionID": "ses_e2f38210cffewmhZbBK6WCbQVq",
    "metadata": { "position": 3, "live": true }
  },
  "durable": { "aggregateID": "ses_e2f38210cffewmhZbBK6WCbQVq", "seq": 18, "version": 1 }
}
```

The payload carries the **full** metadata object (not a diff) and a durable
per-session `seq`. The app already patches its cached home-list rows in place
from live events (title, the active dot) without a refetch — this event is the
same shape of update, so a position change merges into the cached list with no
refetch: read `data.metadata.position`, update the row, re-sort. For
option B the bridge emits an equivalent **bridge-native** event (see wire) on
the same fan-out; the app-side merge is identical either way.

### A/B/C — where the order lives

The decision point is which component owns the order and how it reaches the
app. ADR-0001 is the governing constraint: the bridge is the app's **single**
API, the app never talks to the opencode service directly, and the bridge
re-emits upstream events **verbatim** onto `GET /api/events` while
bridge-native events (no durable seq) are multiplexed onto the same stream.

One fact reframes the choice and is worth stating plainly, because it is not
obvious from the service side: **the home list is not one service's list.**
`CompositeOpencodeService.listSessions()` merges the host's sessions with every
**running orb's** sessions into a single list, which `SessionsBackend.list()`
then sorts by `created` desc. A session's order must therefore span host and
orb rows simultaneously (and a session moved host↔orb keeps its id — ADR-0006 —
so it stays in the list it was ordered in). This is the decisive argument for
a bridge-local store.

- **A — order in the opencode `metadata`.** Write
  `metadata.position` (or `{"pinned":bool}`) on each session, per service; the
  bridge sorts merged rows by `(position ?? +∞, time.updated desc)`.
  *Pros:* persisted service-side, a real live SSE event already reaches the
  bridge, and every bridge that shares a service sees the same order.
  *Cons (the ones that decide it):* the order **does not span services** — each
  service (host and each orb) keeps its own `position`, so the bridge must
  stitch per-service orders into the merged list with no natural global
  coordinate, and a two-bridge setup (server + client bridge over the same
  host) gets two independent `position` namespaces. The write is
  read-modify-write (Q1: whole-object replace), so a drag that reorders N rows
  is N sequential PATCHes with no atomicity, and a lost PATCH mid-drag leaves a
  half-ordered list. And any `position` write clobbers `metadata` (Q1) — fine
  while the bridge is the only consumer, fragile the moment anything else
  writes there.

- **B — a bridge-local order store.** The bridge owns a `sessionID → position`
  map, persisted in an app-owned file, exposed through its own route and
  bridge-native event. *Pros:* **one order across host + orb rows** (it keys on
  session id, which the composite list and the move primitive both preserve);
  **atomic** reorder (the bridge rewrites the whole map in one write — a drag is
  one operation, not N network PATCHes, and a crash can't leave a half-ordered
  list); full control of semantics and no dependence on service `metadata`
  behaviour (Q1's replace semantics become irrelevant). *Cons:* the order is
  **per-bridge** (two bridges = two orders) — the same limitation as A in
  practice, so not a disqualifier; and the map must be kept tidy (drop a session
  on its `DELETE`, which the bridge already detects and emits `session.closed`
  for; it survives host↔orb moves automatically because the id is preserved, so
  cleanup is deletion-only).

- **C — sort modes + pin only (no drag).** The user picks a sort
  (`recent activity` / `created` / `pinned first`) plus per-session pinning,
  via A or B. The smallest step that may satisfy the request. *Cons:*
  `recent activity` needs `time.updated`, which the `Session` home-list row does
  **not** carry today (only `created`) — so even C, in its natural form,
  requires surfacing a per-row freshness field, i.e. a small contract change
  regardless of the ordering decision.

### Recommendation

**B — a bridge-local order store — with `pinned` as the first-shape UX (C's
minimal step), the `position`-int store already in place so full drag is a
non-breaking extension.**

The reasoning, against the repo's conventions:

1. **ADR-0001 — the bridge is the single API and the app never talks to the
   service.** Order is an app-level display concern, not service data. The
   bridge already composes the home-list rows (`SessionsBackend.list()` already
   re-sorts the merged set) and is the only component that sees the *complete,
   merged* host+orb list. Owning the order there is the one place that can order
   the list the app actually renders — option A cannot, because the merged
   list spans services that A's per-service `position` never covers. This is the
   same "the bridge is the sole orchestrator" position ADR-0001 and ADR-0006
   already take for orb moves.

2. **Atomicity and no dependence on service semantics.** B rewrites one map in
   one local write — a drag of N rows is atomic and crash-safe — whereas A's
   read-modify-write + N PATCHes (Q1) is non-atomic and couples the feature to
   the service's whole-object-replace behaviour, which is an implementation
   detail the bridge should not build on. B makes Q1, Q2, and Q4 irrelevant to
   correctness.

3. **It reuses what the bridge already has.** The `session.closed` hook for
   cleanup, the `EventHub.emit` fan-out for the live event, the composite
   service's id-keyed routing, and ADR-0006's id-preserved moves all already
   exist; B wires into them. A would instead put app display state *inside* the
   service's `metadata`, where the service does not own it and where a TUI or any
   future consumer could collide.

What B does **not** get, and why that is acceptable: a shared order across two
bridges. That is not a requirement the app has today (server mode is one bridge
per host; client mode is a client of *that* bridge), and A offers no more in the
one-bridge-per-host reality. The cost (per-bridge order) is symmetric with A's
worst case.

The store is a **position int, not just a pin flag**: the app starts with a
pin-only UI (C's "pinned first + created") reading `position != null` as
*pinned, in `position` order*, and `position == null` as *unpinned, newest
created first* — the exact shape that makes a later full-drag reorder a
purely-app-side extension (write fractional/integer positions between rows) with
**no bridge route, event, or store-shape change**.

### The wire (option B), ready to cut into slices

- **Store:** the bridge persists a `sessionID → position:int` map in an
  app-owned file (the same app-owned-file pattern as the tunnel's
  `~/.config/opencodebridge/`, CONTEXT.md). Position `null`/absent = unpinned.
  On load, drop entries whose id is no longer in the merged list (deletion
  cleanup); the map follows a session across host↔orb moves for free (id
  preserved, ADR-0006).

- **Read:** no new read route. `SessionsBackend.list()` already returns the
  merged, sorted rows; it becomes the sort's owner:
  `rows.sort` by *(pinned first: `position != null` before `null`, then
  `position` ascending when both pinned, then `created` descending as the stable
  fallback)*. The `Session` home-list row gains the field the UI needs to
  render and re-merge — a `pinned` bool (and, for the "recent activity" sort
  mode, a `time.updated` int, which it does not carry today). Adding fields to
  `Session.toJson`/`fromJson` is the only contract change and is additive.

- **Write (the one new route):** `PATCH /api/sessions/{id}/order`, body
  `{"position": <int|null>}` (`null` unpins). This is a **bridge-native**
  write (it touches the bridge's own store), *not* a pass-through to the service
  — consistent with ADR-0001's "the app talks only to the bridge". Response
  `204`. Unknown session → `404`; malformed body → `400` (the existing
  `_sessionCommandIn` path already yields the `(id, sub)` pair, so this slots in
  beside the `/api/sessions/{id}/…` command routes).
  - First-slice (pin) shape: `{"position": 0}` pins, `{"position": null}`
    unpins — pin order is "pin time" (first pinned highest).
  - Extension (drag) shape: `{"position": <float/int>}` sets an explicit order;
    a reorder posts the new positions for the affected rows (or a batched
    `PATCH /api/sessions/order` variant if per-row N is too chatty) — same store,
    same event, no schema change.

- **Event (bridge-native, on the existing fan-out):** `session.order.changed`,
  `data: {"sessionID": <id>, "position": <int|null>}`, **no durable seq** (a
  bridge-native side-effect, exactly the class of `session.closed` and
  `session.turn.cancelled` in `bridge_event.dart`). Emitted from the route after
  the store write, through the same `EventHub.emit` the app's home-list already
  consumes — so the app merges `data.position` into its cached row and re-sorts
  with **no refetch**, identical to how it already merges `session.metadata.updated`
  and title updates.

- **What the app does not do:** it never reads or writes the service's
  `metadata` for order (option A's whole-object-replace, Q1, stays out of the
  app's path entirely). If a future slice wants a *cross-bridge* shared order,
  that is a separate decision (a service-side or tunnel-synced store), out of
  scope for this ticket.

### Assumptions (labelled, per the probe brief)

- **O1.** The `session_v2` table (and its `metadata` column) is the durable
  store that survives a service restart. Verified by read-only on-disk read; the
  live restart was not run against this host's shared service (real sessions in
  flight). A service that changed its persistence would be a service incident,
  not an app concern — and option B does not depend on it at all.
- **O2.** `metadata` has no practical size cap (no cap observed to 4 MiB).
  Unverified for future service versions; irrelevant to a position int.
- **O3.** The bridge is the sole consumer of `Session.Metadata`. True today
  (the service and the TUI do not use it for ordering); if a future consumer
  appears, option B is unaffected (it never touches `metadata`), option A
  would need to coordinate.

## Session archiving

Probe for issue #228 — archiving a session from the app (hide it from the home
list without deleting it, and come back to it later) versus the only exit today,
the destructive `DELETE`. Every *observed* claim below was verified live against
the running opencode service the app's bridge wraps (an `opencode serve` on this
box, **v2.1.4**, `http://127.0.0.1:4097`, Basic auth) on 2026-11-13, on a
throwaway session titled `test-archive-228` (created, probed, deleted). The
service's own `openapi.json` confirms the parameter set and the event names.
The deliverable is this section only — no UI, no runtime behaviour change.

One environment fact up front, because it shapes Q1 and the version notes: the
tasking assumed the in-orb build pin was **v2.2.7** (matching the host service
the issue probed on 2026-11-12). It is not — `opencode --version` and
`GET /api/info` both report **v2.1.4** in this container, and the binary
(`/usr/local/bin/opencode`, a single Bun-compiled executable) carries the
archiving feature in full (both durable events, the `time_archived` migration on
both `session` and `project`, the TUI's `session.archived` local-store reducer,
and the OpenAPI `archived` param). The Q2–Q5 endpoint behaviour is
version-independent and identical to the host's v2.2.7 findings in the issue;
the only version-dependent detail is *how* the TUI hides archived sessions (Q1).
The raw JSON below is unreshaped, from the v2.1.4 service, so it can be replayed
against the real parser.

### Q1 — the TUI's session surfaces (hidden by default; the CLI list is not)

This is the visible side effect of the feature: does archiving from the app also
hide the session from the user's terminal? Two surfaces matter — the **TUI's
interactive lists** (the ones a person looks at) and the **CLI `opencode
session list`** (`<leader>l`).

The **TUI hides archived sessions from every interactive list by default**, and
no "show archived" toggle was found in either version:

- **v2.2.7 (host, the issue's probe — cited from the issue's binary read):**
  the "Open recent" menu (`ctrl+o`) queries
  `session.list({…, limit:50, order:"desc", parentID:null, archived:!1})`; the
  "Switch session" palette filters its local list by
  `time.archived === void 0`; the new-session "continue latest" heuristic, the
  "recently used sessions" dialog, and the session-picker for a directory all
  query `archived:!1`. (`!1` is minified `false`.)
- **v2.1.4 (this in-orb binary — confirmed here):** the TUI's session list is
  built the same way behaviourally, but the filter is applied at the list
  query rather than as a raw `archived:!1` literal: the list builder applies a
  `where` on `time_archived` —
  `where(x?.archived ? void 0 : <predicate>(time_archived))` — i.e. *constrain
  the list to exclude rows whose `time_archived` is set* unless an `archived`
  argument is passed. (The helper is minified, so the exact predicate identity
  is not isolated; the behaviour — hide archived by default — matches the
  v2.2.7 `archived:!1` surfaces above and the OpenAPI `archived` param.) The
  same binary also carries the `session.archived` / `session.unarchived`
  local-store reducer (`case "session.archived": …set "time","archived"…`), so
  a TUI that is open while a session is archived updates its own list from the
  event.

The **CLI `opencode session list` (`<leader>l`) does NOT filter** — it queries
`session.list({project, parentID:null, order:"desc", limit})` with **no**
`archived` param, so archived rows show. (Verified on the host's v2.2.7 binary
per the issue; the in-orb v2.1.4 binary carries the same `session.list`
operation and the same `time_archived`/event machinery, though the exact CLI
list string was not isolated here — see Assumptions.)

**Verdict:** archiving a session from the app **hides it from the user's TUI
interactive lists** (the visible side effect), but **not from the CLI
`opencode session list`**. The app and the TUI therefore agree on the default
(both hide archived), and there is no service-side "show archived" knob the app
would need to discover — the app implements its own archived surface. This is a
soft-hide, consistent with Q2: the session is fully usable while archived.

### Q2 — the archived session's own API surface (fully usable while archived)

While the probe session was archived, its own endpoints all worked, and a new
turn ran to completion **without unarchiving it**:

```
POST /api/session                -> 200  (create, title "test-archive-228")
PATCH /api/session/{id} {"archived":true}  -> 204
GET  /api/session/{id}          -> 200  (time.archived set)
GET  /api/session/{id}/message  -> 200  (empty, data:[])
POST /api/session/{id}/prompt   -> 200  (a new turn runs while archived)
GET  /api/session/{id}          -> 200  (time.archived STILL set)
PATCH /api/session/{id} {"archived":false} -> 204
GET  /api/session/{id}          -> 200  (time.archived absent)
```

Detail read, unarchived (baseline) — note **no** `time.archived` key:

```json
{"data":{"id":"ses_e2a94e24cffeEAtHtWl5RB1yo2","projectID":"852276104c2ebb2ed449cbaa3cc940e4eec565e9","cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1794581929401,"updated":1794581929401},"title":"test-archive-228","location":{"directory":"/workspace"}}}
```

Detail read, archived — `time.archived` present (unix-ms):

```json
{"data":{"id":"ses_e2a94e24cffeEAtHtWl5RB1yo2","projectID":"852276104c2ebb2ed449cbaa3cc940e4eec565e9","cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1794581929401,"updated":1794581973085,"archived":1794581973085},"title":"test-archive-228","location":{"directory":"/workspace"}}}
```

Message read while archived (empty — the turn had not run yet):

```json
{"data":[],"cursor":{"previous":null,"next":null}}
```

Prompt accepted while archived (a `steer` inbox item, same shape as an
unarchived prompt):

```json
{"data":{"id":"msg_1d56c51ba001Zz8As66o8X5XBV","sessionID":"ses_e2a94e24cffeEAtHtWl5RB1yo2","time":{"created":1794582008251},"type":"user","payload":{"text":"Reply with exactly: ok"},"delivery":"steer"}}
```

Detail read *after* the turn completed — the turn ran to
`outcome:"succeeded"` and `time.archived` is **still set** (the turn did not
unarchive it):

```json
{"data":{"id":"ses_e2a94e24cffeEAtHtWl5RB1yo2","projectID":"852276104c2ebb2ed449cbaa3cc940e4eec565e9","cost":0,"tokens":{"input":3556,"output":3,"reasoning":0,"cache":{"read":1792,"write":0}},"outcome":"succeeded","time":{"created":1794581929401,"updated":1794582011937,"idle":1794582011939,"archived":1794581973085},"title":"test-archive-228","location":{"directory":"/workspace"}}}
```

Detail read after unarchiving — `time.archived` is **absent** from the JSON
(in the v2.2.7 host read it is `null`; either way, absent-or-null = not
archived):

```json
{"data":{"id":"ses_e2a94e24cffeEAtHtWl5RB1yo2","projectID":"852276104c2ebb2ed449cbaa3cc940e4eec565e9","cost":0,"tokens":{"input":3556,"output":3,"reasoning":0,"cache":{"read":1792,"write":0}},"outcome":"succeeded","time":{"created":1794581929401,"updated":1794582081565,"idle":1794582011939},"title":"test-archive-228","location":{"directory":"/workspace"}}}
```

**Verdict: fully usable (soft-hide).** An archived session answers its detail,
message, and prompt endpoints normally, and a turn runs to completion without
unarchiving it. Two consequences for the app: (a) the app **can open an
archived session straight into the structured view** — the per-id routes work
while archived, so no unarchive-first dance is needed; (b) the app **need not
refuse to archive an active/mid-turn session** — the turn keeps running
invisibly and is still observable per-id (the active dot and turn footer still
work). Whether the app *warns* before archiving an active session is a product
choice (Q7), not a service constraint.

### Q3 — `search` / `directory` / `project` compose independently with `archived`

With the probe session **archived**, each list param composed with `archived`
independently (the probe's own directory is `/workspace`; its project id is the
`8522761…` value above):

| query | rows | probe present? |
|---|---|---|
| *(no params — default)* | 1 | yes |
| `archived=false` | 0 | no |
| `archived=true` | 1 | yes |
| `search=test-archive-228` | 1 | yes |
| `search=test-archive-228&archived=false` | 0 | no |
| `search=test-archive-228&archived=true` | 1 | yes |
| `directory=/workspace` | 1 | yes |
| `directory=/workspace&archived=false` | 0 | no |
| `directory=/workspace&archived=true` | 1 | yes |
| `project=8522761…` | 1 | yes |
| `project=8522761…&archived=false` | 0 | no |
| `project=8522761…&archived=true` | 1 | yes |

**Verdict: independent, not a conflict.** `search`, `directory`, and `project`
each compose with `archived` (an AND): the probe appears with no filter and with
`archived=true`, and is excluded by `archived=false` under every combination.
The default (no `archived` param) **includes archived rows** — the service does
not hide them on its own; a client that omits the param sees archived sessions.
This is why the home list must be filtered deliberately (the app, in the
recommendation), not accidentally.

### Q4 — orb sessions (the in-orb service is the confirmation)

The in-orb service **is** the confirmation: it is the same binary the host runs
(`/usr/local/lib/node_modules/@opencode/cli/bin/opencode.exe` resolves for both
the host's service and this container's service), reporting v2.1.4 here, and the
Q2/Q3 endpoints behave identically — the raw JSON above is the orb-side
evidence, taken against this box's own service. So the bridge's per-orb upstream
(the same `OpencodeHttpService` pointed at the orb's URL) will see the same
`time.archived` field and the same `archived` list param.

One bridge-side fact the flag depends on: `CompositeOpencodeService.listSessions()`
(app/lib/bridge/sessions/composite_service.dart, ~line 78) **re-builds every orb
row from `OpencodeSession`**, copying only `id`, `title`, `projectId`, `created`,
`location` (and stamping `orb`). It drops any field the `OpencodeSession` model
does not carry. So **the `archived` field must be added to `OpencodeSession`
*and* carried through this rebuild**, or an archived orb session would be
inconsistent with an archived host session (the host row hidden, the orb row
shown). Host rows are passed through as-is (no rebuild), so they need only the
model field.

### Q5 — persistence (the durable store)

`time.archived` lives in the WAL-backed SQLite store
(`~/.local/share/opencode/opencode.db` in this container; the isolated probe used
`/tmp/opencode-probe/data/opencode/opencode.db` so it never touched a shared
store), table `session_v2`, column **`time_archived`**. A **read-only** read of
the store on disk immediately after the PATCH shows the exact value, then `NULL`
after unarchiving (the live restart was not run — the on-disk store read is the
verification, the same posture #204's Q3 took for `metadata`):

```
table=session_v2   columns include: … time_updated, time_idle, time_viewed,
                    idle_outcome, time_compacting, time_archived, time_suspended …
while archived:    id=ses_e2a94e24cffeEAtHtWl5RB1yo2
                   time_archived = 1794582423589
after unarchive:   id=ses_e2a94e24cffeEAtHtWl5RB1yo2
                   time_archived = NULL
```

**Verdict: persisted.** The flag is a durable store column, on disk the moment
the PATCH lands (before any WAL checkpoint), so it survives a service restart.
The `time_archived` migration also adds the column to the **`project`** table —
project-level archiving exists too (`project.list` excludes archived projects
unless `archived=true`), but it is out of scope for this ticket.

### The live events (Q6 context — how the app learns of an archive)

A one-shot SSE capture on the in-orb service recorded **both** events live, each
with its durable per-session `seq`:

```json
{"id":"evt_1d56bc85d001gQCWO1vL6uW21A","created":1794581973085,"type":"session.archived","location":{"directory":"/workspace"},"data":{"sessionID":"ses_e2a94e24cffeEAtHtWl5RB1yo2"},"durable":{"aggregateID":"ses_e2a94e24cffeEAtHtWl5RB1yo2","seq":1,"version":1}}
```

```json
{"id":"evt_1d56d701d001zseSctCLBsONZF","created":1794582081565,"type":"session.unarchived","location":{"directory":"/workspace"},"data":{"sessionID":"ses_e2a94e24cffeEAtHtWl5RB1yo2"},"durable":{"aggregateID":"ses_e2a94e24cffeEAtHtWl5RB1yo2","seq":12,"version":1}}
```

Both are **durable** (`{aggregate:"sessionID", version:1}`), payload
`{"sessionID": "…"}` — a thin, id-only payload (unlike `session.metadata.updated`,
which carries the full object). The bridge's `EventHub` re-emits every upstream
event verbatim and the event service subscribes to the **full** type enum, so
**both events already reach the app's SSE stream today** — the app simply does
not handle the two types yet. No hub work is needed; the app just merges
`data.sessionID` into its cached row (set `archived` true/false) with no
refetch, exactly as it already merges title and the active dot.

### A/B — where the filter lives

The decision point is which component owns "the home list excludes archived,"
and how the flag reaches the app. ADR-0001 is the governing constraint: the
bridge is the app's **single** API, the app never talks to the opencode service
directly, the bridge re-emits upstream events **verbatim** onto
`GET /api/events`, and the wrapper is the stable contract the app consumes.

One framing fact differs from #204 and is worth stating, because it flips the
default intuition: **`archived` is a per-session, service-owned fact, not a
bridge display coordinate.** #204's order had to live bridge-local precisely
because a `position` is a *global ordering coordinate the service cannot hold*
across host+orb. `archived` is the opposite: it lives on the service's own row
(Q5) and each service filters its **own** rows, so service-side filtering
composes across host+orb for free. That removes the #204 "can't span services"
objection to service-side state — and it is the reason option A is at all
viable here.

- **A — the bridge filters.** `listSessions()` requests `archived=false` from
  the service; archived sessions are invisible to the app until an explicit
  "archived" list (the bridge also accepts `?archived=` on its own
  `GET /api/sessions`). *Pros:* one source of truth — the bridge decides what
  the home list is, so the app does not re-derive hide/show; the home-list route
  is self-describing. *Cons (the one that decides it):* `listSessions()` is the
  **seam**, and the same seam feeds two other consumers today —
  `SessionsBackend.exists()` (the reopen guard) and
  `SessionsBackend._defaultModel()` (the "copy the current model" heuristic).
  If the seam filters `archived=false`, an archived session fails `exists()`
  (the reopen guard says it doesn't exist) and `_defaultModel()` silently skips
  it. Filtering at the seam couples a *display* decision to every internal
  reader. To keep A safe the filter must be scoped to the home-list **route**
  only, with the seam still returning all sessions — at which point A's
  "one source of truth" mostly becomes "the route filters a faithful list,"
  i.e. B's wire plus a route param.

- **B — the app filters (the flag rides on every row).** `listSessions()` keeps
  returning **all** sessions; each row carries `archived: bool`; the app's home
  list renders `where(!archived)` by default, with an "Archived" surface for the
  rest. *Pros:* the seam stays a faithful "all sessions" read, so
  `exists()`/`_defaultModel()`/any future internal consumer keep working with
  **zero** behaviour change; a "show archived" toggle is nearly free (the data is
  already on the row); the wire is purely additive (one `bool` on the model and
  the row). *Cons:* "every client must implement the same hide-or-show logic" —
  but the bridge is the single API and the app is the only client, and the TUI
  (the service's other consumer) already filters its own list independently (Q1),
  so there is no second in-repo client that could diverge; a future
  raw-service-only consumer would see archived rows, but that is the service's
  own default (Q3), not a bridge regression.

- **Both.** The two are compatible — carry the flag on rows (B) *and* let the
  bridge's `GET /api/sessions` accept `?archived=` (A's route). **Not needed now**:
  B alone produces every UX shape in Q7 (separate view, toggle, or both), and a
  later slice can add the `?archived=` route param on top of the flag **without
  any seam or model change** (it is a filter applied to the already-flagged
  rows). So the recommendation is B; A's route param is a non-breaking
  extension, not a prerequisite.

### Recommendation

**B — the flag rides on every row and the app hides/shows locally — with the
single-verb pass-through write route from Q8 to set it.**

Against the repo's conventions:

1. **The bridge relays service facts; it does not impose display policy.**
   ADR-0001 makes the bridge the *stable wrapper* over a churning 130-endpoint
   service, and CONTEXT.md makes it the app's single API. *Which rows count as
   "home"* is a display choice (a policy the user can toggle), not a service
   fact — that is the app's concern. B keeps the bridge in its wrapper role: it
   faithfully relays `time.archived` as a row field. A instead makes the bridge
   re-derive "what is the home list," a decision it would have to keep in sync
   with the service's own notion of archived — the kind of app policy the
   bridge should not own.

2. **B keeps the seam faithful; A breaks two live consumers.** The concrete,
   code-grounded reason (not a vibe): `listSessions()` today feeds
   `exists()` (the reopen guard) and `_defaultModel()`. B leaves both untouched.
   A at the seam breaks both; A at the route is workable but collapses into
   "B's wire plus a route filter," i.e. B plus extra surface for no first-cut
   benefit.

3. **It composes across host+orb for free, and the state is already durable.**
   Because `archived` is a per-session, service-owned fact (Q4/Q5), B does not
   need any bridge-local store (unlike #204's option B) — the flag is simply
   carried on each row, host and orb alike (Q4's composite-rebuild caveat), and
   it survives restarts because the service owns it (Q5). B is the *minimal*
   bridge change that is also the *complete* one: an additive field, a new
   seam method, one route, and two already-arriving event types.

4. **Lowest churn, additive wire.** `OpencodeSession.archived` (default false),
   `Session.archived` on the row, the composite carries it through, one new
   `OpencodeService.archive(id, bool)` seam method, one `POST /api/sessions/{id}/archive`
   route, and the app handles the two SSE types it already receives. No route
   signature change, no behaviour change to any existing consumer.

What B does **not** get, and why that is acceptable: a single bridge-side
source of truth for "the home list." That is not a requirement the app has
today (one bridge per host in server mode; a client in client mode). If a later
slice wants the bridge to own the hide (e.g. for a headless client), the
`?archived=` route param slots on top of the flag with no seam or model change.

### Q7 — UX shape (implications only, not a decision)

Documented so the slices have a shape to build against; none of this is decided
here, and all of it is enabled by B (the flag is on every row, so the app can
render any of these without further bridge work):

- **Separate "Archived" view vs a filter toggle vs both.** All three work off
  the row flag. A separate view is the more discoverable "come back later"
  surface (it is the thing the user is told they can find the session in); a
  home-list toggle is the lower-effort option. Both is fine — they are the same
  flag, two renderings.
- **Where the archive action sits.** The natural home is the row menu next to
  Delete (the home-list row menu already offers Delete today). Archiving is
  non-destructive, so it can be a lighter-weight action than Delete (no
  destructive-confirm; at most a "this hides the session — you can unarchive
  later" note). Unarchive is the same menu, on the archived surface.
- **Archiving an active / mid-turn session.** Not refused (Q2: the turn keeps
  running invisibly and stays observable per-id). The app *may* warn, but it is
  a product choice, not a service constraint — the service happily runs a turn
  on an archived session.
- **Per-project vs global.** The flag is per-session (service-owned), so the
  archived set is naturally **global** (it spans projects); the app can present
  it however it likes (one global archived list, or grouped by project off the
  row's existing `project` field). Not a service constraint.
- **Push notifications.** Expected: **none.** Archiving is a local housekeeping
  act, unlike a permission request or turn end. The two SSE types
  (`session.archived` / `session.unarchived`) reach the app's stream today
  (EventHub re-emits verbatim, full enum subscribed) but are for the app to
  **merge the row in place** (no refetch), not to push-notify.

### Q8 — the bridge route shape

The service offers **one** verb both ways: `PATCH /api/session/{id}` with
`{"archived": bool}` (one call each way; the `session.update` handler dispatches
`payload.archived ? archive : unarchive`). The bridge should mirror that 1:1 —
**a single pass-through route with a `{"archived": bool}` body, not a
two-verb pair.** A two-verb pair (`/archive`, `/unarchive`) would invent a split
the service does not have and force the app to pick the verb; the bool body maps
cleanly to the service's own body.

On the HTTP method: the bridge's command-route family is
`POST /api/sessions/{id}/<verb>` (compact / undo / cancel / rename / move /
fork …, dispatched by `_sessionCommandIn` / `_handleCommand` in
`bridge_server.dart`), and the bridge already re-frames the service's
`PATCH rename` as `POST /api/sessions/{id}/rename`. The family-consistent shape
is therefore **`POST /api/sessions/{id}/archive`** with body
`{"archived": bool}` → service `PATCH /api/session/{id}` `{"archived": bool}` →
`204` (matching the other command routes). Unknown session → `404`; malformed
body → `400` (the existing `_invalidBody` / `_notFound` paths apply). (The
issue's "PATCH …/archive" framing matches the *service* verb; the *bridge*
command family is POST, so POST is the consistent choice — either is acceptable,
but the key decision is single-verb-bool, not two verbs.)

### The wire (option B), ready to cut into slices

- **Model (additive, default `false`):**
  - `OpencodeSession` (app/lib/bridge/sessions/opencode_service.dart) gains
    `bool archived` — derived in `_sessionFrom` (opencode_http_service.dart,
    ~line 1321) as `time.archived != null` (a number when archived, **absent or
    `null`** when not — Q2). This is the host-row and orb-row carrier.
  - `CompositeOpencodeService.listSessions()` (composite_service.dart, ~line 78)
    carries `archived: session.archived` in the orb-row rebuild — **required**,
    or orb rows drop the flag and archived orb sessions leak into the home list
    (Q4).
  - `Session` (app/lib/model/session.dart) gains `bool archived` (default
    `false`) on the home-list row, in `toJson`/`fromJson`, `copyWith` (so the
    app can merge the two SSE types in place, as it does for title/active), and
    `==`. `SessionsBackend._row` (backend.dart, ~line 309) sets
    `archived: s.archived`.

- **Read (no new read route, no seam behaviour change):** `listSessions()`
  still returns **all** sessions (the service's default includes archived —
  Q3), now each carrying `archived`. The home-list route (`GET /api/sessions`,
  endpoint 1) passes the flag through; the app renders
  `rows.where((r) => !r.archived)` by default. `exists()` and `_defaultModel()`
  are unchanged (the seam is faithful). *(Later, non-breaking: the route may
  accept `?archived=` to filter the already-flagged rows — A's surface, added on
  top.)*

- **Write (the one new route + one new seam method):**
  `OpencodeService.archive(String id, bool archived)` (the seam interface),
  implemented in `OpencodeHttpService` as the service's
  `PATCH /api/session/{id}` `{"archived": bool}`. Exposed as
  `POST /api/sessions/{id}/archive`, body `{"archived": bool}` → `204`
  (Q8), dispatched from the existing `_handleCommand` family.
  `SessionsBackend.archive(id, bool)` pass-through, beside `delete`.

- **Events (the two types already arriving — the app just handles them):**
  `session.archived` and `session.unarchived`, payload `{"sessionID": "…"}`,
  durable `{aggregateID, seq, version}`. The bridge re-emits them verbatim onto
  `GET /api/events` (no hub work — they are already in the subscribed full
  enum). The app's home-list handler merges each: set `archived` true on
  `session.archived`, false on `session.unarchived`, on the cached row by
  `data.sessionID` — no refetch, no push notification (Q7). No new
  bridge-native event is needed; the upstream events are the source of truth.

- **What the app does not do:** it never opens an archived session by
  unarchiving it first (per-id routes work while archived — Q2); it does not
  add a bridge-local archived store (the service owns the flag — Q5); and it
  does not build the `?archived=` route in the first slice (it is a later,
  non-breaking extension — "Both" in the A/B evaluation).

### Assumptions (labelled, per the probe brief)

- **A1.** The in-orb build pin is **v2.1.4**, not the v2.2.7 the tasking
  assumed (both `opencode --version` and `GET /api/info` report 2.1.4 in this
  container; the binary carries the full archiving feature regardless). Q2–Q5
  are version-independent and match the issue's host v2.2.7 findings; the only
  version-dependent detail is the TUI's *mechanism* (Q1).
- **A2.** The v2.1.4 TUI hides archived sessions by default by constraining its
  list query on `time_archived` (the in-orb binary shows
  `where(x?.archived ? void 0 : <predicate>(time_archived))`; the minified
  helper's identity was not isolated, but the behaviour matches the v2.2.7
  `archived:!1` list-param surfaces the issue verified on the host). The CLI
  `opencode session list` does not filter in either version (verified on the
  host's v2.2.7 binary per the issue; the exact v2.1.4 CLI list string was not
  isolated here, though the same `session.list` op and `time_archived` machinery
  are present in the in-orb binary).
- **A3.** Project-level archiving (`project.list` excluding archived projects
  unless `archived=true`) exists in the same build (the migration adds
  `time_archived` to the `project` table and the `Project.Time` schema carries
  `archived`), but is out of scope for this ticket.
- **A4.** `time_archived` on `session_v2` is the durable column that survives a
  service restart (verified by read-only on-disk read; the live restart was not
  run against a shared store — the probe used an isolated store). Option B does
  not depend on restart behaviour at all (the service owns the flag), so this
  is noted, not load-bearing.

