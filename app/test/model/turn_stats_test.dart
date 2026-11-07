import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/turn_stats.dart';

/// An assistant step of a turn: created at [created], first streamed token at
/// [streamed] (omitted when null — a step without a streamed timestamp),
/// completed at [completed], billing [output] + [reasoning] tokens.
SessionMessage _step({
  String id = 'a',
  int? created,
  int? streamed,
  int? completed,
  int? output = 0,
  int? reasoning = 0,
}) => SessionMessage(
  id: id,
  role: 'assistant',
  created: created,
  streamed: streamed,
  completed: completed,
  outputTokens: output,
  reasoningTokens: reasoning,
);

void main() {
  group('computeTurnStats', () {
    test('single-step turn: duration, no compaction, weighted tok/s', () {
      final stats = computeTurnStats([
        SessionMessage(role: 'user', created: 1000),
        _step(created: 1100, streamed: 2100, completed: 2600, output: 150),
        SessionMessage(id: 'i1', role: 'idle', created: 2601),
      ]);
      // 1000 -> 2600: 1.6s; 150 tokens over 1s of streaming: 150 tok/s.
      expect(stats?.duration, const Duration(milliseconds: 1600));
      expect(stats?.compactions, 0);
      expect(stats?.tokensPerSecond, 150);
    });

    test('multi-step turn aggregates before dividing', () {
      final stats = computeTurnStats([
        SessionMessage(role: 'user', created: 0),
        _step(
          id: 'a1',
          created: 100,
          streamed: 1100,
          completed: 1200,
          output: 100,
        ),
        _step(
          id: 'a2',
          created: 1200,
          streamed: 1700,
          completed: 1800,
          output: 400,
        ),
        SessionMessage(id: 'i1', role: 'idle', created: 1801),
      ]);
      // 0 -> 1800; (100 + 400) / (1.0 + 0.5) = 333.33…
      expect(stats?.duration, const Duration(milliseconds: 1800));
      expect(stats?.tokensPerSecond, closeTo(333.3333, 0.01));
    });

    test('a turn with compactions counts the markers within it', () {
      final stats = computeTurnStats([
        // An earlier turn, ending at its idle marker.
        SessionMessage(id: 'x', role: 'user', created: 1),
        _step(id: 'ax', created: 1, streamed: 2, completed: 3, output: 999),
        SessionMessage(id: 'i0', role: 'idle', created: 9),
        SessionMessage(role: 'user', created: 10),
        SessionMessage(id: 'c1', role: 'compaction', created: 20),
        _step(id: 'a1', created: 30, streamed: 40, completed: 50, output: 10),
        SessionMessage(id: 'c2', role: 'compaction', created: 60),
        _step(id: 'a2', created: 70, streamed: 80, completed: 90, output: 10),
        SessionMessage(id: 'i1', role: 'idle', created: 100),
      ]);
      // Walked back from the end to i0: the turn starts at its first user
      // prompt (created 10) and sees both compaction markers.
      expect(stats?.compactions, 2);
      expect(stats?.duration, const Duration(milliseconds: 80));
    });

    test('reasoning tokens count toward the throughput', () {
      final stats = computeTurnStats([
        SessionMessage(role: 'user', created: 0),
        _step(
          created: 0,
          streamed: 1000,
          completed: 1500,
          output: 60,
          reasoning: 40,
        ),
        SessionMessage(id: 'i1', role: 'idle', created: 1501),
      ]);
      // (60 + 40) over 1s of streaming.
      expect(stats?.tokensPerSecond, 100);
    });

    test('an incomplete step (no streamed timestamp) omits the tok/s', () {
      final stats = computeTurnStats([
        SessionMessage(role: 'user', created: 0),
        _step(
          id: 'a1',
          created: 0,
          streamed: 1000,
          completed: 1500,
          output: 50,
        ),
        _step(id: 'a2', created: 1500, completed: 2000, output: 10),
        SessionMessage(id: 'i1', role: 'idle', created: 2001),
      ]);
      // The duration and compaction stat stay; the throughput is dropped.
      expect(stats?.duration, const Duration(milliseconds: 2000));
      expect(stats?.compactions, 0);
      expect(stats?.tokensPerSecond, isNull);
    });

    test('a legacy history without idle markers reads back to its last '
        'prompt', () {
      final stats = computeTurnStats([
        SessionMessage(id: 'u0', role: 'user', created: 0),
        _step(id: 'a0', created: 0, streamed: 500, completed: 600, output: 10),
        SessionMessage(id: 'u1', role: 'user', created: 1000),
        _step(
          id: 'a1',
          created: 1000,
          streamed: 2000,
          completed: 2500,
          output: 200,
        ),
      ]);
      // The turn is u1 -> a1: 1000 -> 2500, 200 / 1s.
      expect(stats?.duration, const Duration(milliseconds: 1500));
      expect(stats?.compactions, 0);
      expect(stats?.tokensPerSecond, 200);
    });

    test('a running turn (no trailing idle) gets its stats so far', () {
      final stats = computeTurnStats([
        SessionMessage(id: 'i0', role: 'idle', created: 0),
        SessionMessage(role: 'user', created: 100),
        _step(
          id: 'a1',
          created: 100,
          streamed: 1100,
          completed: 1200,
          output: 100,
        ),
      ]);
      expect(stats?.duration, const Duration(milliseconds: 1100));
      expect(stats?.tokensPerSecond, 100);
    });

    test(
      'the earlier turn is never read: the walk stops at the idle marker',
      () {
        final stats = computeTurnStats([
          // An earlier, longer turn. Its steps would skew the throughput if
          // the walk did not stop at the idle marker.
          SessionMessage(id: 'u0', role: 'user', created: 0),
          _step(
            id: 'a0',
            created: 0,
            streamed: 10000,
            completed: 20000,
            output: 100000,
          ),
          SessionMessage(id: 'i0', role: 'idle', created: 20001),
          SessionMessage(id: 'u1', role: 'user', created: 30000),
          _step(
            id: 'a1',
            created: 30000,
            streamed: 31000,
            completed: 32000,
            output: 100,
          ),
          SessionMessage(id: 'i1', role: 'idle', created: 32001),
        ]);
        expect(stats?.duration, const Duration(milliseconds: 2000));
        expect(stats?.tokensPerSecond, 100);
      },
    );

    test('a steer prompt keeps the turn: the duration starts at the first '
        'prompt', () {
      final stats = computeTurnStats([
        SessionMessage(id: 'i0', role: 'idle', created: 0),
        SessionMessage(id: 'u0', role: 'user', created: 100),
        _step(
          id: 'a0',
          created: 100,
          streamed: 600,
          completed: 700,
          output: 10,
        ),
        // A mid-turn steer prompt: no idle marker between the steps.
        SessionMessage(id: 'u1', role: 'user', created: 800),
        _step(
          id: 'a1',
          created: 800,
          streamed: 1800,
          completed: 2800,
          output: 200,
        ),
        SessionMessage(id: 'i1', role: 'idle', created: 2801),
      ]);
      // One turn (the window after i0): 100 -> 2800,
      // (10 + 200) over 0.5s + 1s of streaming.
      expect(stats?.duration, const Duration(milliseconds: 2700));
      expect(stats?.tokensPerSecond, closeTo(140, 0.001));
    });

    test('no assistant step in the window has no stats', () {
      expect(
        computeTurnStats([SessionMessage(role: 'user', created: 0)]),
        isNull,
      );
      expect(computeTurnStats([]), isNull);
    });

    test('a prompt without a created timestamp drops only the duration', () {
      // A locally-appended user prompt (no timestamps yet) normalized
      // against the service's copy keeps the throughput.
      final stats = computeTurnStats([
        SessionMessage(role: 'user'),
        _step(created: 0, streamed: 1000, completed: 1500, output: 100),
      ]);
      expect(stats?.duration, isNull);
      expect(stats?.tokensPerSecond, 100);
    });
  });

  group('TurnStats.label', () {
    test('the full footer: duration, compactions, tok/s', () {
      const stats = TurnStats(
        duration: Duration(milliseconds: 3400),
        compactions: 2,
        tokensPerSecond: 87.65,
      );
      expect(stats.label, '3.4s · 2 compactions · 87.7 tok/s');
    });

    test('one compaction is singular; a minute-plus duration reads 1m 23s', () {
      const stats = TurnStats(
        duration: Duration(seconds: 83),
        compactions: 1,
        tokensPerSecond: null,
      );
      expect(stats.label, '1m 23s · 1 compaction');
    });

    test('the segments drop with the stats', () {
      const stats = TurnStats(
        duration: null,
        compactions: 0,
        tokensPerSecond: 12.5,
      );
      expect(stats.label, '0 compactions · 12.5 tok/s');
    });

    test('the compaction count alone is noise: no footer', () {
      const stats = TurnStats(
        duration: null,
        compactions: 2,
        tokensPerSecond: null,
      );
      expect(stats.label, isNull);
    });

    test('turnStatsLabel is null when there are no stats', () {
      expect(turnStatsLabel([SessionMessage(role: 'user')]), isNull);
    });
  });
}
