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

- [ ]
