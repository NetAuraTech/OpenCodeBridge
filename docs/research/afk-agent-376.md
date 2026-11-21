# AFK agent spec (#376) — driver notes & shared contract

Spec: https://github.com/NetAuraTech/OpenCodeBridge/issues/376
Tickets (GitHub, in the same repo): #377 (T1), #378 (T5), #379 (T4), #380 (T3), #381 (T6), #382 (T2).

## Task graph

```
T1 #377 (settings, charter, session)
 ├─ T2 #382 (ready gate: gh reader + poller)
 │    └─ T3 #380 (run service: state machine, feed, narration, retry)
 │         ├─ T5 #378 (push: afkRun kind, deep-links, toggle)
 │         └─ T6 #381 (restart: reconciliation, lost-run, fresh-agent handoff)
 └─ T4 #379 (cap N + AFK attribution at spawn boundary)
```

## Driver context (do not lose)

- Spec issue #376 (the map), tickets #377–#382. Read `gh issue view <n>` for the full ticket text — this file is a pointer + shared contract only.
- Integration branch: `integrate/afk-agent-376` on origin (base `origin/main` @ `fce3c65`).
- One draft PR: `origin/integrate/afk-agent-376` → `main`, body carries `Closes #376, #377, #378, #379, #380, #381, #382`.
- Worktrees live in `../opencodebridge-wt/tNNN-<slug>` (sibling of the checkout).

## Repo context for implementers

- Flutter app (Dart) in `app/`. Bridge = server mode inside the app process. `app/lib/bridge/` = bridge code; `app/lib/settings/` = persisted settings; `app/lib/ui/` = settings tab, deep-link tap handling; `app/lib/notify/` = push dispatcher.
- Existing prior art (read before writing):
  - orb task service tests — injected poll interval (ms) with fakes; busy-orb refusal tests; spawn-tree & attribution.
  - push dispatcher tests — fake sender, event frame construction; FCM sender payload-shape tests.
  - persisted settings tests (pure key/value); settings tab widget tests (section rendering + persistence round-trip).
  - deep-link tap tests (in-app deep links; T5 adds the external-URL tap).
  - the orb lifecycle state module — the shape for T3's run state machine (exhaustive transition tests).
  - the tunnel settings section — the pattern for the "AFK agent" settings section (server-mode only, after "Host connection").
  - `gh` CLI shelling — the bridge's existing pattern (the GitHub reader reuses it).
- Known environment quirk: local sandbox runs as **root** — tests simulating permission denial or unset `GH_CONFIG_DIR` fail locally, pass on CI's non-root runners. Treat as environmental; do not build on root behaviour.
- Local verification (fast): `cd app && flutter pub get --enforce-lockfile && flutter analyze && dart format --set-exit-if-changed --output=none lib test && flutter test --exclude-tags docker`
- CI (Linux) additionally builds a **release** app — run `flutter build linux --release` before reporting done if you changed UI code (or any code the release build compiles).
- Commit style: conventional commits, `type: scope — summary` (lowercase summary, em dash), e.g. `feat: bridge — ...`. The repo has a pre-commit hook refusing unformatted Dart commits (run `dart format` on touched files).
- The one branch contract: each orb commits on its named branch; a post-commit hook auto-pushes that branch. The completion report carries that branch + PR (the draft integration PR counts as the PR).

## Per-ticket branch contract (the driver hands the exact branch to each implementer)

| Ticket | Branch | Base |
|---|---|---|
| #377 T1 | `t377-afk-settings-charter` | integration branch |
| #382 T2 | `t382-ready-gate-poller` | integration branch (post-T1) |
| #379 T4 | `t379-afk-cap-attribution` | integration branch (post-T1) |
| #380 T3 | `t380-afk-run-service` | integration branch (post-T2) |
| #378 T5 | `t378-afk-push` | integration branch (post-T3) |
| #381 T6 | `t381-afk-restart-reconcile` | integration branch (post-T3) |
| review fixups | `t376-review-fixups` | integration branch tip |

## Shared implementation contract (all tickets)

