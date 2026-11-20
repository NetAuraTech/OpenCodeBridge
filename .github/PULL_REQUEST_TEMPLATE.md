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
- Verification result: `verification matches the clean-base signature (root AGENTS.md, Verification section)` — the one-line result reported against the canonical clean-base signature. Replace this line only when the run deviates; a full results paragraph is required only on deviation, and a deviation is reportable only after reproduction on a clean base.
