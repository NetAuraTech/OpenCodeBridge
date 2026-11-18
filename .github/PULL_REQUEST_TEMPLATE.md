<!--
Line 1 of the body MUST keep a closing keyword so GitHub closes the
issue(s) on merge: `Fixes #<n>` (or `Fixes #<n>, #<m>`). "Implements",
"Part of" and "Related to" do NOT close an issue (docs/agents/
issue-tracker.md). Replace the number and delete this comment before
publishing.
-->
Fixes #

## Why

(One or two sentences: the concrete problem — the leak, the behavior, the
coupling — and where it lives when it is not obvious from the diff.)

## What changed

(Bullets: the seam / file and the new posture or behavior. For
degradation-sensitive work, state each fact's degradation posture.)

## Acceptance

- [ ] (From the issue, or the behavior this PR locks.)

## Tests

- (Name the tests and what each asserts, with their files.)

`flutter analyze` and `dart format --set-exit-if-changed --output=none lib test` are clean; `flutter test --exclude-tags docker <paths>` passes.
