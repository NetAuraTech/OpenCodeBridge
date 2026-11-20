# AGENTS.md

## Agent skills

### Issue tracker

Issues and specs live as GitHub issues on `NetAuraTech/OpenCodeBridge`, managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary, each label equal to its role name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout: `GLOSSARY.md` at the root, ADRs in `docs/adr/`. See `docs/agents/domain.md`.

## Verification

Run the single local verification command — the fast local sequence (lockfile enforcement + analyze + format + test; CI's Linux release build is not part of it) — from the repo root before considering any change done:

    cd app && flutter pub get --enforce-lockfile && flutter analyze && dart format --set-exit-if-changed --output=none lib test && flutter test --exclude-tags docker

**Expected outcome — check your run against this.** The invariant: **zero failures on a clean base in either environment** (a non-root host, or the root orb sandbox). A green run is a run with no failing tests; the skips below are expected and self-explanatory, so match your run on *no failures* plus the skips that fit your environment — not on any count. A deviation is real only once reproduced on the clean base.

Skips are named by the reason that triggers them (what to look for, never a number):

- **Root — the orb sandbox runs as root:**
  - the permission-denial tests self-skip — *permission denial cannot be exercised as root* (a mode-000 dir is still listable and writable as root, so the denial branch is unreachable);
  - the entrypoint default-config tests self-skip when the sandbox exports `GH_CONFIG_DIR` / `ORB_BASE_BRANCH` — the variable is set in the parent environment and *leaks into the fake container*, so the default-config assertion is no longer the one under test;
  - the throwaway-container state-dir delete test self-skip — *a recursive delete cannot fail as root*, so the `on FileSystemException` fallback is unreachable.
- **Non-root host — the environment-conditional skip family:** when a real *docker CLI on PATH* or a shared *opencode service descriptor* is present, the tests that would otherwise reach the docker / opencode fake seams self-skip, because the bridge builds a real backend there and the fake seam is no longer the one under test.

## Orb sandbox

Dispatched orbs (the `orb_spawn` tool) run a git clone of this repo at `/workspace` with the same toolchain as CI: Flutter 3.47.8, Dart 3.13.7, git, `gh`. Known quirks: the sandbox runs as **root**, so tests that simulate permission denial or unset `GH_CONFIG_DIR` fail there (they pass on CI's non-root runners — treat them as environmental, reproduce on the clean base before flagging). The one branch contract (issue #353): the task **names the branch** (`orb_spawn`'s `branch` argument) — the orb's git state lives on that branch, its agent commits there, and the post-commit hook auto-pushes **that one branch** after every commit; the completion report carries it as its single branch artifact. `orb/<id>` is only the internal default the bridge passes when no branch is named, and it never appears as the reported artifact. Before merging any orb work, verify its branch actually reached the remote — see `docs/agents/orb-verify-remote-merge.md` (the orb's self-report is a claim, not a fact: `git ls-remote origin <branch>` after it reports done, before the merger is invoked).
