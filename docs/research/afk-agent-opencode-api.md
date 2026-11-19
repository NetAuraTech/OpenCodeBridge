# The AFK agent's opencode v2 service API — verified research

Ticket #360. Consolidates the wayfinding findings (the context-pointer comment on the
issue) and re-verifies the three points it flagged, against the **live host service** and
the repo code. Facts with file:line pointers and short quotes; no opinions.

## Environment & method

- **Service**: the host shared opencode service, `http://127.0.0.1:49374`, v2.2.7
  (process 2805514, `opencode serve --service`, started 2026-11-19 15:59:47).
- **Auth**: HTTP Basic, user `opencode`, password from
  `~/.local/state/opencode/service.json` (`{id,version,url,pid,password}`).
- **Probe discipline**: throwaway sessions only, all bound to a temp dir
  (`/tmp/opencode/afk-probe`), created and deleted by the probe. The user's real sessions
  were read-only (list metadata / store counts). No service restart.
- **Primary sources**:
  - The service's own OpenAPI spec, served live at `GET /openapi.json` (v2.2.7) — cited by
    `paths['…']` + `operationId` and quoted description.
  - The on-disk store, `~/.local/share/opencode/opencode.db` (SQLite), read read-only.
  - Repo code at branch base `origin/main` (`eec7f7f`).
- **Prior notes** (this repo): `docs/research/opencode-api-remote.md`,
  `docs/research/opencode-session-runtime.md` (both v2.1.4-era; this note corrects and
  extends them for v2.2.7).

The bridge already speaks this API to the host service:
`OpencodeHttpService.fromHost()` (`app/lib/bridge/sessions/opencode_http_service.dart:42`)
reads the descriptor, and `CompositeOpencodeService` routes an unregistered session id to
the host (`app/lib/bridge/sessions/composite_service.dart:66-68`). So every endpoint below
is already reachable from the bridge; this note establishes what each one *does*.

---

## The three flagged points — verdicts

| # | Point | Verdict | Basis |
|---|-------|---------|-------|
| 1 | Session-id persistence across a service restart | **Session ids and all state persist** (durable SQLite); **connection url/password do not** (descriptor rewritten per start) | Live store + descriptor |
| 2 | Feed to a busy session: steer vs queue, interrupt or enqueue? | **Neither auto-interrupts.** Both enqueue durably; the current turn continues. `interrupt` is a separate explicit call. On `interrupt?resume=true`, `steer` is injected, `queue` is parked | Live probe |
| 3 | Can `POST …/skill` run `implement-spec` on demand? | **Yes.** It injects the skill's SKILL.md as a `skill` message and resumes execution with full tool access; `resume` controls scheduling. Not a free-form prompt | Live probe |

Details and evidence follow under the five sub-questions.

---

## 1. Creation with pins

**Endpoint**: `POST /api/session` (operationId `session.create`).
Spec description: *"Create a session at the requested location. A parentID creates a
linked child session at its parent's location."*

Request body (spec, all optional except none are required): `id`, `parentID`, `title`,
`agent`, `model`, `location`, `metadata`, `permissions`.

- `location` is `Location.PublicRef` = `{ "directory": <AbsolutePath> }`.
- `model` is `Model.Ref` = `{ "id", "providerID", "variant?" }`.
- `metadata` is a free-form object (spec: `{"type":"object"}`) — a pin/claim field.
- `id` is accepted caller-side (spec `Session.ID | null`) — **a caller can mint the
  session id**. *Not live-tested here* (recorded as spec-only).
- `agent` is an `Agent.ID` string; the live registry (`GET /api/agent`) exposes
  `build`/`general`/`explore`/… with a `mode` (`primary`/`subagent`).

**Response**: `{ "data": Session.Info }` (envelope — the bridge unwraps `data`,
`opencode_http_service.dart:120-122`).

**Verified live** — created a session with all pins at once:

