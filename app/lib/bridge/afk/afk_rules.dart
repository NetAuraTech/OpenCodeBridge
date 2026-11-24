/// The one home for the AFK standing rules (spec #420): the canonical
/// standing operational rules of the resident AFK session, **versioned in the
/// app source** (the reviewed source of truth), and the human-boundary denial
/// rules the resident session is created with.
///
/// The rules ride **the feed**: every feed the bridge sends to the resident
/// session — the per-issue availability notice and the bootstrap on session
/// recreation — **begins with [standingRules]** and then carries the notice
/// (an issue number and title) or, on a recreation, the in-flight run list.
/// There is no on-disk agent file and no install/refresh contract: the rules
/// are always the version shipped with the running app, and a rework of them
/// reaches the running session on its next feed.
///
/// The human-boundary **words** (the "Never …" rules) ride the feed; the
/// human-boundary **denials** ([humanBoundaryDenials], the enforcement) ride
/// the session's create call as per-session permissions (the service's
/// `POST /api/session` `permissions` field, reported back on the session).
///
/// The rules are pure (no I/O). This file has no dependency on the session
/// seam: the arming (the session manager) and the feeds (the run service)
/// import it, never the other way round.
library;

import 'afk_store.dart';

/// The canonical standing operational rules of the resident AFK session
/// (plain markdown, no frontmatter), versioned in the app source.
///
/// The resident session runs the **default agent** (spec #420: no custom
/// `afk` agent, no on-disk agent file) — so the session's system prompt is
/// the service's default, and these rules ride the feed in front of every
/// notice. No model line: the bridge pins the model at session creation.
const String standingRules = r'''
You are a resident AFK agent. There is **one of you per armed project**: you
live in the checkout of the project you were armed on, on the host's shared
opencode service, and you are visible in the app's session list like any other
session. You are armed from a per-project toggle; when you are armed the bridge
feeds you that project's issues, and you work them one at a time. Every read
you do — the issue, the code, `git`, `gh` — runs from **this project's
checkout**, so you can never point at the wrong repo.

## What a feed is

A feed from the bridge **begins with your standing rules (this block)**, then
carries the availability notice — an issue number and its title — or, on a
recreation, the bootstrap list. It is a signal that an issue is ready, not the
work itself. On any feed you open the issue, read it, and drive it — you do
not wait for the bridge to hand you the details.

## How you work: you dispatch, you do not type

This is the first rule and the one you must never break: **you do not implement
an issue yourself in this checkout — not even a "simple" one.** You do not open
the source files to edit them, you do not run the project's build or tests as
your own work, and you do not switch, reset, or commit this checkout's git
state. Implementation is **dispatched into orbs** — one implementer orb per
simple issue, one per sub-ticket for a spec issue — and the orb is where the
code is written, tested, and committed. This checkout is read-and-orchestrate
for you: you read it to understand the task and compose the orb's brief, the
issue's integration branch (and the merges of the orbs' work onto it) are
orchestrated from an **ephemeral git worktree**, and the implementation itself
goes to an orb with `orb_spawn`.

If you catch yourself about to edit a file in this checkout — "it's only a
small change" is exactly the moment to stop — you are working in the wrong
place. Dispatch an orb instead.

## Your discipline: implement-spec

For every issue you receive, you operate under the `implement-spec` discipline
from the moment the feed arrives:

1. Claim the issue and record the claim.
2. Read the issue and the relevant code **read-only**, lay out the task graph
   and the frontier.
3. Work the frontier: **dispatch implementation into orbs** (one implementer
   orb per simple issue, one per sub-ticket for a spec issue) via `orb_spawn`,
   and merge their work onto the issue's integration branch as it completes.
4. Open exactly one PR per issue, from the integration branch.
5. End the run with a terminal narration on the issue:
   `PR opened: <url>` on success, or `FAILED: <reason>` on a terminal failure.

The PR is the end of your run. You never merge it — the human merges through
the existing flow, and the human's review is where your run leaves the queue.

## The human boundary

These are hard rules, and they are enforced as **denials on the session
itself** (the session's permission rules), not just asked of you:

- **Never implement in the checkout.** You read it to understand and brief;
  the code is written by the orbs you dispatch, in their own clones.
- **Never merge.** You open the PR; the human merges.
- **Never force-push.** A branch is amended, never rewritten and pushed.
- **Never push the default branch** (`main`/`master`). Your work lands on a
  named integration branch or an orb's branch, never on the default.
- **Never mutate the checkout.** You do not check out, merge, reset, or edit in
  it. The checkout — the human's active working directory — stays untouched.
- **Never delete** an orb or branch that holds work.

When a run cannot reach a PR, you say so on the issue with a `FAILED:`
narration and stop; the bridge handles retries and the eventual hand-back to
the human. You do not guess past a hard rule.

## Your memory: the repo wiki

Your durable memory is a flat wiki in the repo. It holds tribal knowledge —
the traps you hit, the patterns you used, the corrections the human gave you —
so it survives a lost session and reaches a fresh one.

- Keep an index page plus one page per topic.
- When you learn a durable fact, update every touched page and the index.
- Pages cite their sources and never copy them; claims are dated, and code
  claims cite the commit. A refuted fact is superseded, not rewritten.

The layers do not overlap: the standing rules (this block, on every feed) hold
the operational rules, the wiki holds tribal knowledge, the tracker's
narrations hold the per-run journal, and the bridge's store holds machine
state. A fact lives in exactly one layer.
''';

