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

    test(
      'a history without idle markers is one turn from its first prompt '
      '(issue #123: the session never closed a turn, so no prompt cut it)',
      () {
        final stats = computeTurnStats([
          SessionMessage(id: 'u0', role: 'user', created: 0),
          _step(
            id: 'a0',
            created: 0,
            streamed: 500,
            completed: 600,
            output: 10,
          ),
          // A steered prompt inside the session's first, unclosed turn.
          SessionMessage(id: 'u1', role: 'user', created: 1000),
          _step(
            id: 'a1',
            created: 1000,
            streamed: 2000,
            completed: 2500,
            output: 200,
          ),
        ]);
        // One turn (u0 -> a1): 0 -> 2500, (10 + 200) over 0.5s + 1.0s.
        expect(stats?.duration, const Duration(milliseconds: 2500));
        expect(stats?.compactions, 0);
        expect(stats?.tokensPerSecond, closeTo(140, 0.001));
      },
    );

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

    test('several steer prompts between two idles stay one turn: the first '
        'prompt anchors, every step weighs (issue #123)', () {
      final stats = computeTurnStats([
        SessionMessage(id: 'i0', role: 'idle', created: 0),
        SessionMessage(id: 'u1', role: 'user', created: 100),
        _step(
          id: 'a1',
          created: 100,
          streamed: 600,
          completed: 700,
          output: 10,
        ),
        // Two steer prompts delivered mid-Turn: no idle marker between them.
        SessionMessage(id: 'u2', role: 'user', created: 800),
        SessionMessage(id: 'c1', role: 'compaction', created: 900),
        _step(
          id: 'a2',
          created: 1000,
          streamed: 1500,
          completed: 2000,
          output: 100,
        ),
        SessionMessage(id: 'u3', role: 'user', created: 2100),
        _step(
          id: 'a3',
          created: 2100,
          streamed: 2600,
          completed: 3100,
          output: 100,
        ),
        SessionMessage(id: 'i1', role: 'idle', created: 3101),
      ]);
      // One Turn (the window after i0): 100 -> 3100; the steered prompts are
      // no Turn boundary, so all three steps weigh the throughput together:
      // (10 + 100 + 100) over 0.5s + 0.5s + 0.5s = 210/1.5.
      expect(stats?.duration, const Duration(milliseconds: 3000));
      expect(stats?.compactions, 1);
      expect(stats?.tokensPerSecond, closeTo(140, 0.001));
    });

    test('a steer prompt whose step has not landed keeps the turn at its '
        'first prompt (issue #123)', () {
      final stats = computeTurnStats([
        SessionMessage(id: 'i0', role: 'idle', created: 0),
        SessionMessage(id: 'u1', role: 'user', created: 100),
        _step(
          id: 'a1',
          created: 100,
          streamed: 600,
          completed: 700,
          output: 100,
        ),
        // The steer prompt is in the history; its step has not started yet.
        SessionMessage(id: 'u2', role: 'user', created: 800),
      ]);
      // The Turn stays the u1 window: 100 -> 700, the a1 step alone
      // (100 tokens over 0.5s of streaming). The undelivered prompt neither
      // restarts the duration nor joins the fold.
      expect(stats?.duration, const Duration(milliseconds: 600));
      expect(stats?.tokensPerSecond, 200);
    });

    test('a queued prompt after the idle keeps the previous turn frozen '
        '(issue #123)', () {
      final stats = computeTurnStats([
        SessionMessage(id: 'u1', role: 'user', created: 0),
        _step(
          id: 'a1',
          created: 100,
          streamed: 600,
          completed: 1600,
          output: 200,
        ),
        SessionMessage(id: 'i1', role: 'idle', created: 1601),
        // The queued prompt: the previous turn closed before it, its own
        // has not started — the footer keeps showing the previous turn.
        SessionMessage(id: 'u2', role: 'user', created: 5000),
      ]);
      // The u2 window holds no step: the walk falls back to the u1 Turn
      // (200 tokens over 0.5s of streaming).
      expect(stats?.duration, const Duration(milliseconds: 1600));
      expect(stats?.tokensPerSecond, 400);
    });

    test('a legacy bare prompt tail folds as the single unclosed turn (issue '
        '#123)', () {
      final stats = computeTurnStats([
        SessionMessage(id: 'u1', role: 'user', created: 0),
        _step(
          id: 'a1',
          created: 100,
          streamed: 600,
          completed: 1100,
          output: 50,
        ),
        // No idle marker anywhere (legacy): the trailing prompt has no step.
        SessionMessage(id: 'u2', role: 'user', created: 2000),
      ]);
      // The u2 pseudo-Turn has no content: the footer keeps the u1 Turn
      // (50 tokens over 0.5s of streaming).
      expect(stats?.duration, const Duration(milliseconds: 1100));
      expect(stats?.tokensPerSecond, 100);
    });

    test('a queued prompt after consecutive idle markers keeps the last '
        'contentful turn (issue #123)', () {
      final stats = computeTurnStats([
        SessionMessage(id: 'u1', role: 'user', created: 0),
        _step(
          id: 'a1',
          created: 100,
          streamed: 600,
          completed: 1100,
          output: 50,
        ),
        // Two idle markers in a row (a re-delivered boundary): the empty
        // window between them is skipped in one step back.
        SessionMessage(id: 'i1', role: 'idle', created: 1200),
        SessionMessage(id: 'i2', role: 'idle', created: 1200),
        SessionMessage(id: 'u2', role: 'user', created: 5000),
      ]);
      expect(stats?.duration, const Duration(milliseconds: 1100));
      expect(stats?.tokensPerSecond, 100);
    });

    test('a no-idle history ending in a prompt folds as one turn (issue '
        '#123)', () {
      final stats = computeTurnStats([
        // No idle markers anywhere: the session's first turn never closed,
        // so the trailing prompt is a steer inside it, not a new turn.
        SessionMessage(id: 'u0', role: 'user', created: 0),
        _step(
          id: 'a0',
          created: 0,
          streamed: 500,
          completed: 600,
          output: 1000,
        ),
        SessionMessage(id: 'u1', role: 'user', created: 1000),
        _step(
          id: 'a1',
          created: 1000,
          streamed: 1500,
          completed: 1800,
          output: 100,
        ),
        SessionMessage(id: 'u2', role: 'user', created: 2000),
      ]);
      // One turn (u0 -> a1): 0 -> 1800, (1000 + 100) over 0.5s + 0.5s.
      expect(stats?.duration, const Duration(milliseconds: 1800));
      expect(stats?.tokensPerSecond, 1100);
    });

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

  group('liveTurnStats', () {
    test(
      'ticks the duration from the first prompt to now, before any step',
      () {
        // The turn has a prompt but no completed step yet: the live footer
        // shows the ticking duration (and the compaction count) anyway, so it
        // appears the moment a prompt is sent.
        final stats = liveTurnStats([
          SessionMessage(role: 'user', created: 1000),
        ], now: 4500);
        expect(stats?.duration, const Duration(milliseconds: 3500));
        expect(stats?.compactions, 0);
        expect(stats?.tokensPerSecond, isNull);
      },
    );

    test('a step still streaming does not yet count toward the throughput', () {
      // One step finished, one is in flight (started, not completed): the
      // in-flight step's missing fields do not drop the throughput, and the
      // finished step's number stands.
      final stats = liveTurnStats([
        SessionMessage(role: 'user', created: 0),
        _step(
          id: 'a1',
          created: 100,
          streamed: 1100,
          completed: 1600,
          output: 100,
        ),
        // The in-flight step: created only (from step.started), no
        // streamed/completed/tokens yet.
        _step(id: 'a2', created: 2000),
      ], now: 2500);
      // Duration ticks to now (2500 - 0); throughput is the finished step
      // alone: 100 tokens over 1s.
      expect(stats?.duration, const Duration(milliseconds: 2500));
      expect(stats?.tokensPerSecond, 100);
      expect(stats?.compactions, 0);
    });

    test('the in-flight step settles in once it completes', () {
      // The same turn a moment later: the second step has ended, so both
      // steps weigh the throughput exactly as the frozen fold would.
      final stats = liveTurnStats([
        SessionMessage(role: 'user', created: 0),
        _step(
          id: 'a1',
          created: 100,
          streamed: 1100,
          completed: 1600,
          output: 100,
        ),
        _step(
          id: 'a2',
          created: 2000,
          streamed: 2700,
          completed: 2800,
          output: 400,
        ),
      ], now: 2900);
      // (100 + 400) / (1.0s + 0.7s) = 294.11… ; duration 0 -> 2900.
      expect(stats?.duration, const Duration(milliseconds: 2900));
      expect(stats?.tokensPerSecond, closeTo(294.1176, 0.01));
    });

    test('freezes into the identical value the frozen fold shows', () {
      // The live stats at the turn's end and the frozen stats over the same
      // history agree on throughput and compactions; the duration differs only
      // by the gap between the last step's completion and the end instant.
      final messages = [
        SessionMessage(role: 'user', created: 10),
        SessionMessage(id: 'c1', role: 'compaction', created: 20),
        _step(id: 'a1', created: 30, streamed: 400, completed: 900, output: 50),
        _step(
          id: 'a2',
          created: 1000,
          streamed: 1800,
          completed: 2000,
          output: 300,
          reasoning: 100,
        ),
      ];
      final live = liveTurnStats(messages, now: 2000)!;
      final frozen = computeTurnStats(messages)!;
      expect(live.compactions, frozen.compactions);
      expect(live.tokensPerSecond, frozen.tokensPerSecond);
      // Live duration runs to now (2000); the frozen one to the last step's
      // completion (also 2000 here, so they match exactly).
      expect(live.duration, frozen.duration);
    });

    test('a finished step lacking a field still drops the live throughput', () {
      final stats = liveTurnStats([
        SessionMessage(role: 'user', created: 0),
        _step(
          id: 'a1',
          created: 0,
          streamed: 1000,
          completed: 1500,
          output: 50,
        ),
        // Finished (completed) but its streamed timestamp is missing.
        _step(id: 'a2', created: 1500, completed: 2000, output: 10),
      ], now: 2100);
      // The duration still ticks; the throughput is dropped.
      expect(stats?.duration, const Duration(milliseconds: 2100));
      expect(stats?.tokensPerSecond, isNull);
    });

    test('no prompt and no step yet: nothing to show', () {
      expect(liveTurnStats([], now: 1000), isNull);
      // A turn with no prompt known and no finished step: a compaction alone
      // is noise, so the footer stays empty.
      expect(
        liveTurnStats([SessionMessage(role: 'compaction')], now: 1000),
        isNull,
      );
    });

    test('a history without idle markers ticks from its first prompt (issue '
        '#123)', () {
      final stats = liveTurnStats([
        SessionMessage(id: 'u0', role: 'user', created: 0),
        _step(id: 'a0', created: 0, streamed: 500, completed: 600, output: 10),
        // A steered prompt inside the session's first, unclosed turn.
        SessionMessage(id: 'u1', role: 'user', created: 1000),
        _step(
          id: 'a1',
          created: 1000,
          streamed: 2000,
          completed: 2500,
          output: 200,
        ),
      ], now: 2600);
      // One turn (u0 -> now): 0 -> 2600, (10 + 200) over 0.5s + 1.0s.
      expect(stats?.duration, const Duration(milliseconds: 2600));
      expect(stats?.tokensPerSecond, closeTo(140, 0.001));
    });
  });

  group('turnWindow', () {
    test(
      'a completed history: the window is the last turn, between its idles',
      () {
        final (start, end) = turnWindow([
          SessionMessage(id: 'u0', role: 'user'),
          SessionMessage(id: 'i0', role: 'idle'),
          SessionMessage(id: 'u1', role: 'user'),
          _step(id: 'a1'),
          SessionMessage(id: 'i1', role: 'idle'),
        ]);
        // i1 closes the last turn, so `end` sits past it; the window is the
        // turn between i0 and i1 — the previous turn (u0) is excluded by i0.
        expect(start, 2);
        expect(end, 4);
      },
    );

    test('an in-flight turn (no trailing idle) runs to the end', () {
      final (start, end) = turnWindow([
        SessionMessage(id: 'i0', role: 'idle'),
        SessionMessage(id: 'u1', role: 'user', created: 5),
        _step(id: 'a1'),
      ]);
      expect(start, 1);
      expect(end, 3);
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