```
POST /api/session
{ "location":{"directory":"/tmp/opencode/afk-probe"},
  "title":"afk-probe-create", "agent":"general",
  "model":{"id":"Qwen3.8-27B","providerID":"amd","variant":"low"},
  "metadata":{"afk":"probe-360"} }
```
→ `200`, `data` echoed `agent:"general"`, the full `model` ref, `title:"afk-probe-create"`,
`metadata:{"afk":"probe-360"}`, `location.directory`. All pins were applied on creation.

**Verified live (store)** — the same row in `session_v2`:
`model='{"id":"Qwen3.8-27B","providerID":"amd","variant":"low"}'`, `agent='general'`,
`metadata='{"afk":"probe-360"}'`, `permission=NULL`. So pins are persisted to the store,
not just echoed.

**Verified live** — creating at a directory the store has never seen **creates a `project`
row** for it (a `project` row for `/tmp/opencode/afk-probe` appeared and *remained* after
the session was deleted). Project rows are keyed by directory and are not garbage-collected
by session deletion.

**Bridge's existing client**: `createSessionInDirectory(directory, {model, agent})`
(`opencode_http_service.dart:126-159`) builds the body via `_createBody`
(`:148-159`) which sends only `location` + optional `model`/`agent` — it does **not** send
`title`, `metadata`, `permissions`, or a caller `id`. The bridge has no existing pin/claim
metadata path; an AFK agent would extend `_createBody` to add `metadata` (and, if a stable
id is wanted, `id`).

---

## 2. Prompt semantics (feed to a busy session) — flagged point 2

**Endpoint**: `POST /api/session/{sessionID}/prompt` (operationId `session.prompt`).
Spec description: *"Durably admit one session input and schedule agent-loop execution
unless resume is false."*

Request body: `text` (required), `files?`, `agents?`, `skills?`, `metadata?`,
`delivery?`, `resume?`.

- `delivery` is `Session.Inbox.Delivery` = enum **`"steer" | "queue"`**.
- **Default delivery is `steer`.** *Verified live*: a prompt sent with **no** `delivery`
  field came back admitted as `"delivery":"steer"`.
- Response: `200` with the admitted `Session.Inbox.User` item (its `id`, `sessionID`,
  `payload.text`, and the effective `delivery`).

The admitted input is a **durable inbox item**. `GET /api/session/{id}/inbox`
(operationId `session.inbox.list`) — *"List durable enqueued session work not yet
delivered, ordered by enqueue sequence. Includes user, synthetic, compaction, and move
items."*

### Does it interrupt the current turn? **No.** Both modes enqueue.

**Verified live** (a long single-turn generation, model `Qwen3.8-27B`/`amd`):

- A `steer` prompt admitted mid-turn **stayed in `GET …/inbox`** (undelivered) for the
  whole turn; the running turn **kept going** (the story kept being written). `steer` does
  **not** auto-interrupt.
- A `queue` prompt admitted mid-turn likewise stayed in the inbox; the running turn kept
  going.

### When is each delivered?

- **On natural turn completion**: both modes are drained in FIFO order and run. *Verified
  live* (two sequential `sleep 5` turns): a `queue` item admitted during turn 1 ran after
  turn 1 completed.
- **On an explicit interrupt** (`POST …/interrupt?resume=true`): the spec says
  (operationId `session.interrupt`): *"When resume=true, execution resumes pending steering
  input and next-in-line control items (manual compaction, moves) while queued prompts
  remain parked."* *Verified live*: with a `steer` and a `queue` item both parked,
  `interrupt?resume=true` → the **steer item was consumed and ran** (a new turn), while the
  **queue item stayed parked in the inbox**. The parked queue item was then drained and run
  on the next ordinary execution resume.

**Net semantics** (all live-verified):

- `steer` = deliver at the next execution boundary, *including* an `interrupt?resume=true`
  (it is injected as a new turn).
- `queue` = deliver only at a *natural* turn completion / next ordinary resume; it is
  *parked* (not injected) by `interrupt?resume=true`.
- **Neither** interrupts a running turn by itself.

### Interrupting a running turn is a separate, explicit call

