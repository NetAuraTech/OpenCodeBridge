import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/afk/afk_charter.dart';

/// The AFK agent's charter (spec #376, T1; reworked by #407): the canonical
/// markdown agent file and its app-owned-files guarantee (issue #141): write
/// if absent, refresh a stale untouched copy, never touch a hand edit.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('oc-afk-charter');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('installs the canonical charter when absent (fresh machine)', () async {
    final file = await AfkCharter.install(agentsDir: dir);
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), AfkCharter.canonical);
  });

  test('leaves an existing (hand-edited) file byte-identical', () async {
    final file = File('${dir.path}/${AfkCharter.fileName}');
    const edited = '---\ndescription: my edit\n---\n\nmy own rules\n';
    file.writeAsStringSync(edited);

    await AfkCharter.install(agentsDir: dir);

    expect(file.readAsStringSync(), edited);
  });

  test('leaves an existing file byte-identical when it already equals the '
      'canonical copy (no churn)', () async {
    final file = File('${dir.path}/${AfkCharter.fileName}');
    file.writeAsStringSync(AfkCharter.canonical);

    final before = file.lastModifiedSync();
    await AfkCharter.install(agentsDir: dir);

    expect(file.readAsStringSync(), AfkCharter.canonical);
    // The file is not rewritten when it is already current.
    expect(file.lastModifiedSync(), before);
  });

  /// The reviewed #376 charter as it reached main (8566d98) — the version
  /// every post-#376 install materialized on the host, shipped here as a
  /// fixture so the stale-refresh path is tested with the real previous
  /// bytes (its digest is in [AfkCharter.previousDigests]).
  const String shipped376 = r'''---
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

  group('the refresh contract (issue #141)', () {
    /// The SHA-256 of the current embedded canonical (the bytes [install]
    /// would write, as UTF-8).
    String currentDigest() =>
        sha256.convert(utf8.encode(AfkCharter.canonical)).toString();

    test('a stale untouched materialization (the shipped #376 charter) is '
        'refreshed in place to the current canonical (the #407 rework reaches '
        'an existing install)', () async {
      final file = File('${dir.path}/${AfkCharter.fileName}');
      file.writeAsStringSync(shipped376);
      expect(file.readAsStringSync(), isNot(AfkCharter.canonical));

      await AfkCharter.install(agentsDir: dir);

      expect(file.readAsStringSync(), AfkCharter.canonical);
    });

    test('the digests set names the previous embedded versions and not the '
        'current one (the mechanism\'s invariants)', () {
      final digests = AfkCharter.previousDigests[AfkCharter.fileName]!;
      // The pilot's first charter (4033b30, the version whose bytes the
      // pilot actually installed on hosts) and the reviewed #376 charter
      // as it reached main (8566d98) are both in the set.
      expect(
        digests,
        contains(
          'b2acfe04bca11fd1c9ecc66f5628e7d0b74c2f3ea2cdbac88db69805528f91f7',
        ),
      );
      expect(
        digests,
        contains(
          '427e08ffa42656de112654bdcf2c99a950354b2c6f627fc1b95577c7d2575f14',
        ),
      );
      // The shipped #376 fixture's digest is the reviewed-main one, and the
      // current canonical's digest is NOT a "previous" digest: a file
      // already at the embedded bytes is the no-churn path, not the
      // refresh path.
      expect(
        sha256.convert(utf8.encode(shipped376)).toString(),
        '427e08ffa42656de112654bdcf2c99a950354b2c6f627fc1b95577c7d2575f14',
      );
      expect(digests, isNot(contains(currentDigest())));
    });
  });

  group('the canonical charter content', () {
    test('defines the `afk` primary agent (the session agent is `afk`)', () {
      expect(AfkCharter.agentId, 'afk');
      // The body is the agent's system prompt; the frontmatter names the id
      // and the mode. A markdown agent file's frontmatter carries `mode`.
      expect(AfkCharter.canonical, contains('mode: primary'));
    });

    test('denies force-push (the hard rule enforced as a permission)', () {
      expect(AfkCharter.canonical, contains('git push --force *'));
      expect(AfkCharter.canonical, contains('effect: deny'));
    });

    test('denies pushing the default branch', () {
      expect(AfkCharter.canonical, contains('git push origin main *'));
      expect(AfkCharter.canonical, contains('git push origin master *'));
    });

    test('denies merging a PR (the "never merge" hard rule enforced as a '
        'permission)', () {
      // The body's "You never merge it." is words; the permission is the
      // enforcement — the `gh pr merge` command and the classic `gh merge`
      // alias, each with and without its arguments (the same last-matching-
      // wins posture as the other denials).
      expect(AfkCharter.canonical, contains('gh pr merge *'));
      expect(AfkCharter.canonical, contains('gh pr merge'));
      expect(AfkCharter.canonical, contains('gh merge *'));
      expect(AfkCharter.canonical, contains('gh merge'));
    });

    test('carries no model (the bridge pins it at creation)', () {
      // The model is deliberately absent from the charter file: the bridge
      // pins it from the afkModel setting, and an empty pin inherits the
      // service default. A `model:` line in the frontmatter would freeze a
      // model into the file that the setting must own.
      final lines = AfkCharter.canonical.split('\n');
      expect(lines, isNot(contains(RegExp(r'^model:'))));
    });

    test('states the implement-spec discipline and the human boundary', () {
      expect(AfkCharter.canonical, contains('implement-spec'));
      expect(AfkCharter.canonical, contains('Never merge'));
      expect(AfkCharter.canonical, contains('Never force-push'));
      expect(AfkCharter.canonical, contains('default branch'));
    });
  });
}
