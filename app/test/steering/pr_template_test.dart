import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Self-check for the #386 steering batch (#389): the PR template's Tests
/// section reports the verification result against the canonical clean-base
/// signature (root AGENTS.md, Verification section) with a one-line result,
/// a full paragraph only on deviation, and no pre-written failure count or
/// environmental boilerplate; the issue-tracker doc's sub-issue operation
/// matches the verified live API (sub_issues, integer sub_issue_id).
///
/// The files are read relative to the cwd (app/, where the verification
/// command runs), so `../.github/...` and `../docs/...` reach the repo root.

void main() {
  late String template;
  late String doc;

  String testsSection() {
    final section = template.split('## Tests').skip(1).first;
    return section.split(RegExp(r'^## ', multiLine: true)).first;
  }

  String childTicketLine() =>
      doc.split('\n').firstWhere((l) => l.startsWith('- **Child ticket**'));

  setUpAll(() {
    template = File('../.github/PULL_REQUEST_TEMPLATE.md').readAsStringSync();
    doc = File('../docs/agents/issue-tracker.md').readAsStringSync();
  });

  group(
    'PR template — the Tests section reports against the signature (#389)',
    () {
      test('one-line result reported against the canonical clean-base '
          'signature', () {
        final section = testsSection();
        expect(section, contains('clean-base signature'));
        expect(section, contains('root AGENTS.md, Verification'));
      });

      test('the full paragraph is required only on deviation, and a deviation '
          'is reportable only after reproduction on a clean base', () {
        final section = testsSection();
        expect(section, contains('only on deviation'));
        expect(section, contains('reproduction on a clean base'));
      });

      test('no pre-written failure count and no environmental boilerplate '
          'remain in the section', () {
        final section = testsSection();
        expect(section, isNot(matches(RegExp(r'\d+\s+fail'))));
        expect(section, isNot(contains('environmental')));
        expect(
          section,
          isNot(
            contains(
              'flutter analyze and dart format --set-exit-if-changed '
              '--output=none lib test are clean',
            ),
          ),
        );
      });

      test('the surrounding template structure is untouched', () {
        expect(template, startsWith('<!--'));
        expect(template, contains('Fixes #'));
        expect(template, contains('## Why'));
        expect(template, contains('## What changed'));
        expect(template, contains('## Acceptance'));
      });
    },
  );

  group('issue-tracker doc — the sub-issue operation matches the live API '
      '(#389)', () {
    test('the child-ticket line states the verified sub_issues endpoints '
        'with an integer sub_issue_id', () {
      final line = childTicketLine();
      expect(line, contains('/sub_issues'));
      expect(line, contains('DELETE'));
      expect(line, contains('sub_issue_id'));
      expect(line, contains('2026-03-10'));
      expect(line, contains('gh issue edit <parent> --add-sub-issue <n>'));
    });

    test('the stale sub-issues + issue_id sub-issue form is gone', () {
      // The stale form is the endpoint name plus the issue_id body field,
      // both confined to the child-ticket line; "sub-issues" survives
      // repo-wide only as the feature name. issue_id is scoped to the
      // child-ticket line (the untouched blocked_by bullet keeps its
      // `-F issue_id=<blocker-db-id>` database-id form).
      expect(doc, isNot(contains('sub-issues endpoint')));
      // \bissue_id matches the standalone field (as in the stale form or the
      // blocked_by bullet's -F issue_id=) but not sub_issue_id, whose
      // preceding underscore is a word character.
      expect(childTicketLine(), isNot(matches(RegExp(r'\bissue_id'))));
    });

    test('the blocked_by dependencies bullet is untouched', () {
      expect(
        doc,
        contains('repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by'),
      );
    });
  });
}