- **AFK store**: one persisted store (pattern: the orb task store / persisted-state files the bridge already owns) holding, per issue: state, issue number, title, retry count, PR number/URL. New files go under the bridge's state area.
- **State machine**: pure module, states `idle → dispatched → pr-open → done` + terminal `failed`; per-action predicates, no I/O. Shaped on the orb lifecycle state module.
- **Bridge events** (event hub): T2 emits a ready-admission event; T3 emits `pr-open` and `failed` events. T5 maps them to the `afkRun` notification kind.
- **GitHub reader**: thin interface (list ready-labelled issues, last comment, issue/PR state, add label) — real impl shells to `gh`, tests fake it.
- **AFK attribution**: an orb spawn's caller session == the stored AFK session id ⇒ AFK-attributed (bridge's own persisted fact; the spawn surface already carries the caller session).
- **Settings keys** (namespaced, e.g. `afk.enabled`, `afk.parallel_orbs`, `afk.model`): arming toggle default off; cap 1–10 default 5; model free text, empty = inherit. The bridge is notified in-process on change (no HTTP endpoint); cap effective from next spawn, model from next session creation.
- **Charter**: canonical markdown agent file in the repo (reviewed source of truth); guarantee module installs it into the global opencode config's agents dir only if absent, never rewrites; permissions deny force-push and push-to-the-default-branch.
- **Layer rule** (spec): charter = standing rules, repo wiki = tribal knowledge, tracker narrations = per-run journal, bridge store = machine state. A fact lives in exactly one layer.
- **Human boundary**: never merge, never force-push, never push the default branch, never mutate the main checkout. The PR waits for the human (`/merge-orb` flow).
- Tests: external behaviour only (store contents, events, pushes, UI). No real sleeps (injected clock/poll interval). No new I/O surfaces besides the GitHub reader.

## Orbs available to the driver

