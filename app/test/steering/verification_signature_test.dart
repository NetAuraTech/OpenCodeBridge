import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The repo-root AGENTS.md. Tests run with cwd `app/`; the root is the
/// nearest ancestor directory that holds an AGENTS.md, so the test does not
/// depend on the checkout's depth.
File _agentsMd() {
  final candidates = ['../AGENTS.md', '../../AGENTS.md', '../../../AGENTS.md'];
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) return f;
  }
  fail('repo-root AGENTS.md not found (tried ${candidates.join(', ')})');
}

/// Extracts the `## Verification` section: from its heading up to (not
/// including) the next `## ` heading. Scoping the assertions to this section
/// keeps them off the `## Orb sandbox` section, which is owned by a separate
/// ticket (#386 batch).
String _verificationSection(String agentsMd) {
  final lines = agentsMd.split('\n');
  final start = lines.indexWhere((l) => l.trim() == '## Verification');
  expect(start, isNonNegative, reason: '## Verification section not found');
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
  group('the clean-base signature in the AGENTS.md Verification section '
      '(#386/#387)', () {
    late String section;

    setUp(() {
      section = _verificationSection(_agentsMd().readAsStringSync());
    });

    test('states the invariant: zero failures on a clean base in either '
        'environment', () {
      expect(
        section,
        contains('zero failures on a clean base in either environment'),
        reason: 'the invariant wording must be present',
      );
    });

    test('names the root permission-denial self-skip with its reason', () {
      expect(
        section,
        contains('permission denial cannot be exercised as root'),
        reason: 'the permission-denial self-skip reason must be named',
      );
    });

    test('names the root parent-env-leak self-skip (GH_CONFIG_DIR / '
        'ORB_BASE_BRANCH)', () {
      expect(
        section,
        contains('GH_CONFIG_DIR'),
        reason: 'the GH_CONFIG_DIR parent-env leak must be named',
      );
      expect(
        section,
        contains('ORB_BASE_BRANCH'),
        reason: 'the ORB_BASE_BRANCH parent-env leak must be named',
      );
      expect(
        section,
        contains('leaks into the fake container'),
        reason: 'the parent-env leak mechanism must be named',
      );
    });

    test('names the root state-dir self-skip with its reason', () {
      expect(
        section,
        contains('a recursive delete cannot fail as root'),
        reason: 'the root state-dir self-skip reason must be named',
      );
    });

    test('names the non-root environment-conditional skip family (docker CLI '
        'on PATH / shared opencode service descriptor)', () {
      expect(
        section,
        contains('docker CLI on PATH'),
        reason: 'the docker-CLI-on-PATH condition must be named',
      );
      expect(
        section,
        contains('opencode service descriptor'),
        reason: 'the shared opencode descriptor condition must be named',
      );
    });

    test('carries no stale "fail there" prose in the Verification section', () {
      expect(
        section,
        isNot(contains('fail there')),
        reason:
            'the stale "fail there" phrasing must not appear in the '
            'Verification section',
      );
    });

    test('states the expectation as an invariant, not absolute counters', () {
      // No specific pass/skip/fail count (a digit followed by a counter
      // noun). The invariant "zero failures" uses a word, so it does not
      // match this.
      expect(
        section,
        isNot(
          contains(RegExp(r'\d+\s+(passed|skipped|failed|failures|tests)\b')),
        ),
        reason: 'absolute pass/skip/fail counters must not appear',
      );
      // No `+NNN -N`-style run signature either.
      expect(
        section,
        isNot(contains(RegExp(r'\+\d+'))),
        reason: 'a +NNN counter run signature must not appear',
      );
    });
  });
}
