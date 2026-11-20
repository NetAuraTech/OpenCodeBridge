import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The repo-root AGENTS.md. Tests run with cwd `app/`; the locator tries a
/// fixed list of candidate paths (1 to 3 levels up from the cwd) and uses the
/// first that exists, so the test does not depend on the checkout's depth.
/// Mirrors the locator/section-scan in verification_signature_test.dart.
File _agentsMd() {
  final candidates = ['../AGENTS.md', '../../AGENTS.md', '../../../AGENTS.md'];
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) return f;
  }
  fail('repo-root AGENTS.md not found (tried ${candidates.join(', ')})');
}

/// Extracts the `## Orb sandbox` section: from its heading up to (not
/// including) the next `## ` heading, or the end of the file. Scoping the
/// assertions to this section keeps them off the `## Verification` section,
/// which is owned by ticket #387.
String _orbSandboxSection(String agentsMd) {
  final lines = agentsMd.split('\n');
  final start = lines.indexWhere((l) => l.trim() == '## Orb sandbox');
  expect(start, isNonNegative, reason: '## Orb sandbox section not found');
  var end = -1;
  for (var i = start + 1; i < lines.length; i++) {
    if (lines[i].startsWith('## ')) {
      end = i;
      break;
    }
  }
  final stop = end == -1 ? lines.length : end;
  return lines.sublist(start, stop).join('\n');
}

void main() {
  group('the AGENTS.md Orb sandbox section is navigation, not state '
      '(#386/#388)', () {
    late String section;

    setUp(() {
      section = _orbSandboxSection(_agentsMd().readAsStringSync());
    });

    test('restates no pinned toolchain version list', () {
      expect(
        section,
        isNot(contains(RegExp(r'Flutter\s+\d+\.\d+'))),
        reason: 'the pinned Flutter version must not be restated',
      );
      expect(
        section,
        isNot(contains(RegExp(r'Dart\s+\d+\.\d+'))),
        reason: 'the pinned Dart version must not be restated',
      );
    });

    test('points at the orb_spawn/orb_wait tool answers as the toolchain '
        'source', () {
      expect(
        section,
        contains('orb_spawn'),
        reason: 'the toolchain must point at the orb_spawn tool answers',
      );
      expect(
        section,
        contains('orb_wait'),
        reason: 'the toolchain must point at the orb_wait tool answers',
      );
    });

    test('restates no one-branch-contract prose', () {
      expect(
        section,
        isNot(contains('orb/<id>')),
        reason: 'the internal default ref must not be restated',
      );
      expect(
        section,
        isNot(
          matches(RegExp(r'one\s*branch\s*contract', caseSensitive: false)),
        ),
        reason: 'the one-branch-contract prose must not be restated',
      );
    });

    test('states the verified root-quirk fact: named self-skips, not '
        'failures, pointing at the Verification section', () {
      expect(
        section,
        contains('root'),
        reason: 'the sandbox runs as root — the verified fact',
      );
      expect(
        section,
        contains('Verification'),
        reason: 'the quirk line must point at the canonical signature',
      );
      expect(
        section,
        contains(RegExp(r'self-skip', caseSensitive: false)),
        reason: 'the affected tests are self-skips, not failures',
      );
      expect(
        section,
        isNot(contains('fail there')),
        reason: 'the stale "fail there" phrasing must not appear',
      );
      expect(
        section,
        isNot(contains('environmental')),
        reason: 'the stale "environmental" phrasing must not appear',
      );
    });

    test('keeps the pointer to the driver rule doc', () {
      expect(
        section,
        contains('docs/agents/orb-verify-remote-merge.md'),
        reason: 'the driver rule pointer must be preserved',
      );
      expect(
        section,
        contains('self-report is a claim, not a fact'),
        reason: 'the minimal surrounding fact a merger needs must be kept',
      );
    });

    test('stays compact: a few lines, not a paragraph wall', () {
      final contentLines = section
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      expect(
        contentLines.length,
        lessThanOrEqualTo(5),
        reason: 'the section is navigation, not state — keep it to a few lines',
      );
    });
  });
}
