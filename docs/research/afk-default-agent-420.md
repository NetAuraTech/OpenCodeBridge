# AFK resident session: default agent + rules ride the feed (#420) — driver notes & spec

Spec: https://github.com/NetAuraTech/OpenCodeBridge/issues/420
Related (already merged): the AFK agent spec #376 + its notes in `docs/research/afk-agent-376.md`, the per-project rework #407, and the pilot findings #417. This ticket is a follow-up to the #417 pilot findings.

## Why (the defect class this kills)

The resident AFK session was created with a custom `afk` agent. Its definition — the **charter** (the standing rules + the human-boundary permission denials) — is a markdown agent file (`afk.md`) the app **installs into the host's global opencode config** (`~/.config/opencode/agents/afk.md`) at server-mode startup and **refreshes in place** (the app-owned-files contract, issue #141). The pilots showed the cost: a **stale on-disk copy** kept a running agent on outdated rules long after `main` moved on, and an entire install/refresh contract exists only to keep that one file honest.

The fix: the resident session runs the **default agent** (the same agent an interactive session gets) — the app installs and references **no** custom `afk` agent anywhere. The standing operational rules ride **the feed** the bridge already sends, so they are always the version shipped with the running app, with no on-disk agent state to go stale. The human-boundary denials are applied **to the resident session itself** as **per-session permissions at creation** (the service's create API carries them — verified, see below).

## Verified facts (the enforcement point)

The shared opencode service (v2.2.7, probed against the live `GET /openapi.json`) carries **per-session permissions at creation**:

- `POST /api/session` body has a `permissions` field: a `Permission.Ruleset` = an **array** of `Permission.Rule` `{ "action": string, "resource": string, "effect": "allow"|"deny"|"ask" }`.
- `Session.Info` (the `GET /api/session/{id}` response) **reports** `permissions` (the same `Permission.Ruleset`) — so the fact is readable back.
- The **old charter's frontmatter denials** are exactly `Permission.Rule` objects (it used `action: shell`, `resource: "git push --force *"`, `effect: deny`), so they map 1:1.

**Decision (enforcement point): the denials are enforced by per-session permissions at session creation** — `OpencodeService.createSessionInDirectory` gains an optional `permissions` argument and the HTTP layer posts it in the create body. This is the mechanism the spec names first ("per-session permissions at creation, where the service's API carries them") and the service's API **does** carry them (verified above). **Record this decision on issue #420 as a comment before the merge PR** (the spec's AC requires it), and capture it in the ADR. The rules' **words** (the human boundary) still ride the feed; the **denials** (the enforcement) ride the create call. A service that ignores the field degrades to the words in the feed only (accepted risk, noted in the ADR).

## What to build (the change map)

All under `app/`. The new module is `app/lib/bridge/afk/afk_rules.dart`.

### 1. NEW `app/lib/bridge/afk/afk_rules.dart`

The one home for the AFK standing rules, **versioned in the app source** (the reviewed source of truth, riding the feed). It holds:

