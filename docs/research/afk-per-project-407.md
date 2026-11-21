# AFK agent per-project (#407) — driver notes & shared contract

Spec: https://github.com/NetAuraTech/OpenCodeBridge/issues/407
Tickets: #408 (T1), #409 (T2), #410 (T3), #411 (T4), #412 (T5), #413 (T6).

## Task graph (native GitHub dependencies)

```
T1 #408 (foundation: repo identity, armedRepos, per-repo store keys)
 ├─ T2 #409 (reader working dir + poller per armed project)
 ├─ T3 #410 (session per repo: create/reuse, arming diff, bootstrap)
 │    ├─ T4 #411 (run service per-repo routing/liveness/reconciliation; also blocked by T2)
 │    └─ T6 #413 (UI per-project arm toggle + failure push deep-link per repo)
 └─ T5 #412 (spawn gate set of AFK sessions, cap host-total)
```

## Driver context (do not lose)

- Spec issue #407 (the map), tickets #408–#413 — `gh issue view <n>` for the full ticket text; the spec body's "Implementation Decisions" is the authoritative design.
- Integration branch: `integrate/afk-per-project-407` on origin (base `origin/main` @ `8566d98`, which already carries the merged #376 AFK system).
- One draft PR: `origin/integrate/afk-per-project-407` → `main`, body carries `Closes #407, #408, #409, #410, #411, #412, #413`.
- Worktrees: `../opencodebridge-wt/integrate-afk407` (the driver's).

## Repo context for implementers

- The #376 AFK system is on your base: `app/lib/bridge/afk/` (afk_settings, afk_charter, afk_store, afk_session_manager, afk_component, afk_ready_gate_poller, afk_run_service, afk_run_state, afk_spawn_gate, github_reader), the spawn boundary in `app/lib/bridge/orb/orb_task_service.dart` (the `afkGate` closure), the push in `app/lib/bridge/notify/push_dispatcher.dart`, the settings in `app/lib/settings/app_settings.dart` + `app/lib/ui/settings_tab.dart`, the project rows in the sidebar (`app/lib/ui/` home shell / project picker), the composite sessions backend in `app/lib/bridge/sessions/`.
- This spec RESHAPES #376, it does not add a parallel system: repo identity, per-repo keys, per-repo sessions, a set-based spawn gate. The pure state machine (`afk_run_state.dart`) stays untouched.
- Key decisions (spec "Implementation Decisions" — read it): cap is the HOST TOTAL; arming is per project (per repo identity); two checkouts of the same repo share one armed state + one session (first list-order project); no `origin` → not armable; no store migration (legacy flat keys are ignored by the tolerant decode); the failed push deep-links the REPO's session.
- Prior art for the per-project UI: the existing project picker rows and their dropdowns (server-mode-only sections like the tunnel one).
- Local verification (fast): `cd app && flutter pub get --enforce-lockfile && flutter analyze && dart format --set-exit-if-changed --output=none lib test && flutter test --exclude-tags docker`. The sandbox runs as root: the documented environmental failure families (permission-denial, GH_CONFIG_DIR/ORB_BRANCH entrypoint, root-owned state dir) fail or self-skip there and pass on CI's non-root runners — the gate is ZERO NEW FAILURES vs the clean base (verify by stash/re-run if anything looks off). No CMake in the sandbox — the CI release build is out of the local command.
- Commit style: conventional, `type: scope — summary`. Pre-commit hook refuses unformatted Dart (`dart format` touched files). The one branch contract: commit on the named branch; the post-commit hook pushes it.
- Do NOT label anything `ready-for-agent` — this spec is human-driven (Phase-1 rule, #407 "Build sequencing").

## Per-ticket branch contract (the driver hands the exact branch to each implementer)

| Ticket | Branch | Base |
|---|---|---|
| #408 T1 | `t408-afk-per-project-foundation` | integration branch |
| #409 T2 | `t409-afk-per-project-reader-poller` | integration branch (post-T1) |
| #410 T3 | `t410-afk-per-project-session` | integration branch (post-T1) |
| #411 T4 | `t411-afk-per-project-run-service` | integration branch (post-T2+T3) |
| #412 T5 | `t412-afk-per-project-cap` | integration branch (post-T1) |
| #413 T6 | `t413-afk-per-project-ui-push` | integration branch (post-T1+T3) |
| review fixups | `t407-review-fixups` | integration branch tip |

## Shared implementation contract (all tickets)

- **Repo identity**: `owner/repo` from the project's `origin` remote (`git -C <dir> remote get-url origin`, the bridge's `Process.run` pattern); a pure `parseRepoIdentity(String remoteUrl)` (https + ssh, with/without `.git`, junk → `null`); `repoIdentityOf(Directory)` → `null` on any failure. One module: `app/lib/bridge/afk/repo_identity.dart` (T1).
- **Armed state**: `AfkSettings.armedRepos` (set of `owner/repo`); persisted `afk.armedRepos` (JSON list, `afk.` namespace, default empty); `enabled`/the global toggle go away (the global arming toggle is removed from the Settings section in T1; arming arrives per-project in T6).
- **Store keys**: `afk.session.<owner/repo>`, `afk.run.<owner/repo>.<issue>`; `AfkRun.ownerRepo` field; accessors `sessionIdFor(repo)`, `runsFor(repo)`, `allRuns()`; legacy flat keys never written, ignored on read (tolerant decode).
- **Reader**: `GhGitHubReader` takes a required working directory; all `gh` calls pass `workingDirectory:`.
- **Events**: `afk.ready_admitted`, `afk.pr_open`, `afk.failed` gain the repo identity in their `data` (T2/T4).
- **Spawn gate**: the set of AFK session ids (all armed repos) + the global cap; `isAfk` = set membership; counter = all AFK-attributed orbs in flight (T5).
- **Push**: `afk.failed` deep-links the repo's session (resolved live from the store); `afk.pr_open` unchanged (PR URL, external browser) (T6).
- **Layer rule / human boundary**: unchanged from #376 — charter holds standing rules (repo-agnostic), the store holds machine state, the agents never merge/force-push/push the default branch/mutate a checkout.

## Orbs available to the driver

- `t1` — #408; `t2` — #409; `t3` — #410; `t4` — #411; `t5` — #412; `t6` — #413; `review` — fixups.
- Orb base dir `/workspace`; the named branch is checked out on creation (creation-time tip). Work persists on the branch (auto-pushed).

## Driver checklist after each orb report

1. `git fetch origin <branch>` — the branch must exist on origin at the reported sha (a `push_unverified` report = re-dispatch, never a merge on the orb's word).
2. `git merge --no-ff` onto `integrate/afk-per-project-407` (in the worktree), full local verification (zero new failures vs the clean base), push.
3. Update this file's done list (commit to the integration branch — orbs only see git).

## Done (driver appends)

- [x] T1 #408 — merged (branch `t408-afk-per-project-foundation` @ 65c3177d, merge `cd150e2`). Landed: `app/lib/bridge/afk/repo_identity.dart` (pure `parseRepoIdentity` https/ssh ± `.git`, junk → `null`; `repoIdentityOf` wraps `git -C <dir> remote get-url origin`, `null` on failure), `AfkSettings.armedRepos` (ordered set, replaces `enabled`) + `firstArmedRepo` anchor, `AppSettings` persistence `afk.armedRepos` (JSON list, corrupt → empty) + the global arming toggle removed from the Settings section (cap + model kept), `AfkStore` re-keyed (`afk.session.<o/r>`, `afk.run.<o/r>.<n>`, `AfkRun.ownerRepo`, `sessionIdFor`/`runsFor`/`allRuns`, legacy flat keys ignored on read + dropped on write). T1 consumer adaptations (the transitional single-anchor shape — T2–T5 replace it): `afk_component.dart` anchors everything on `firstArmedRepo` (`enabled` = `armedRepos.isNotEmpty`, lazy per-repo session manager seeded from `store.sessionIdFor(repo)`); `afk_ready_gate_poller.dart` takes a live `repo` closure (inert when no repo); `afk_run_service.dart` walks `store.allRuns()`; `bridge_server.dart` wires the poller predicate + failure-push deep-link through the component. T2 replaces the poller's single `repo` closure with the armed-project iteration; T3 replaces the `firstArmedRepo` anchor with the per-repo arming diff; T5 replaces the single-id gate with the set.
- [x] T2 #409 — merged (branch `t409-afk-per-project-reader-poller` @ fc61223f). Landed: `GhGitHubReader` takes a REQUIRED `workingDirectory` (all 7 `gh` calls pass it — the #405 root cause is gone) + an optional `ghBinary` test seam (the injectable-CLI pattern); the poller is replaced — it takes the arming set (live), a repo-directory provider (`Future<Map<String,String>> Function()` repo identity → checkout dir), and a per-repo reader builder (`(repo, directory) → GitHubReader`); each tick iterates the armed repos, admits repo-scoped rows + one `afk.ready_admitted` event each with the repo in `data`; per-repo rules: no dup per (repo, issue), legacy flat rows invisible to the dedup, a disarmed repo inert, a failed read inert for that repo only, a repo with no resolvable checkout inert for the tick. Bridge wiring: `BridgeServer._afkRepoDirectories(armedRepos, backend)` resolves each armed identity to the first list-order project whose `repoIdentityOf(canonical)` matches (re-resolved each pass; a closed checkout drops out until it reappears); `readerFor` → `GhGitHubReader(workingDirectory:)`. **Known transitional shape (T4 replaces it)**: the RUN SERVICE's reader is still the pre-T2 single reader on `Directory.current` — T4 does the per-repo run-service routing (each row read through its own repo's reader/directory); T2 left that untouched on purpose. T4 must give the run service the same per-repo reader the poller has (reuse the provider/builder wiring in `bridge_server.dart`).
- [x] T3 #410 — merged (branch `t410-afk-per-project-session` @ 50b858ad, merge `f1a71c7`; branched pre-T2 — conflict in `bridge_server.dart` resolved keeping T2's per-project poller wiring + T3's `_afkSessionResolver`). Landed: `afk_component.dart` reshaped — one `AfkSessionManager` per repo (keyed `owner/repo`, lazy, seeded from `store.sessionIdFor(repo)`, never evicted so a re-arm reuses), `sessionIdFor(repo)`, `isArmed(repo)` (live `armedRepos`), `ensureSession(repo)` = the per-repo arming action (create-or-reuse in the repo's own checkout via an injected `directoryOf` provider, model from global `afkModel`, agent `afk`, id stored under `afk.session.<owner/repo>`); disarm holds everything (session + id outlive it). `afk_run_service.dart` — `AfkSessionPort` repo-scoped (`sessionId(repo)`, `prompt(repo, text)`, `waitIdle(repo, …)`), `bootstrap(repo)` scoped to `store.runsFor(repo)` (a run of another repo never appears in the feed). `bridge_server.dart` — `updateAfKSettings` computes the old→new arming diff and ensures each newly armed repo's session; per-repo bootstrap fires only when the id was just created (a normal restart reuses → no re-bootstrap); the `afk.failed` event data gains `repo` and `PushDispatcher.afkSession` is `Future<String?> Function(String repo)` (T6 consumes exactly this). T3 also pre-shaped the spawn gate as a set (superseded by T5's ticket — see below). **Kept as transitional, explicitly T4's job**: the run service's liveness closure still reads `firstArmedRepo` in `_afkLiveness` → REPLACED by T5 (set via `store.allSessionIds()`); T4 still owns the per-repo run-service reader + liveness/reconciliation.
- [x] T5 #412 — merged (branch `t412-afk-per-project-cap` @ d2646996, merge `1d4466b`; branched pre-T2 — 5-file conflict resolved: T5's version wins the gate/counter/liveness, T3's session layer kept, T5's tests adapted to T3's per-repo component API (`mkComponent(repos:)`, `ensureSession(repo)`)). Landed: `AfkSpawnGate` now `AfkSpawnGate({required this.sessionIds, required this.cap})` with `sessionIds` (Set) + `isAfk(String?)` = membership (null/empty ignored, empty set attributes nothing) — the `afkSessionId`/`afkSessionIds` single-shapes are gone; `AfkStore.allSessionIds()` = every stored `afk.session.<o/r>` id (deduped, legacy flat key ignored — the **disarming-stable** set: a disarm never deletes a stored id); `AfkComponent.spawnGate()` builds the set live from `store.allSessionIds()`, `null` when nothing armed or no id stored; `OrbTaskService._afkOrbsInFlight` counts orbs whose CREATING task's caller is IN THE SET (one host-total counter across all repos); refusal posture unchanged (idempotent retry first, refusal before any orb, "N in flight of M" + positive path, turn not ended, developer spawns never capped, cap live from the next spawn); disarm while in flight: the counter keeps the orb until it settles (attribution = the creating task's persisted caller, not the current arming). `bridge_server.dart` `_afkLiveness` now reads the set via `store.allSessionIds()` and calls `tasks.afkOrbsInFlight(ids)`. Tests: AC1–AC5 rewritten for the set (2 repos armed / cap 2, both sessions' refusals name "2 in flight of 2") + AC6 (disarm while in flight keeps counting) + host-total counter + `allSessionIds` tests. **T4's exact signatures**: `AfkSpawnGate({required this.sessionIds, required this.cap})`, `bool isAfk(String?)`, `OrbTaskService.afkOrbsInFlight(Set<String> afkSessionIds)`, `AfkStore.allSessionIds()` — T4's run-service liveness reads the same counter with `store.allSessionIds()`.
