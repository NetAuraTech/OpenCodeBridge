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

  group('currentTurnRange', () {
    test('an idle session: the window is before the closing idle marker', () {
      final (start, end) = currentTurnRange([
        SessionMessage(id: 'u0', role: 'user', created: 0),
        _step(id: 'a0', created: 0, streamed: 1, completed: 2, output: 1),
        SessionMessage(id: 'i0', role: 'idle', created: 3),
        SessionMessage(id: 'u1', role: 'user', created: 10),
        _step(id: 'a1', created: 10, streamed: 20, completed: 30, output: 2),
        SessionMessage(id: 'i1', role: 'idle', created: 31),
      ]);
      expect(start, 3);
      expect(end, 5); // just before the closing idle at 5.
    });

    test('an active session: the window runs to the end', () {
      final (start, end) = currentTurnRange([
        SessionMessage(id: 'u0', role: 'user', created: 0),
        _step(id: 'a0', created: 0, streamed: 1, completed: 2, output: 1),
        SessionMessage(id: 'i0', role: 'idle', created: 3),
        SessionMessage(id: 'u1', role: 'user', created: 10),
        _step(id: 'a1', created: 10, streamed: 20, output: 2),
      ]);
      expect(start, 3);
      expect(end, 5);
    });

    test(
      'a legacy history without idle markers: the last prompt starts it',
      () {
        final (start, end) = currentTurnRange([
          SessionMessage(id: 'u0', role: 'user', created: 0),
          _step(id: 'a0', created: 0, streamed: 1, completed: 2, output: 1),
          SessionMessage(id: 'u1', role: 'user', created: 10),
          _step(id: 'a1', created: 10, streamed: 20, completed: 30, output: 2),
        ]);
        expect(start, 2);
        expect(end, 4);
      },
    );

    test('an empty history reads as the empty window', () {
      final (start, end) = currentTurnRange(const []);
      expect(start, 0);
      expect(end, 0);
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
        final (start, end) = currentTurnRange(page.messages);
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
      final (start, end) = currentTurnRange(page.messages);
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
      final (start, end) = currentTurnRange(page.messages);
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
