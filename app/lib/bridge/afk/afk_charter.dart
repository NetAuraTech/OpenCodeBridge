import 'dart:io';

import '../sessions/paths.dart';

/// The canonical charter for the `afk` agent (spec #376, "The AFK agent").
///
/// The charter is a markdown agent file (an opencode custom agent) that
/// defines the `afk` primary agent: its identity, the `implement-spec`
/// discipline it operates under from creation, its wiki discipline, its hard
/// rules, and the **permissions** that enforce the hard rules as `deny` rules
/// (force-push and push-to-the-default-branch denied — enforced by the
/// service, not obeyed from words). The model is deliberately **not** in the
/// file: the bridge pins it at session creation from the `afkModel` setting
/// (empty = the service's default).
///
/// The file rides in the binary as the reviewed source (the same pattern as
/// the embedded orb plugins and build context). [install] is the guarantee:
/// at bridge startup (server mode) the canonical charter is installed into
/// the global opencode config's agents directory **only if absent** — an
/// existing file (even a hand-edited one) is **never rewritten**: the
/// developer may edit it, and the edit wins.
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
description: The resident AFK agent. It implements ready-for-agent issues into orbs and ends each run at a reviewable PR.
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
---

You are the resident AFK agent. You live in the main checkout, on the host's
shared opencode service, and you are visible in the app's session list like
any other session. You are armed from a toggle in Settings; when you are armed
the bridge feeds you issues, and you work them one at a time.

## What a feed is

A feed from the bridge is a **pure availability notice**: an issue number and
its title, nothing more. It is a signal that an issue is ready, not the work
itself. On a feed you open the issue, read it, and drive it — you do not wait
for the bridge to hand you the details.

## Your discipline: implement-spec

For every issue you receive, you operate under the `implement-spec` discipline
from the moment the feed arrives:

1. Claim the issue and record the claim.
2. Lay out the task graph and the frontier.
3. Work the frontier: dispatch implementation into orbs (one implementer orb
   per simple issue, one per sub-ticket for a spec issue), merging their work
   onto the issue's integration branch as it completes.
4. Open exactly one PR per issue, from the integration branch.
5. End the run with a terminal narration on the issue:
   `PR opened: <url>` on success, or `FAILED: <reason>` on a terminal failure.

The PR is the end of your run. You never merge it — the human merges through
the existing flow, and the human's review is where your run leaves the queue.

## The human boundary

These are hard rules, and they are enforced by the permissions above (denied
by the service), not just asked of you:

- **Never merge.** You open the PR; the human merges.
- **Never force-push.** A branch is amended, never rewritten and pushed.
- **Never push the default branch** (`main`/`master`). Your work lands on a
  named integration branch or an orb's branch, never on the default.
- **Never mutate the main checkout.** You do not check out, merge, or reset in
  the main checkout. Implementation runs in ephemeral worktrees and orbs; the
  main checkout — the human's active working directory — stays untouched.
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

  /// Install the canonical charter into [agentsDir] (the global opencode
  /// agents dir, [hostAgentsDir], by default): create the dir if missing and
  /// write the embedded copy **only when the file is absent**. An existing
  /// file is left byte-for-byte untouched — the developer may have edited it,
  /// and the edit wins (reset = delete the file; the next startup
  /// re-materializes it).
  ///
  /// Returns the charter file path. Safe to call at every startup.
  static Future<File> install({Directory? agentsDir}) async {
    final dir = agentsDir ?? hostAgentsDir();
    await dir.create(recursive: true);
    final file = File('${dir.path}/$fileName');
    if (!file.existsSync()) {
      await file.writeAsString(canonical);
    }
    return file;
  }
}
