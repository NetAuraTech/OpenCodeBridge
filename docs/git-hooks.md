# Git hooks

## pre-commit — the Dart format check

The committed hook `scripts/git-hooks/pre-commit` refuses Dart commits that do not pass the formatter, before a PR is opened. It runs the same `dart format` flags CI uses (`dart format --set-exit-if-changed --output=none`), from `app/`, on the **staged** app/ Dart files (`lib` and `test`) only — a clean commit has no friction, and a commit with no staged Dart file is a no-op.

Scope: formatting only. The hook is fast and needs no network; the analyzer (`flutter analyze`) deliberately stays at CI.

### Activate it (one line)

From the repo root, once per clone:

```sh
git config core.hooksPath scripts/git-hooks
```

The hook is committed to the repo, so every contributor activates it with this one config line — no per-machine hook copy.

### Deliberate bypass

`git commit --no-verify` skips the hook. The hook itself says so when it refuses, and when it cannot run `dart` at all.
