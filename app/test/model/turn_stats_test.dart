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

  group('activeTurnIndicator', () {
    test('agent, model, and the duration ticking from the first prompt', () {
      // The header's active-turn indicator (issue #161): the agent (its
      // first letter capitalized, like the TUI), the model, and the live
      // duration measured from the turn's first prompt to now.
      final label = activeTurnIndicator(
        messages: [SessionMessage(role: 'user', created: 1000)],
        now: 13300,
        agent: 'build',
        model: 'deepseek/deepseek-v4.1-flash',
      );
      expect(label, 'Build · deepseek/deepseek-v4.1-flash · … 12.3s');
    });

    test(
      'a turn at or above a minute formats its duration like the footer',
      () {
        final label = activeTurnIndicator(
          messages: [SessionMessage(role: 'user', created: 0)],
          now: 83000,
          agent: 'plan',
          model: 'prov/mod',
        );
        expect(label, 'Plan · prov/mod · … 1m 23s');
      },
    );

    test('an unknown agent or model drops that segment', () {
      expect(
        activeTurnIndicator(
          messages: [SessionMessage(role: 'user', created: 1000)],
          now: 1500,
          model: 'prov/mod',
        ),
        'prov/mod · … 0.5s',
      );
      expect(
        activeTurnIndicator(
          messages: [SessionMessage(role: 'user', created: 1000)],
          now: 1500,
          agent: 'build',
        ),
        'Build · … 0.5s',
      );
    });

    test('the ellipsis alone carries the indicator with no facts at all', () {
      // Neither agent nor model known and no first prompt in the loaded
      // window: the indicator still shows the turn is running.
      expect(activeTurnIndicator(messages: const [], now: 1000), '…');
    });

    test('no first prompt yet (the started-but-persisted-nothing window)', () {
      // The Turn started but the loaded history still ends on its closing
      // idle marker: no duration to show yet, the ellipsis ticks alone.
      final label = activeTurnIndicator(
        messages: [SessionMessage(id: 'i1', role: 'idle')],
        now: 5000,
        agent: 'build',
        model: 'prov/mod',
      );
      expect(label, 'Build · prov/mod · …');
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

  group('computeTurnFooters', () {
    // A step with 100 output tokens streamed over 1s reads 100.0 tok/s.
    SessionMessage step(
      int created, {
      required String id,
      int completed = 2000,
    }) => SessionMessage(
      id: id,
      role: 'assistant',
      created: created,
      streamed: created + 1000,
      completed: completed,
      outputTokens: 100,
      reasoningTokens: 0,
    );

    test('a completed turn labels its closing idle marker row', () {
      final footers = computeTurnFooters(const [
        SessionMessage(role: 'user', text: 'go', created: 0),
        SessionMessage(
          role: 'assistant',
          created: 0,
          streamed: 1000,
          completed: 1500,
          outputTokens: 100,
          reasoningTokens: 0,
        ),
        SessionMessage(id: 'i1', role: 'idle'),
      ], oldestLoaded: true);
      expect(footers, {2: '1.5s · 0 compactions · 100.0 tok/s'});
    });

    test('an active (open) turn labels the last row', () {
      final footers = computeTurnFooters(const [
        SessionMessage(role: 'user', text: 'go', created: 0),
        SessionMessage(
          role: 'assistant',
          created: 0,
          streamed: 1000,
          completed: 1500,
          outputTokens: 100,
          reasoningTokens: 0,
        ),
      ], oldestLoaded: true);
      expect(footers, {1: '1.5s · 0 compactions · 100.0 tok/s'});
    });

    test('two completed turns each label their own closing marker', () {
      final footers = computeTurnFooters([
        SessionMessage(id: 'u0', role: 'user', created: 0),
        step(0, id: 'a0', completed: 2000),
        SessionMessage(id: 'i0', role: 'idle', created: 2001),
        SessionMessage(id: 'u1', role: 'user', created: 10000),
        step(10000, id: 'a1', completed: 12000),
        SessionMessage(id: 'i1', role: 'idle', created: 12001),
      ], oldestLoaded: true);
      expect(footers, {
        2: '2.0s · 0 compactions · 100.0 tok/s',
        5: '2.0s · 0 compactions · 100.0 tok/s',
      });
    });

    test('an older turn is hidden until its opening marker loads', () {
      // Only the tail of a previous turn (no prompt, no opening marker) is in
      // the window: the first loaded turn is partial, so its footer is
      // withheld. The current turn is complete and labeled.
      final footers = computeTurnFooters([
        step(0, id: 'a0', completed: 2000), // a stray step of a previous turn
        SessionMessage(id: 'i0', role: 'idle', created: 2001),
        SessionMessage(id: 'u1', role: 'user', created: 10000),
        step(10000, id: 'a1', completed: 12000),
        SessionMessage(id: 'i1', role: 'idle', created: 12001),
      ], oldestLoaded: false);
      expect(footers.keys, isNot(contains(1)));
      expect(footers, {4: '2.0s · 0 compactions · 100.0 tok/s'});
    });

    test('the first turn is hidden until the whole history is loaded', () {
      final footers = computeTurnFooters([
        SessionMessage(id: 'u0', role: 'user', created: 0),
        step(0, id: 'a0', completed: 1500),
        SessionMessage(id: 'i0', role: 'idle', created: 1501),
        SessionMessage(id: 'u1', role: 'user', created: 10000),
        step(10000, id: 'a1', completed: 12000),
        SessionMessage(id: 'i1', role: 'idle', created: 12001),
      ], oldestLoaded: false);
      // The current turn (the second) is shown; the first is not yet.
      expect(footers, {5: '2.0s · 0 compactions · 100.0 tok/s'});
    });

    test('a running turn labels the last row; the closed turn is hidden', () {
      final footers = computeTurnFooters(
        [
          SessionMessage(id: 'u0', role: 'user', created: 0),
          step(0, id: 'a0', completed: 1500),
          SessionMessage(id: 'i0', role: 'idle', created: 1501),
          // The running turn: a prompt and a step so far.
          SessionMessage(id: 'u1', role: 'user', created: 10000),
          step(10000, id: 'a1', completed: 12000),
        ],
        oldestLoaded: true,
        active: true,
      );
      // The closed turn's marker (2) keeps its footer; the running turn [3,5)
      // labels its last row (4).
      expect(footers, {
        2: '1.5s · 0 compactions · 100.0 tok/s',
        4: '2.0s · 0 compactions · 100.0 tok/s',
      });
    });

    test('a running turn with no step yet has no footer', () {
      final footers = computeTurnFooters(
        [
          SessionMessage(id: 'u0', role: 'user', created: 0),
          step(0, id: 'a0', completed: 1500),
          SessionMessage(id: 'i0', role: 'idle', created: 1501),
          SessionMessage(id: 'u1', role: 'user', created: 10000),
        ],
        oldestLoaded: true,
        active: true,
      );
      // The closed turn's marker (2) keeps its footer; the running turn has no
      // step yet, so nothing labels its rows.
      expect(footers, {2: '1.5s · 0 compactions · 100.0 tok/s'});
    });

    test("now makes the running turn's label live", () {
      final footers = computeTurnFooters(
        [
          SessionMessage(id: 'u1', role: 'user', created: 10000),
          // The step still streaming: no `completed`, and its partial
          // token totals stay out of the live throughput.
          SessionMessage(
            id: 'a1',
            role: 'assistant',
            created: 10000,
            streamed: 10500,
            outputTokens: 50,
            reasoningTokens: 0,
          ),
        ],
        oldestLoaded: true,
        active: true,
        now: 15000,
      );
      // Duration ticks from the prompt (10000) to now (15000); the streaming
      // step carries no completed stats yet, so no tok/s.
      expect(footers, {1: '5.0s · 0 compactions'});
    });

    test('the live throughput counts only the completed steps', () {
      final footers = computeTurnFooters(
        [
          SessionMessage(id: 'u1', role: 'user', created: 10000),
          step(10000, id: 'a1', completed: 12000), // 100 tokens / 1000ms
          // Still streaming: excluded from the live average.
          SessionMessage(
            id: 'a2',
            role: 'assistant',
            created: 13000,
            streamed: 13500,
            outputTokens: 900,
            reasoningTokens: 0,
          ),
        ],
        oldestLoaded: true,
        active: true,
        now: 14000,
      );
      // 4.0s of wall clock; the frozen tok/s would drop (a step is still
      // streaming), the live one keeps the completed step's 100.0.
      expect(footers, {2: '4.0s · 0 compactions · 100.0 tok/s'});
    });
  });

  group('loadCurrentTurn', () {
    /// A scripted page source: serves [history] (oldest-first) newest-first in
    /// pages of [pageSize], counting every fetch.
    Future<MessagePage> fetch(
      List<SessionMessage> history,
      int pageSize,
      List<int> requests,
      String? cursor,
    ) async {
      requests.add(cursor == null ? 0 : int.parse(cursor));
      final newestFirst = history.reversed.toList();
      final offset = cursor == null ? 0 : int.parse(cursor);
      final slice = newestFirst.skip(offset).take(pageSize).toList();
      final next = offset + pageSize < history.length
          ? '${offset + pageSize}'
          : null;
      // Return the slice oldest-first (chronological).
      return MessagePage(messages: slice.reversed.toList(), nextCursor: next);
    }

    test(
      'an idle session reads only the pages that cover the last turn',
      () async {
        // 3 turns of 4 messages (prompt, 2 steps, closing idle) each.
        final history = <SessionMessage>[];
        for (var t = 0; t < 3; t++) {
          history.add(
            SessionMessage(id: 'u$t', role: 'user', created: t * 10000),
          );
          history.add(
            _step(
              id: 'a${t}0',
              created: t * 10000,
              streamed: t * 10000 + 1000,
              completed: t * 10000 + 2000,
              output: 10,
            ),
          );
          history.add(
            _step(
              id: 'a${t}1',
              created: t * 10000 + 2000,
              streamed: t * 10000 + 3000,
              completed: t * 10000 + 4000,
              output: 10,
            ),
          );
          history.add(
            SessionMessage(id: 'i$t', role: 'idle', created: t * 10000 + 4100),
          );
        }
        const pageSize = 3; // Small pages so the turn (4 msgs) spans > 1 page.
        final requests = <int>[];
        final page = await loadCurrentTurn(
          fetchPage: (cursor) => fetch(history, pageSize, requests, cursor),
        );
        // The last turn is the 4 newest messages; the read covers it plus the
        // overshoot page. It must not read the whole 12-message history: two
        // pages of 3 suffice (the current turn's opener idle is in the second).
        expect(requests.length, 2);
        expect(page.messages.length, 6);
        // The window of the loaded messages is the current (last) turn.
        final (start, end) = turnWindow(page.messages);
        expect(
          end - start,
          3,
        ); // prompt + 2 steps (the closing idle is at end).
        expect(page.nextCursor, isNotNull); // older pages remain.
      },
    );

    test('an active session stops at the first idle marker', () async {
      // One completed turn, then an active turn (no closing idle).
      final history = <SessionMessage>[
        SessionMessage(id: 'u0', role: 'user', created: 0),
        _step(
          id: 'a0',
          created: 0,
          streamed: 1000,
          completed: 2000,
          output: 10,
        ),
        SessionMessage(id: 'i0', role: 'idle', created: 2100),
        SessionMessage(id: 'u1', role: 'user', created: 10000),
        _step(
          id: 'a1',
          created: 10000,
          streamed: 11000,
          completed: 12000,
          output: 10,
        ),
      ];
      const pageSize = 2;
      final requests = <int>[];
      final page = await loadCurrentTurn(
        fetchPage: (cursor) => fetch(history, pageSize, requests, cursor),
      );
      // The active turn is 2 messages; with the opener idle it spans two
      // pages of 2 (not the full 5-message history).
      expect(requests.length, 2);
      final (start, end) = turnWindow(page.messages);
      expect(end - start, 2); // prompt + 1 step.
    });

    test('a single open turn reads its whole (small) history', () async {
      // No idle markers at all: the turn is the whole history.
      final history = <SessionMessage>[
        SessionMessage(id: 'u0', role: 'user', created: 0),
        _step(
          id: 'a0',
          created: 0,
          streamed: 1000,
          completed: 2000,
          output: 10,
        ),
      ];
      const pageSize = 3;
      final requests = <int>[];
      final page = await loadCurrentTurn(
        fetchPage: (cursor) => fetch(history, pageSize, requests, cursor),
      );
      expect(requests.length, 1);
      expect(page.messages, history);
      expect(page.nextCursor, isNull);
    });

    test('a deep legacy history stops at its last prompt', () async {
      // No idle markers anywhere (legacy): 100 old turns then the running
      // one. The read must bound at the last prompt, not walk the history.
      final history = <SessionMessage>[];
      for (var t = 0; t < 100; t++) {
        history.add(
          SessionMessage(id: 'u$t', role: 'user', created: t * 10000),
        );
        history.add(
          _step(
            id: 'a$t',
            created: t * 10000,
            streamed: t * 10000 + 1000,
            completed: t * 10000 + 2000,
            output: 10,
          ),
        );
      }
      history.add(SessionMessage(id: 'u999', role: 'user', created: 999000));
      const pageSize = 10;
      final requests = <int>[];
      final page = await loadCurrentTurn(
        fetchPage: (cursor) => fetch(history, pageSize, requests, cursor),
      );
      // First page: 5 older turns' content (no prompt? no: prompts every 2)
      // — the first page holds prompts, so the prompt bound triggers the
      // overshoot page and the stop: two pages, never the 201-message walk.
      expect(requests.length, 2);
      expect(page.messages.length, 20);
      // The loaded window's Turn is the running one: its last prompt is the
      // first loaded message's newest prompt.
      final (start, end) = turnWindow(page.messages);
      expect(page.messages.sublist(start, end).first.role, 'user');
      expect(page.nextCursor, isNotNull); // the rest stays lazy.
    });

    test('an empty history reads nothing', () async {
      final requests = <int>[];
      final page = await loadCurrentTurn(
        fetchPage: (cursor) => fetch(const [], 5, requests, cursor),
      );
      expect(page.messages, isEmpty);
      expect(page.nextCursor, isNull);
      expect(requests.length, 1);
    });
  });
}