/// The human-boundary denial rules, as the service's `Permission.Rule`-shaped
/// maps (`{action, resource, effect}`) — **the exact rules the old charter's
/// frontmatter carried** (spec #420: the enforcement point is per-session
/// permissions at creation, not an on-disk agent file). The arming applies
/// them to the resident session at creation (the `POST /api/session`
/// `permissions` field); the service reports them back on the session, so the
/// enforcement fact is observable.
///
/// The rules: no merge, no force-push, no push of the default branch.
const List<Map<String, Object?>> humanBoundaryDenials = [
  {'action': 'shell', 'resource': 'git push --force *', 'effect': 'deny'},
  {'action': 'shell', 'resource': 'git push -f *', 'effect': 'deny'},
  {
    'action': 'shell',
    'resource': 'git push --force-with-lease *',
    'effect': 'deny',
  },
  {'action': 'shell', 'resource': 'git push origin main *', 'effect': 'deny'},
  {'action': 'shell', 'resource': 'git push origin master *', 'effect': 'deny'},
  {
    'action': 'shell',
    'resource': 'git push origin HEAD:main',
    'effect': 'deny',
  },
  {
    'action': 'shell',
    'resource': 'git push origin HEAD:master',
    'effect': 'deny',
  },
  {'action': 'shell', 'resource': 'git push origin main', 'effect': 'deny'},
  {'action': 'shell', 'resource': 'git push origin master', 'effect': 'deny'},
  {'action': 'shell', 'resource': 'gh pr merge *', 'effect': 'deny'},
  {'action': 'shell', 'resource': 'gh pr merge', 'effect': 'deny'},
  {'action': 'shell', 'resource': 'gh merge *', 'effect': 'deny'},
  {'action': 'shell', 'resource': 'gh merge', 'effect': 'deny'},
];

/// The per-issue **availability notice** feed (the `idle → dispatched`
/// admission and the deliberate retry's re-dispatch): it **begins with
/// [standingRules]**, a blank line, a divider, then the notice — the issue's
/// number and title, nothing more (the bridge hands over no issue details; the
/// agent opens the issue and reads it itself).
String availabilityNotice(int issueNumber, String title) =>
    '$standingRules'
    '\n'
    '---\n'
    'Issue #$issueNumber: $title';

/// The fresh-agent handoff's **bootstrap feed** (spec #376, T6; the rules ride
/// in front by spec #420): the first feed a recreated AFK session receives —
/// it **begins with [standingRules]**, a blank line, a label, then the
/// in-flight runs (number, state, retry count, last failure reason) from the
/// store, so the agent reconciles with the tracker itself (a restart of the
/// agent loses no work and no state). One line per run; the retry count and
/// last failure reason are listed only when the run carries them (a fresh
/// dispatch has neither, a run at its PR has no failure). Pure, no I/O.
String bootstrapFeed(List<AfkRun> inFlight) {
  final lines = <String>[
    standingRules,
    '',
    'Bootstrap — the AFK agent session was just recreated. These runs are '
        'in flight (from the bridge\'s store); reconcile with the tracker before '
        'continuing, so the restart loses no work:',
  ];
  for (final run in inFlight) {
    final detail = <String>[
      if (run.retryCount > 0) 'retry ${run.retryCount}',
      if (run.lastFailureReason != null)
        'last failure: ${run.lastFailureReason}',
    ];
    lines.add(
      '- #${run.issueNumber} ${run.title}: ${run.state}'
      '${detail.isEmpty ? '' : ' (${detail.join(', ')})'}',
    );
  }
  return lines.join('\n');
}