- `t1` — claims #377; `t2` — #382; `t4` — #379; `t3` — #380; `t5` — #378; `t6` — #381; `review` — fixups.
- Orb base dir is `/workspace`; the named branch is checked out on creation (the base is the branch's creation-time tip). Work done on the orb persists on that branch (auto-pushed by the post-commit hook).

## Driver checklist after each orb report

1. `git fetch origin <branch>` — branch must exist on origin at the reported sha. Missing/mismatch ⇒ re-dispatch (never merge on the orb's word).
2. `git merge --no-ff` the branch onto `integrate/afk-agent-376` (in the worktree), run full verification, push.
3. Reclaim + close the ticket (`gh issue close <n> --comment`), update this file's done list.

## Done (driver appends)

- [x] T1 #377 — merged as `295d10d` (branch `t377-afk-settings-charter` @ 4033b30b; orphan `orb/ea23f47d` on the remote carries the same commit — candidate for deletion at cleanup, needs the developer's OK). Same quirk left `orb/923bb9cf` after T4's re-dispatch (same commit as `t379-afk-cap-attribution`), and `orb/4f44e81c` after T3's re-dispatch (same commit as `t380-afk-run-service`) — also deletion candidates. Landed: `app/lib/bridge/afk/` (afk_settings, afk_charter + install guarantee, afk_store, afk_session_manager, afk_component), settings section in `settings_tab.dart` (server-mode only, after "Host connection", keys `afk.enabled`/`afk.parallelOrbs`/`afk.model`, defaults off/5/empty), in-process handoff in `bridge_server.dart` (`updateAfKSettings`/`ensureAfKSession`/`afkSettings`) and `app.dart`. T2/T4 build on `app/lib/bridge/afk/` and the store surface.
- [x] T2 #382 — merged as `9f07a05` (residual PR #397 from the orb, head `t382-ready-gate-poller` → integration branch: GitHub marks it merged on the merge; the driver closes it explicitly at cleanup). (branch `t382-ready-gate-poller` @ 461ec9db). Landed: `app/lib/bridge/afk/github_reader.dart` (`GitHubReader` interface: `listReadyIssues`/`readIssueState`/`readLastComment`; real impl `GhGitHubReader` shells to `gh`), `app/lib/bridge/afk/afk_ready_gate_poller.dart` (`AfkReadyGatePoller`: armed-only ticks, admits new ready issues as store rows `idle` + one `afk.ready_admitted` event each, no duplicates, never aborts, read/write failures emit nothing), `afk_store.dart` extended with `AfkRun` rows under `afk.run.<issueNumber>` keys (state, issue number/title), `bridge_server.dart` wiring (poller built at `start()` when an event hub exists; `syncArmed` on settings change; stopped on `stop()`), new event type `afk.ready_admitted`. T3 builds on the store rows, the reader, and the event hub.
- [x] T4 #379 — merged (branch `t379-afk-cap-attribution` @ 606009fa). Landed: `app/lib/bridge/afk/afk_spawn_gate.dart` (`AfkSpawnGate`: AFK session id + live cap + `isAfk(callerSession)` attribution; `AfkComponent.spawnGate()` reads both live — cap effective from the next spawn, `null` = disengaged when no AFK session is persisted), `OrbTaskService` gains the injected `afkGate` seam (wired in `bridge_server.dart`): idempotent retry answered first, then an AFK-attributed spawn above the cap is refused BEFORE any orb is created via `OrbRefusalError.afk_cap` (counter + "wait for a slot, then re-dispatch"); developer spawns never capped. Attribution is derived from the task records' persisted caller sessions — no new generic record. Residual PR #399 from the orb (head `t379-afk-cap-attribution` → integration branch): closed explicitly at cleanup.
- [x] T3 #380 — merged (branch `t380-afk-run-service` @ ccd9fb25, 5 commits). Landed: `app/lib/bridge/afk/afk_run_state.dart` (PURE state machine: five states, per-action predicates, unknown → refused, exhaustive matrix tests), `app/lib/bridge/afk/afk_run_service.dart` (all deps injected: reader, session port, hub emit, clock, poll interval; feed = pure availability notice via the existing prompt path, the service's durable inbox is the FIFO queue; idle-wait long-poll as trigger; terminal narration `PR opened: <url>` / `FAILED: <reason>` from the issue's last comment as the signal; narration dedup by comment id; retry ≤3 with 5/10 min backoff as ordinary FIFO feeds, no events on retries; PR-open runs never retried; terminal failure labels `needs-triage` + comment + event; deliberate retry on re-label resets the counter), store row grown (`retryCount`, `prNumber`/`prUrl`, `closedUnmerged`, `retryAt`, `narrationId`, tolerant decode), `GitHubReader` grown (`readLastComment` → id+body, `hasLabel`, `readPr`, `addLabel`, `addComment`), events `afk.pr_open` + `afk.failed`, `waitIdle` on the session seam. Bridge wiring: pass loop runs for the bridge's whole life (armed or not) — arming gates NEW work only (feed, re-dispatch), read live via `isArmed` (user story #24: disarming never stops the loop, never orphans an in-flight run); the session port only reads the resident session id (arming creates the session, never the service). T5 maps `afk.pr_open`/`afk.failed` to the push; T6 builds on liveness + the store.
- [x] T5 #378 — merged (branch `t378-afk-push` @ 2db40952). Landed: notification kind `afkRun` (`lib/notify/notify_kind.dart`), the existing push dispatcher maps `afk.pr_open` / `afk.failed` (no new event types, no direct send), `notify.afkRun` toggle in the Notifications group (default off, distinct from the arming toggle), deep-link `external` for the PR (GitHub URL → platform browser via `home_shell.dart` tap path) and the in-app AFK session for terminal failure (resolved live from the stored session id; no session ⇒ no push), `highPriority` threaded through the FCM senders. A retry emits no event ⇒ no push (asserted).
- [x] T6 #381 — merged (branch `t381-afk-restart-reconcile` @ 84a4b53c; merge `c09d890` resolved one conflict: T6 moved the `taskService` declaration above the AFK run service for the liveness closure — kept the single `afkComponent` declaration already on the branch). Landed: `AfkLiveness` injected into the run service (AFK-attributed orbs in flight via `OrbTaskService.afkOrbsInFlight` + the AFK session's active state, OR-ed, not the service inbox), `reconcile()` startup pass (once, from `start()`, not armed-gated — a disarm never strands an in-flight run): live `dispatched` left alone, `dispatched` + no liveness + no terminal narration + no PR = **lost run** → the failure path (reuses the bounded-retry logic factored into `_routeToFailure`, same cap of 3 + `afk.failed` event), `pr-open` settled to closure, `idle`/`failed`/`done` left to their owners; a run re-counts as lost on each startup it is still lost. Store row grows `lastFailureReason` (tolerant decode). Fresh-agent handoff: arming triggers the bootstrap only when a session was just created (`id != before`) — a normal restart reuses the session (ids persist across a plain service restart), so no recreation, no re-bootstrap; the bootstrap feed lists in-flight runs (`dispatched` + `pr-open`: number, state, retry count, last failure reason). `AfkRunService.lostRunReason` is the lost-run constant.
- [x] Code review + fixups — merged (branch `t376-review-fixups` @ 19129ca0, commit `fix: afk — the code-review fixups (spec #376)`). The four findings (F1–F4) are fixed: the reader's `readLastComment` throws on a failed `gh` read (null = genuinely no comments) so a startup during a GitHub outage no longer burns a lost-run retry; the `needs-triage` hand-back comment is retried via a new `handbackLanded` row field until it lands (no silent skip after a partial addLabel+addComment); the charter denies `gh pr merge` / `gh merge` (merge is a permission, not words); the `AfkComponent` doc no longer references the non-existent `forgetSession`. 18 new/changed tests; the full suite is green (zero new failures vs the clean base).
- All six tickets merged + reviewed + fixups in. The branch carries the whole spec and is the merge target of draft PR #385 (`integrate/afk-agent-376` → `main`), whose body lists every ticket + the spec so the issues close in one shot when the human merges to `main` (the human boundary — the driver marks #385 ready and stops there; it never merges to `main`).
- Local verification signature on this host (Flutter 3.50, non-root): `--enforce-lockfile` fails on `origin/main` itself (host Flutter ≠ CI's 3.47.8) — treat as environmental; `flutter analyze` fails on pre-existing 30 `material` deprecation infos (host-only); **authoritative local gate here = `flutter test --exclude-tags docker` (0 failures) + `dart format`**. CI (Flutter 3.47.8) runs the full command. Do not commit a regenerated `pubspec.lock` from the host.

## Code review (driver, post-merge) — the fixups

Two-axis review of `origin/main...integrate/afk-agent-376` (Standards: driver-direct, `reviewer-local` unavailable; Spec: `reviewer-flash`). Findings fixed on branch `t376-review-fixups` (orb `review`):
- **F1 (spec)**: `_reconcileDispatched` read a failed `gh` read (null) as "no narration" → a startup during a GitHub outage burned a lost-run retry on a healthy run. Fix: `readLastComment` throws on a failed/unreadable read (null = genuinely no comments); the per-run try/catch makes a failed read inert at reconciliation, exactly as in the periodic pass.
- **F2 (spec)**: `_labelNeedsTriage` short-circuited on the label → `addLabel` landed + `addComment` failed once = the hand-back comment never posted. Fix: a `handbackLanded` row field; the comment is posted until it lands, then the row is marked.
- **F3 (spec)**: the charter denied force-push and push-to-`main`/`master` but not merging — "never merge" was words. Fix: `gh pr merge` / `gh merge` deny rules in the frontmatter.
- **F4 (standards)**: `afk_component.dart` class doc referenced a `forgetSession` that does not exist and described a disarm-drops-the-id behaviour the implementation never has. Fix: doc rewrite only.
Accepted without change: the poller/run-service shared `_inFlight` guard shape, `_existingTargetOrbId`'s documented targeting mirror, Android-only high-priority, `DeepLink.tryParse` accepting any http(s) (the spec asks for the external-URL tap), the French push titles (the spec specifies them verbatim).

**Cleanup decision (developer OK):** the three orphan `orb/…` branches (each identical to its ticket branch, both already in the integration branch) are deleted at the fixup stage; the six `tNNN-…` ticket branches, the integration branch, and the local worktree stay (developer cleans them up). Residual orb PRs #397/#399 auto-merged when their branches were merged into the integration branch — no action. The final merge to `main` is the human's act (the human boundary); the driver marks #385 ready for review and stops there.