- **`standingRules`** (a `static const String`): the canonical standing operational rules, as a plain-markdown block (no frontmatter). Adapt it from the **old `AfkCharter.canonical` body** (the sections, kept in full and in order): the dispatch discipline ("How you work: you dispatch, you do not type"), the `implement-spec` discipline, the human boundary, the wiki memory discipline, and the layered-memory note. **Adapt two things** while you adapt:
  - The old charter's **"What a feed is"** section said a feed was "a **pure availability notice**: an issue number and its title, nothing more." That is no longer true — every feed now **begins with the standing rules** and then carries the notice. Rewrite that section to say: a feed from the bridge begins with your standing rules (this block), then carries the availability notice (an issue number and title) or, on a recreation, the bootstrap list; on any feed you open the issue, read it, and drive it — you do not wait for the bridge to hand you details.
  - The old human-boundary section said the hard rules are "enforced by the permissions above (denied by the service)." The rules no longer live in a file with a frontmatter. Rewrite that line to say they are enforced as **denials on the session itself** (the session's permission rules), not just asked of you.
  - Keep the rest (identity, dispatch discipline, implement-spec steps, wiki discipline, the "a fact lives in exactly one layer" note) verbatim. Do **not** include a model line (the bridge pins the model at creation, unchanged).
- **`humanBoundaryDenials`** (a `static const List<Map<String, Object?>>`): the human-boundary denial rules as `Permission.Rule`-shaped maps, **the exact rules the old charter frontmatter carried** (action `shell`, effect `deny`):
  - `git push --force *`, `git push -f *`, `git push --force-with-lease *`
  - `git push origin main *`, `git push origin master *`, `git push origin HEAD:main`, `git push origin HEAD:master`, `git push origin main`, `git push origin master`
  - `gh pr merge *`, `gh pr merge`, `gh merge *`, `gh merge`
- **`availabilityNotice(int issueNumber, String title)`** (a top-level `String` function): the per-issue feed. It **begins with `standingRules`**, a blank line, a short divider/label, then the availability notice. The notice part must still be `Issue #$issueNumber: $title` (a test below depends on the full-feed containing that substring).
- **`bootstrapFeed(List<AfkRun> inFlight)`** (a top-level `String` function): the bootstrap feed (the fresh-agent handoff's first feed on session recreation). It **begins with `standingRules`**, a blank line, a label, then the in-flight run list. **Keep the existing run-listing format exactly** (the existing test `afk_run_service_test.dart` depends on it): the header line "Bootstrap — the AFK agent session was just recreated. These runs are in flight (from the bridge's store); reconcile with the tracker before continuing, so the restart loses no work:" then one line per run `- #<n> <title>: <state>` with ` (retry <c>, last failure: <reason>)` appended only when the run carries those fields.

The rules are pure (no I/O). The file has no dependency on the session seam.

### 2. `app/lib/bridge/sessions/opencode_service.dart` — the seam

- `createSession(String projectId, {ModelRef? model, String? agent, List<Map<String, Object?>>? permissions})` — add the `permissions` named arg.
- `createSessionInDirectory(String directory, {ModelRef? model, String? agent, List<Map<String, Object?>>? permissions})` — add the `permissions` named arg.
- A **new** operation to read a session's permissions back (the `Session.Info.permissions` the service reports — so the enforcement fact is observable in tests without a live service):
  `Future<List<Map<String, Object?>>> sessionPermissions(String id)` — **with a default implementation** that throws `UnimplementedError`, mirroring how the seam already gives `probe`/`waitIdle`/`canCancelTurn` defaults. **Why a default (not abstract):** the repo's many test fakes `extends OpencodeService` and rely on `noSuchMethod` for the operations they don't override (see e.g. `afk_component_test.dart`, `backend_test.dart`); a new *abstract* method would break every one of them, a *default* keeps them compiling. The HTTP layer overrides it; the tests that need it (the new ones) override it too.

### 3. `app/lib/bridge/sessions/opencode_http_service.dart` — the real client

- `_createBody(String directory, {ModelRef? model, String? agent, List<Map<String, Object?>>? permissions})` — add `if (permissions != null && permissions.isNotEmpty) 'permissions': permissions`. Thread the new arg from both `createSession` and `createSessionInDirectory`.
- Implement `sessionPermissions(String id)`: `GET /api/session/{id}` (reuse the existing `_sessionData`/`getDetail` read — whichever returns the session's `data` map), read `map['permissions']`, and return it as a `List<Map<String, Object?>>` (an absent/`null` field → empty list). Non-2xx propagates as `OpencodeServiceError` (as the existing reads do).

### 4. `app/lib/bridge/sessions/composite_service.dart`

- `createSession` / `createSessionInDirectory` already forward `model`/`agent` to `host` — **forward `permissions` too** (the create is host-only; the AFK session always lands on the host).
- `sessionPermissions(String id)` → `(await _route(id)).sessionPermissions(id)` (route by the `sessionID -> orb` table, same as every other per-session op; the AFK session is host-only so it resolves to the host).

### 5. `app/lib/bridge/afk/afk_session_manager.dart` — arming creates the default-agent session

- **Remove** `static const String agentId = 'afk';` and **stop passing** `agent:` to the create call. The resident session is now an **ordinary default-agent session**: the create call passes only the pinned model and the human-boundary permissions.
- `ensureSession({String? model})` now calls
  `sessions.createSessionInDirectory(directory, model: parseAfkModel(model ?? ''), permissions: afk_rules.humanBoundaryDenials)`.
  (Import `afk_rules.dart`.) The model pin is unchanged (empty = inherit).
- Update the class/`ensureSession` docs: the resident session is the **default agent**, its standing rules ride the feed (`afk_rules.dart`), and the human-boundary denials are applied to the session at creation (per-session permissions).

### 6. `app/lib/bridge/afk/afk_run_service.dart` — the feeds carry the rules

- **Delete** the local top-level `String availabilityNotice(int, String)` and `String bootstrapFeed(List<AfkRun>)` (they move to `afk_rules.dart`, now rule-prefixed).
- Import `afk_rules.dart`. The call sites keep their names: `availabilityNotice(run.issueNumber, run.title)` in `_feed`, and `bootstrapFeed(inFlight)` in `bootstrap` — now resolved from `afk_rules`.
- **Update the docs** that describe the feed as "the pure availability notice … nothing more (the charter's 'What a feed is')": the feed now **begins with the standing rules** (the rule's text) and then the notice; the bridge still hands over no issue details. Update the doc comments at `_feed`, `bootstrap`, and the class-level description of the `idle → dispatched` feed and the bootstrap accordingly (the rules ride in-band; there is no on-disk charter anymore).

### 7. `app/lib/bridge/bridge_server.dart` — drop the install

- Remove the `import 'afk/afk_charter.dart';`.
- Remove the server-mode block that calls `await AfkCharter.install();` (the `if (bootstrapOpencode != null) { try { await AfkCharter.install(); } catch (_) {} }` block, ~lines 482–494). The app no longer installs an `afk` agent anywhere.

### 8. DELETE the install/refresh contract and its tests

- `app/lib/bridge/afk/afk_charter.dart` (the canonical file, `install`, `previousDigests`, `hostAgentsDir`, `hostCharterFile`, `agentId`).
- `app/test/bridge/afk/afk_charter_test.dart`.

### 9. Tests

- **NEW `app/test/bridge/afk/afk_rules_test.dart`**:
  - `standingRules` is non-empty and contains the standing-rule markers (dispatch discipline, `implement-spec`, the human boundary, the wiki discipline) — e.g. contains "implement-spec", "human boundary" / "Never merge", "wiki".
  - `availabilityNotice(n, title)` **begins with `standingRules`** (its `startsWith(standingRules)`) and **contains** `Issue #$n: $title`.
  - `bootstrapFeed([...])` **begins with `standingRules`** and preserves the run-listing format (reuse/adjust the assertions from the old `bootstrapFeed` test in `afk_run_service_test.dart`).
  - `humanBoundaryDenials` is the set of denial rules: every entry has `effect == 'deny'` and `action == 'shell'`, and the set contains the force-push / default-branch / merge resources (assert the resource strings are present, as the old `afk_charter_test.dart` did).
- **`app/test/bridge/afk/afk_component_test.dart`** (the `_FakeService` + the `AfkSessionManager` group):
  - `_FakeService.createSessionInDirectory` records the `permissions` it is passed (add a `createPermissions` field); it already records `createAgent`.
  - **Change** the test `creates the session in the directory with agent afk` → `creates the session with the default agent and the human-boundary permissions`: assert `service.createAgent` is **`null`** (no agent override) and `service.createPermissions` **is not null and equals `humanBoundaryDenials`** (the denials ride the create call).
  - The other `AfkSessionManager`/`AfkComponent` tests (model pin, reuse, restart-reuse, two repos, directory resolution, spawn gate) are unchanged and must still pass.
- **`app/test/bridge/afk/afk_run_service_test.dart`**:
  - **Move/delete** the two feed-text tests (`availabilityNotice is the issue number + title, nothing more` and the `bootstrapFeed lists the in-flight runs …` test) to `afk_rules_test.dart` (the functions moved). Where a test only asserts the notice part, assert it now as a **substring of the rule-prefixed feed** (the rules ride in front). Keep every other test (the state machine, the retry, the narration, the liveness, the bootstrap wiring) green.
  - If the tests referenced the feed as a bare notice in any prompt assertion, update those to expect the rule-prefixed feed (the fake session port records the prompt text).
- **`app/test/bridge/sessions/opencode_http_service_test.dart`**: add that `createSessionInDirectory` **posts the `permissions` array in the create body** (mirror the existing "posts the pinned model ref" / "posts no model key" tests), and **posts no `permissions` key** when none is passed.
- **`app/test/bridge/sessions/composite_service_test.dart`** (optional but cheap): the create forwards `permissions` to the host, and `sessionPermissions` routes by owner.
- Search the whole test tree for any reference to `agentId`, `'afk'` as an agent, `AfkCharter`, or the feed being a "pure availability notice" and update/remove each. The only legit `'afk'` string left anywhere is the settings namespace (`afk.`) and the `afk` directory — no agent reference.

### 10. `GLOSSARY.md`

The **AFK agent** entry currently says "One resident opencode session per armed project … the bridge feeds it the project's ready issues." Add one clause that the resident session runs the **default agent** and its standing rules ride the feed (no custom agent). Keep the "never merges / force-pushes / deletes: runs end at a PR" sentence. Use the glossary vocabulary.

### 11. ADR — `docs/adr/0009-afk-resident-default-agent.md`

Follow the format of `docs/adr/0008-opencode-service-as-second-app-owned-child.md` (title, `- **Status**: accepted (date, ticket #420)`, `## Context`, `## Decision`, `## Consequences`). Record:

- **Context**: the resident AFK session ran a custom `afk` agent whose charter (standing rules + human-boundary denials) was installed/refreshed on disk (the app-owned-files contract); the #417 pilots showed a stale on-disk copy kept a running agent on outdated rules and the whole install/refresh contract exists to keep one file honest.
- **Decision**:
  1. The resident session runs the **default agent** (no agent override on create; the app installs and references no custom `afk` agent; the on-disk agent file, the install/refresh contract, and their tests are deleted).
  2. The **standing rules ride the feed**: every feed the bridge sends to the resident session (the per-issue availability notice and the bootstrap on recreation) begins with the standing operational rules, versioned in the app source (`afk_rules.dart`), so the rules are always the shipped version with no on-disk state to go stale.
  3. The **human-boundary denials** (no merge, no force-push, no push of the default branch) are enforced on the resident session itself as **per-session permissions at creation** — the verified enforcement point (the service's `POST /api/session` carries `permissions`; `Session.Info` reports them). The words ride the feed; the denials ride the create call.
- **Consequences**: a rework of the standing rules ships with the app and reaches the running session on its next feed (no refresh contract, no stale-agent defect class); a resident session is now indistinguishable from an interactive session except for its feed and its session-level permission denials; a service that ignores the create-time `permissions` field degrades to the feed's words only (the denials are not enforced) — accepted, noted; the host's `~/.config/opencode/agents/afk.md` is no longer written by the app (a pre-existing copy is left in place; the app no longer reads it).

### 12. Record the enforcement decision on the issue (required before merge)

Run `gh issue comment 420 --body "…"`: state the **chosen enforcement point** — per-session permissions at session creation (`POST /api/session` `permissions`, verified on the service v2.2.7 OpenAPI; reported back on `Session.Info.permissions`) — and **why** (it is the mechanism the spec names first, it is verified to be carried by the API, it scopes the denials to the resident session only, and the rules' words still ride the feed so a rules rework needs no re-arm).

## Workflow (the branch contract for the implementing agent)

- The work lives on the **integration branch** `integrate/afk-default-agent-420` (base `origin/main`). This note is committed on that branch — read it there; it is the single pointer.
- Commit in conventional style, run the verification command, and push the branch. Do **not** merge to `main` (the human boundary) and do **not** open the final merge PR — the driver does that.
- One branch contract: all of #420 lands on `integrate/afk-default-agent-420`; the driver merges it to `main` and opens the final PR carrying `Closes #420`.

## Verification (run at the repo root before reporting done)

The single local verification command (fast local sequence; CI's Linux release build is not part of it):

    cd app && flutter pub get --enforce-lockfile && flutter analyze && dart format --set-exit-if-changed --output=none lib test && flutter test --exclude-tags docker

**Expected: zero failures on the clean base, in either environment** (a non-root host, or the root orb sandbox). A green run = **no failing tests** plus the environment-appropriate self-skips (never judge on a count):
- **Root (the orb sandbox runs as root)**: the permission-denial tests self-skip (a mode-000 dir is still writable as root), the entrypoint default-config/fallback tests self-skip when the sandbox exports `GH_CONFIG_DIR`/`ORB_BASE_BRANCH`/`ORB_BRANCH`, and the throwaway-container state-dir delete test self-skips (a recursive delete cannot fail as root).
- **Non-root host**: when a real docker CLI is on PATH or a shared opencode service descriptor is present, the tests that would reach the docker/opencode fake seams self-skip (the bridge builds a real backend there).

The host's Flutter may differ from CI's pinned version: if `--enforce-lockfile` or `flutter analyze` report **pre-existing** host-only issues on the clean base, treat them as environmental (compare against a clean-base run); do **not** commit a regenerated `pubspec.lock` from the host. The authoritative local gate is the **zero-failure test run + `dart format` clean**.

Commit style: conventional commits, `type: scope — summary` (lowercase summary, em dash), e.g. `feat: bridge — afk resident session runs the default agent, rules ride the feed`. A pre-commit hook refuses unformatted Dart — run `dart format` on touched files.