`POST /api/session/{sessionID}/interrupt` (operationId `session.interrupt`), query
`resume=true|false`. Spec: *"Interrupt active execution owned by this OpenCode process.
Returns interrupted=true when an active execution was interrupted and false for the idle
no-op."* Response: `{ "interrupted": boolean }` (`SessionInterruptResponse`).
*Verified live*: `interrupt?resume=true` on a busy turn → `{"interrupted":true}` and the
steer item ran; `interrupt?resume=false` on a running skill execution →
`{"interrupted":true}` and it stopped.

### Bridge's existing client

`prompt(id, text, {files, skills})` (`opencode_http_service.dart:414-427`) hardcodes
`'delivery': 'steer'` (`:420`) and forwards `files`/`skills` as the service's `PromptInput`
attachments. The host's own prompt endpoint `POST /api/sessions/{id}/messages` returns 202
(`bridge_server.dart:2020-2062`, the prompt at `:2056` + `HttpStatus.accepted` at `:2057`).
Orb-task completions wake sessions through this same primitive
(`orb_task_service.dart:1285`). The bridge has **no** wrapper for the `queue` delivery.
It **does** already wrap the interrupt route: `cancelTurn(id)`
(`opencode_http_service.dart:727-752`) POSTs `{}` to
`/api/session/{id}/interrupt` (route-probing with `CancelUnsupportedError`, issue #160;
capability comment `composite_service.dart:226-228`) — but without a `resume` query
parameter, so the service default applies. An AFK agent that needs to interrupt *and*
inject parked steering input must pass `resume=true` explicitly.

---

## 3. Completion detection

Four independent signals; the bridge already runs one of them for orb sessions.

1. **Blocking wait** — `POST /api/experimental/session/{sessionID}/wait`
   (operationId `experimental.session.wait`): *"Wait for a session agent loop to become
   idle."* Spec responses `204` (idle) / `503` (running). *Verified live*: at idle it
   returned `204` promptly; while a turn was running it **held the request** (a 3 s client
   timeout expired with no HTTP response). So in practice it behaves as a **long-poll** —
   a client must set its own timeout; it is not a cheap busy-flag probe.

2. **Active set** — `GET /api/session/active` (operationId `session.active`): *"Retrieve
   foreground Session drains currently owned by this OpenCode process. Sessions absent
   from the result are inactive."* Shape: `{ "data": { "<ses_…>": { "type":"running" } } }`.
   *Verified live*: the probe session **appeared** in `active` while running and was absent
   when idle. (Note: the older v2.1.4 note `opencode-session-runtime.md` recorded that an
   API-created session did **not** appear in `active`; in v2.2.7 an API-driven session
   *does* while running. The "foreground drains owned by this process" wording is the
   current contract.) The bridge reads it via `activeSessionIds()`
   (`opencode_http_service.dart:162-170`).

3. **Per-turn outcome** — the session detail's `outcome` enum
   `succeeded | failed | interrupted` (`Session.Info.outcome`; also on the `idle` context
   item). The bridge models it as `SessionDetail.outcome` (`app/lib/model/session_detail.dart:150`)
   and the live flag as `SessionDetail.active` (`:169`).

4. **SSE events** — `GET /api/event` (operationId `event.subscribe`). The `types` filter
   takes the **array form** `?types[]=<name>&types[]=<name>` in v2.2.7 (a comma-joined CSV
   is rejected with `InvalidRequestError`, *verified live*). Relevant session events
   (spec `Session.Event.Durable`): `session.execution.started`,
   `session.execution.succeeded`, `session.execution.failed`,
   `session.execution.interrupted`, `session.inbox.enqueued`, `session.inbox.delivered`,
   `session.skill.activated`. Each frame carries a per-session durable `seq`
   (`{ "durable": { "aggregateID": "<ses_…>", "seq": N } }`) — a gap detector. *Verified
   live* (full stream captured for a skill run).

**The pattern to reuse** (already in the bridge for orb sessions):
`SessionsBackend.detailWithActive(id)` folds a detail read with the live active set into
one result (`app/lib/bridge/sessions/backend.dart:247`; `app/lib/bridge/sessions/session_row.dart:107`).
`OrbTaskService._check` (`app/lib/bridge/orb/orb_task_service.dart:989`) settles on:
`outcome != null` → that outcome; else `outcome == null` **and** not active for a full
`settleIdleWindow` **and** no pending permission → `succeeded`
(`:1020-1048`, the permission guard at `:1030-1039`). An AFK agent's completion detector is
this same read, pointed at a host session id.

