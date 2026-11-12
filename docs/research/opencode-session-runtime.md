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

