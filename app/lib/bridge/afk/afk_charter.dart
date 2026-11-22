import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../sessions/paths.dart';

/// The canonical charter for the `afk` agent (spec #376, "The AFK agent").
///
/// The charter is a markdown agent file (an opencode custom agent) that
/// defines the `afk` primary agent: its identity, the `implement-spec`
/// discipline it operates under from creation, its wiki discipline, its hard
/// rules, and the **permissions** that enforce the hard rules as `deny` rules
/// (merge, force-push, and push-to-the-default-branch denied — enforced by
/// the service, not obeyed from words). The model is deliberately **not** in the
/// file: the bridge pins it at session creation from the `afkModel` setting
/// (empty = the service's default).
///
/// The file rides in the binary as the reviewed source (the same pattern as
/// the embedded orb plugins and build context). [install] is the guarantee,
/// with the app-owned-files refresh contract (issue #141, as the orb spawn
/// plugin): at bridge startup (server mode) the canonical charter is installed
/// into the global opencode config's agents directory — a **stale, untouched**
/// copy of a previous materialization (its digest in [previousDigests]) is
/// refreshed in place, so a reworked charter (e.g. the per-project rework of
/// spec #407) actually reaches the running agent; an **absent** file is
/// written; **anything else** — the developer's hand-edited copy — is left
/// byte-for-byte untouched and wins. A file already at the embedded bytes is
/// not rewritten (no churn). Reset = delete the file (the next startup
/// re-materializes the canonical copy) or pass [replace] to force the current
/// canonical copy over a hand edit.
abstract class AfkCharter {
  /// The agent id the charter defines (the session's agent is `afk`).
  static const String agentId = 'afk';

  /// The agent file name inside the opencode agents dir.
  static const String fileName = 'afk.md';

  /// The global opencode config's agents dir
  /// (`~/.config/opencode/agents/`): opencode's auto-discovered location for
  /// markdown agents, shared by every project on the host.
  static Directory hostAgentsDir() =>
      Directory('${homeDirectory()}/.config/opencode/agents');

  /// The canonical charter's file on the host.
  static File hostCharterFile() => File('${hostAgentsDir().path}/$fileName');

  /// The canonical charter (markdown agent file). The body is the agent's
  /// system prompt (the standing rules); the frontmatter carries the id,
  /// mode, and the permission denials. No model — the bridge pins it.
  static const String canonical = r'''---
description: The resident AFK agent, one per armed project. It implements ready-for-agent issues into orbs and ends each run at a reviewable PR.
mode: primary
permissions:
  # Hard rules, enforced as denials (the human boundary — never merge, never
  # force-push, never push the default branch). The last matching rule wins,
  # and these agent rules append after the base policy, so they hold.
  - action: shell
    resource: "git push --force *"
    effect: deny
  - action: shell
    resource: "git push -f *"
    effect: deny
  - action: shell
    resource: "git push --force-with-lease *"
    effect: deny
  - action: shell
    resource: "git push origin main *"
    effect: deny
  - action: shell
    resource: "git push origin master *"
    effect: deny
  - action: shell
    resource: "git push origin HEAD:main"
    effect: deny
  - action: shell
    resource: "git push origin HEAD:master"
    effect: deny
  - action: shell
    resource: "git push origin main"
    effect: deny
  - action: shell
    resource: "git push origin master"
    effect: deny
  - action: shell
    resource: "gh pr merge *"
    effect: deny
  - action: shell
    resource: "gh pr merge"
    effect: deny
  - action: shell
    resource: "gh merge *"
    effect: deny
  - action: shell
    resource: "gh merge"
    effect: deny
---

You are a resident AFK agent. There is **one of you per armed project**: you
live in the checkout of the project you were armed on, on the host's shared
opencode service, and you are visible in the app's session list like any other
session. You are armed from a per-project toggle; when you are armed the bridge
feeds you that project's issues, and you work them one at a time. Every read
you do — the issue, the code, `git`, `gh` — runs from **this project's
checkout**, so you can never point at the wrong repo.

## What a feed is

A feed from the bridge is a **pure availability notice**: an issue number and
its title, nothing more. It is a signal that an issue is ready, not the work
itself. On a feed you open the issue, read it, and drive it — you do not wait
for the bridge to hand you the details.

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

These are hard rules, and they are enforced by the permissions above (denied
by the service), not just asked of you:

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

The layers do not overlap: the charter holds standing rules (this file), the
wiki holds tribal knowledge, the tracker's narrations hold the per-run journal,
and the bridge's store holds machine state. A fact lives in exactly one layer.
''';

  /// The SHA-256 hex digests of the bytes of **every previous embedded
  /// version** of the charter file (the app-owned-files refresh contract,
  /// issue #141 — the same mechanism as the orb spawn plugin's
  /// [OrbAgentTools.previousDigests]): a file on disk matching one of these
  /// byte-for-byte is a stale copy of a past materialization the user never
  /// touched, and [install] refreshes it to the embedded copy.
  ///
  /// The digests (not the old sources) travel in the binary: enough to
  /// recognize a stale copy, nothing to ship. Add the digest of the version
  /// you are replacing in every commit that edits [canonical]: the digest of
  /// a committed version is `sha256` over the canonical's UTF-8 bytes,
  /// computable from [canonical] at that commit.
  static const Map<String, Set<String>> previousDigests = {
    fileName: {
      // 4033b30 (#376 T1): the pilot's first charter (one agent, "the main
      // checkout"). The version every #376-era install materialized.
      'b2acfe04bca11fd1c9ecc66f5628e7d0b74c2f3ea2cdbac88db69805528f91f7',
      // 8566d98 (#376 merged, #385): the reviewed charter as it reached
      // main — the version every post-#376 install materialized.
      '427e08ffa42656de112654bdcf2c99a950354b2c6f627fc1b95577c7d2575f14',
    },
  };

  /// Install the canonical charter into [agentsDir] (the global opencode
  /// agents dir, [hostAgentsDir], by default), with the app-owned-files
  /// refresh contract (issue #141): create the dir if missing; write the
  /// embedded copy when the file is **absent**; refresh it in place when it
  /// is a **stale, untouched** copy of a previous materialization (its digest
  /// is in [previousDigests]) — the former blanket create-if-missing froze
  /// every reworked charter out of every existing install (the pilot's agent
  /// kept running the pilot's text long after main moved on); leave
  /// **anything else** (a hand-edited copy) byte-for-byte untouched — the
  /// developer's edit wins. A file already at the embedded bytes is not
  /// rewritten (no churn). [replace] forces the embedded copy over whatever
  /// is on disk (the developer's reset when a hand edit must be discarded).
  ///
  /// Returns the charter file path. Safe to call at every startup.
  static Future<File> install({
    Directory? agentsDir,
    bool replace = false,
  }) async {
    final dir = agentsDir ?? hostAgentsDir();
    await dir.create(recursive: true);
    final file = File('${dir.path}/$fileName');
    if (!file.existsSync()) {
      await file.writeAsString(canonical);
      return file;
    }
    final onDisk = sha256.convert(file.readAsBytesSync()).toString();
    if (onDisk == _digestOf(canonical) && !replace) return file;
    final stale = previousDigests[fileName]?.contains(onDisk) ?? false;
    if (replace || stale) {
      await file.writeAsString(canonical);
    }
    // Otherwise the on-disk copy wins (a hand edit).
    return file;
  }

  /// The SHA-256 hex digest of an embedded charter as written
  /// ([writeAsString]'s UTF-8 bytes).
  static String _digestOf(String content) =>
      sha256.convert(utf8.encode(content)).toString();
}
