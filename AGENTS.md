# AGENTS.md

## Agent skills

### Issue tracker

Issues and specs live as GitHub issues on `NetAuraTech/OpenCodeBridge`, managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary, each label equal to its role name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout: `GLOSSARY.md` at the root, ADRs in `docs/adr/`. See `docs/agents/domain.md`.

## Verification

Run the single local verification command — exactly the CI's sequence — from the repo root before considering any change done:

    cd app && flutter pub get --enforce-lockfile && flutter analyze && dart format --set-exit-if-changed --output=none lib test && flutter test --exclude-tags docker
