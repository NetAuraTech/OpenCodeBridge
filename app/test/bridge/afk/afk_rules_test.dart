// The AFK standing rules (spec #420): the one home for the resident session's
// standing operational rules (versioned in the app source, riding the feed)
// and the human-boundary denials (the session's per-session permissions at
// creation). Pure: no I/O, no service.

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/afk/afk_rules.dart';
import 'package:opencodebridge/bridge/afk/afk_store.dart';

void main() {
  group('the standing rules (the reviewed source, riding the feed)', () {
    test(
      'standingRules is the canonical standing-rule block (no frontmatter)',
      () {
        expect(standingRules, isNotEmpty);
        // The sections, in the old charter's order: identity (the resident
        // agent), the feed contract, the dispatch discipline, the
        // implement-spec discipline, the human boundary, and the wiki memory
        // discipline with the layered-memory note.
        expect(standingRules, contains('resident AFK agent'));
        expect(standingRules, contains('What a feed is'));
        expect(standingRules, contains('you dispatch, you do not type'));
        expect(standingRules, contains('implement-spec'));
        expect(standingRules, contains('The human boundary'));
        expect(standingRules, contains('Never merge'));
        expect(standingRules, contains('Never force-push'));
        expect(standingRules, contains('default branch'));
        expect(standingRules, contains('the repo wiki'));
        expect(standingRules, contains('fact lives in exactly one layer'));
        // Plain markdown: no frontmatter (no agent file anymore).
        expect(standingRules, isNot(contains('mode:')));
        expect(standingRules, isNot(contains('permissions:')));
        // No model line: the bridge pins the model at creation.
        expect(standingRules, isNot(contains('model:')));
      },
    );

    test(
      'the feed contract: a feed begins with the standing rules, then the '
      'notice (or the bootstrap list) — the agent opens the issue itself',
      () {
        expect(standingRules, contains('begins with your standing rules'));
        expect(standingRules, contains('availability notice'));
        expect(standingRules, contains('bootstrap list'));
        expect(
          standingRules,
          contains('open the issue, read it, and drive it'),
        );
      },
    );

    test('the human boundary is enforced as denials on the session itself '
        '(the session\'s permission rules), not just asked of the agent', () {
      expect(standingRules, contains('denials on the session'));
      expect(standingRules, contains('permission rules'));
    });
  });

  group('the feeds (the rules ride in front)', () {
    test('availabilityNotice begins with the standing rules and carries the '
        'issue number + title (nothing more of the issue)', () {
      final feed = availabilityNotice(7, 'Add a README');
      expect(feed, startsWith(standingRules));
      expect(feed, contains('Issue #7: Add a README'));
    });

    test('availabilityNotice for a different issue carries that issue', () {
      final feed = availabilityNotice(132, 'Ship the widget');
      expect(feed, startsWith(standingRules));
      expect(feed, contains('Issue #132: Ship the widget'));
    });

    test('bootstrapFeed begins with the standing rules and lists the in-flight '
        'runs (number, state, retry count, last failure reason); a fresh run '
        'lists only its state', () {
      final feed = bootstrapFeed(const [
        AfkRun(
          ownerRepo: 'o/r',
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
          retryCount: 1,
          lastFailureReason: 'model under load',
        ),
        AfkRun(
          ownerRepo: 'o/r',
          issueNumber: 9,
          title: 'Ship the widget',
          state: 'pr-open',
        ),
      ]);
      expect(feed, startsWith(standingRules));
      expect(feed, contains('#7'));
      expect(feed, contains('Add a README'));
      expect(feed, contains('dispatched'));
      expect(feed, contains('retry 1'));
      expect(feed, contains('last failure: model under load'));
      expect(feed, contains('#9'));
      expect(feed, contains('Ship the widget'));
      expect(feed, contains('pr-open'));
      // A fresh run (no retry, no failure) carries no detail parentheses —
      // its line is the bare "- #N title: state" (it is the feed's last
      // line).
      expect(feed, endsWith('- #9 Ship the widget: pr-open'));
      expect(feed, isNot(contains('pr-open (')));
    });
  });

  group('the human-boundary denials (the enforcement at creation)', () {
    test('every denial is a shell deny rule, and the set carries the '
        'force-push, default-branch, and merge denials', () {
      expect(humanBoundaryDenials, isNotEmpty);
      for (final rule in humanBoundaryDenials) {
        expect(rule['action'], 'shell');
        expect(rule['effect'], 'deny');
        expect(rule['resource'], isA<String>());
      }
      final resources = humanBoundaryDenials.map((r) => r['resource']).toList();
      // No force-push (any form).
      expect(resources, contains('git push --force *'));
      expect(resources, contains('git push -f *'));
      expect(resources, contains('git push --force-with-lease *'));
      // No push of the default branch (any form).
      expect(resources, contains('git push origin main *'));
      expect(resources, contains('git push origin master *'));
      expect(resources, contains('git push origin HEAD:main'));
      expect(resources, contains('git push origin HEAD:master'));
      expect(resources, contains('git push origin main'));
      expect(resources, contains('git push origin master'));
      // No merge (any form).
      expect(resources, contains('gh pr merge *'));
      expect(resources, contains('gh pr merge'));
      expect(resources, contains('gh merge *'));
      expect(resources, contains('gh merge'));
    });
  });
}
