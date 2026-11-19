# Orb driver rule: verify the remote branch before merging any orb work

A workflow rule for any agent that dispatches orbs (or merges an orb's work). The orb's self-report is **a claim, not a fact**: an implementer session can report "committed and pushed" while the push never reached the remote. Observed live on 2026-11-19 (ticket #346 fixups): the local commit was intact, but `git ls-remote origin` showed no such branch. The work was recovered only because the driver re-dispatched and forced an explicit push.

## The rule

1. **After the orb reports done, before the merger is invoked**, the driver runs:

       git ls-remote origin <branch>

   where `<branch>` is **the one branch the completion report carries** (issue #353, the one branch contract) — the named branch the task gave the orb (`orb_spawn`'s `branch` argument, e.g. `t346-review-fixups`), or the orb's internal default `orb/<id>` when the task named none. That single branch is what the post-commit hook pushed and what the orb's git state lives on.

2. **Remote branch missing ⇒ re-dispatch or an explicit failure, never a merge attempt.** Ask the orb to re-verify its local state and re-push (e.g. `git push origin HEAD:<branch>`). If it still fails, the driver reports the task as failed with the `ls-remote` output as evidence — not a merge attempt on the orb's word.

3. **Remote sha mismatch ⇒ failure.** The driver confirms the remote sha matches the sha the orb reported. A stale or divergent push is a failure, not a silent merge.

## The positive path

When both checks pass — the branch exists on the remote and its sha matches the orb's report — the driver proceeds: the merge PR may be opened (or the merge invoked) against that exact sha. If a check fails, the only permitted actions are re-dispatch (step 2) or reporting the task failed with the `ls-remote` output attached.