---

## 4. Skill activation — flagged point 3

**Endpoint**: `POST /api/experimental/session/{sessionID}/skill`
(operationId `experimental.session.skill`). Spec: *"Activate a skill for a session by
appending a skill message and resuming execution."* Request body: `{ "id": <Skill.ID>
(required), "resume"?: boolean|null }`. Response `204`.

**Registry**: `GET /api/skill` (operationId `skill.list`): *"Retrieve currently registered
skills."* *Verified live*: 52 skills are registered on the host service, including
`implement-spec`:
```
{ "id":"implement-spec", "name":"implement-spec",
  "description":"Implement the result of /to-spec and /to-tickets in code.",
  "autoinvoke": false,
  "path":"/home/aymeric/.agents/skills/implement-spec/SKILL.md", "content":"…" }
```
`autoinvoke:false`, and the skill's own front-matter sets `disable-model-invocation: true`
(`~/.agents/skills/implement-spec/SKILL.md`) — so the model will not invoke it on its own;
it must be activated explicitly.

**Can it run `implement-spec` on demand? Yes — and it really runs.**
*Verified live* on a throwaway session:

- `POST …/skill { "id":"implement-spec" }` (default resume) → `204`. A `skill` message was
  appended — `{ "type":"skill", "skill":"implement-spec", "name":"implement-spec",
  "text":"<the SKILL.md body>" }` — and the session **became active and executed**:
  `session.skill.activated` → `session.execution.started` → multiple
  `session.step.started`/`tool.called`/`tool.success` cycles (it read
  `docs/orbs-spec.md`, ran `gh`, explored the repo) before being interrupted and the
  session deleted. It is a **real skill execution, not a free-form prompt**: the skill's
  instruction text is injected as a first-class `skill` message and the agent acts on it.

- **Safety fact (live-observed, not an opinion)**: the skill runs with the session's
  location and **full tool + network access** (it invoked the real `gh` CLI against the
  real remote and read the real checkout at its working directory). A skill activation is
  not sandboxed; the session's working directory and permissions bound what it can touch.
  The probe was interrupted (`interrupt?resume=false`) and the session deleted to contain it.

- **`resume:false` parks instead of running.** *Verified live*: a second activation with
  `{ "id":"implement-spec", "resume":false }` → `204`, appended a second `skill` message,
  but the session **stayed idle** (nothing executed; both `skill` messages sat in the
  store). So `resume` controls whether execution is scheduled on activation.

**Bridge's existing client**: `activateSkill(id, skillId)`
(`opencode_http_service.dart:693-699`) POSTs `{ "id": skillId }` (default resume) — the
plumbing already exists and would drive an on-demand `implement-spec` run with no new
endpoint. `listSkills()` (`:685-689`) wraps `GET /api/skill`.

---

## 5. Persistence across a host-service restart — flagged point 1

**What is on disk.** The host service's state is a single SQLite database,
`~/.local/share/opencode/opencode.db`. Relevant tables (read live):

- `session_v2` — one row per session: `id`, `project_id`, `directory`, `title`, `model`,
  `agent`, `metadata`, `permission`, `time_created/updated/idle/archived/suspended`,
  `resume_attempts`, `time_busy`, `idle_outcome`, … (437 rows at probe time).
- `session_message` (42,447 rows), `session_inbox`, `session_part` — the conversation and
  durable inbox, keyed by `session_id`.
- `project` — keyed by directory (`id`, `worktree`, …); created on first use of a dir.
- `kv`, `account`, `credential`, `event`, … — service-level state.

**What survives a restart.** *Verified live*: the running service (started 2026-11-19
15:59:47) is serving **434 sessions whose `time_created` predates the process start**
(oldest 2026-10-26 22:08). So the durable store outlives the process: **session ids, their
location/model/agent/metadata, message history, and any parked inbox items all persist and
are inherited by a restarted service.** A restarted service re-serves the same `ses_…`
ids. (No restart was performed — this is inferred from the store's timestamps vs the
process start time, per the ticket's constraint.)

**What does NOT survive.** The **connection** does. The descriptor
`~/.local/state/opencode/service.json` is rewritten on every service start with a fresh
`url` (ephemeral port), `password`, and `pid` (ADR-0008,
`docs/adr/0008-opencode-service-as-second-app-owned-child.md`: the app writes
`{url,password}` to `service.json` "only after the credentials are parsed … and the service
answers"). So across a restart the **url/port/password change**; only the durable session
identity (in `opencode.db`) is stable. A service restart also loses any **in-flight turn**
(the running agent loop is process state); the `session_v2.resume_attempts` and
`time_suspended` columns exist to track resumption of interrupted work.

**What the bridge inherits vs. must recreate.**

- *Inherits for free*: every session id and its full state, keyed on the id — because the
  bridge reads the shared `opencode.db` through the service. An AFK agent's persistent
  session id is therefore stable across a host-service restart.
- *Must re-derive the connection*: re-read `service.json` for the new `url` + `password`.
  The bridge already does exactly this — `OpencodeHttpService.fromHost()` re-reads the
  descriptor on construction (`opencode_http_service.dart:42-55`), and the composition root
  builds it at startup (`bridge_server.dart:882-884`, host service passed to
  `OrbService`/`hostSessions` at `:999-1017`).
- *In-memory routing may need refresh*: `CompositeOpencodeService`'s owner map
  (`composite_service.dart:66-68`) is rebuilt by `_refresh()`; an unregistered id resolves
  to the host, so a host session needs no registration to survive.
- *App-owned side files* persist independently of the service: e.g. the session display
  order at `~/.config/opencodebridge/session-order.json`
  (`app/lib/bridge/sessions/order_store.dart:20-40`), keyed on the session id.

**Bottom line for the AFK agent**: persist the **session id** (mint it or capture it at
creation, optionally with a `metadata` claim pin). It is durable across host-service
restarts. On each (re)attach, re-read `service.json` for fresh credentials and re-resolve
the route; recreate nothing about the session itself. If a turn was in flight at restart,
treat it as needing a re-drive (prompt/skill with `resume`), per the `resume_attempts`
semantics.

---

## Appendix — endpoint index for an AFK persistent session

| Purpose | Method + path | operationId | Notes (verified) |
|---|---|---|---|
| Create w/ pins | `POST /api/session` | `session.create` | `location/model/agent/title/metadata/id`; 200 `{data:Info}` |
| Send feed | `POST /api/session/{id}/prompt` | `session.prompt` | durable inbox; default `delivery:steer`; 200 inbox item |
| Interrupt turn | `POST /api/session/{id}/interrupt?resume=` | `session.interrupt` | explicit; steer injected / queue parked on resume |
| Wait (long-poll) | `POST /api/experimental/session/{id}/wait` | `experimental.session.wait` | 204 idle / 503 running; holds while busy |
| Active set | `GET /api/session/active` | `session.active` | `{data:{ses:{type:running}}}`; API sessions appear in v2.2.7 |
| Detail/outcome | `GET /api/session/{id}` | `session.get` | `Info.outcome` = succeeded/failed/interrupted |
| Inbox (pending) | `GET /api/session/{id}/inbox` | `session.inbox.list` | undelivered durable items, by seq |
| Context | `GET /api/session/{id}/context` | `session.context` | active messages + `idle{outcome}` items |
| Skill registry | `GET /api/skill` | `skill.list` | `implement-spec` present, `autoinvoke:false` |
| Run a skill | `POST /api/experimental/session/{id}/skill` | `experimental.session.skill` | `{id, resume?}`; 204; real execution w/ tools |
| Events | `GET /api/event?types[]=` | `event.subscribe` | array form; per-session durable `seq` |
| Delete | `DELETE /api/session/{id}` | `session.remove` | 204; cascades message/inbox/part rows |

*All endpoints reachable from the bridge via the existing
`OpencodeHttpService.fromHost()` + `CompositeOpencodeService` host routing.*
