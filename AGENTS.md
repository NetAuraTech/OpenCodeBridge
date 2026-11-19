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

## Orb sandbox

Dispatched orbs (the `orb_spawn` tool) run a git clone of this repo at `/workspace` with the same toolchain as CI: Flutter 3.47.8, Dart 3.13.7, git, `gh`. Known quirks: the sandbox runs as **root**, so tests that simulate permission denial or unset `GH_CONFIG_DIR` fail there (they pass on CI's non-root runners — treat them as environmental, reproduce on the clean base before flagging); the post-commit hook auto-pushes the `orb/<id>` branch, and the ticket branch named in the task text is pushed separately. Before merging any orb work, verify its branch actually reached the remote — see `docs/agents/orb-verify-remote-merge.md` (the orb's self-report is a claim, not a fact: `git ls-remote origin <branch>` after it reports done, before the merger is invoked).
