import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/row_projection.dart';

/// The provider rate-limit error, reused as the terminal error of the
/// exhausted-retry turn (the captured in-flight fixtures' error).
const _rateLimitError = StructuredError(
  type: 'provider.rate-limit',
  message: 'Provider request failed with HTTP 429: {…}',
  status: 429,
  body: '{"detail":{"error":{"type":"rate_limit_error"}}}',
);

const _noRouteError = StructuredError(
  type: 'provider.no-route',
  message: 'Model unavailable: amd/qwen3.8-flash-next',
);

/// A completed assistant step that reads the same footer as turn_stats's
/// fixtures: created at [created], streamed 100 output tokens over 1 s.
SessionMessage _step(int created, {required String id, int completed = 1500}) =>
    SessionMessage(
      id: id,
      role: 'assistant',
      text: 'answer',
      created: created,
      streamed: created + 1000,
      completed: completed,
      outputTokens: 100,
      reasoningTokens: 0,
    );

/// Projects [messages] under [facts] and hands back the row at [i].
RowProjection _row(
  int i,
  List<SessionMessage> messages, {
  bool turnActive = false,
  Set<String> liveMessageIds = const {},
  bool compacting = false,
  int? compactionIndex,
  bool oldestLoaded = true,
  int? now,
}) {
  final facts = TurnFacts(
    messages: messages,
    turnActive: turnActive,
    liveMessageIds: liveMessageIds,
    compacting: compacting,
    compactionIndex: compactionIndex,
    oldestLoaded: oldestLoaded,
    now: now,
  );
  return computeRowProjections(facts)[i];
}

void main() {
  group('computeRowProjections — role classification (issue #283)', () {
    test('an idle marker projects as the idle marker kind', () {
      final projection = _row(1, [
        SessionMessage(id: 'u', role: 'user', created: 0),
        SessionMessage(id: 'i', role: 'idle', created: 1),
      ]);
      expect(projection.kind, RowKind.idleMarker);
      expect(projection.message, isA<SessionMessage>());
    });

    test('a compaction marker projects as the compaction marker kind', () {
      final projection = _row(0, [
        SessionMessage(
          id: 'c',
          role: 'compaction',
          text: 'summary',
          created: 0,
        ),
      ]);
      expect(projection.kind, RowKind.compactionMarker);
    });

    test('user and assistant rows project as message rows', () {
      final projections = computeRowProjections(
        TurnFacts(
          messages: [
            SessionMessage(id: 'u', role: 'user', text: 'go', created: 0),
            _step(1, id: 'a'),
          ],
        ),
      );
      expect(projections.map((row) => row.kind), [
        RowKind.messageRow,
        RowKind.messageRow,
      ]);
    });

    test('a role the service adds later still projects as a message row: a new '
        'in-flow row kind is a derivation change, not a new build branch', () {
      // The default branch of the classification projects whatever role
      // the history carries as a message row, with the message row's
      // in-flow lines and copy-key rule — so a new row kind needs only
      // this derivation (and this test), never a branch in build.
      final projection = _row(
        0,
        [
          SessionMessage(
            id: 's',
            role: 'synthetic',
            text: 'note',
            retry: const MessageRetry(
              attempt: 1,
              at: 2000,
              error: _rateLimitError,
            ),
            created: 0,
          ),
        ],
        turnActive: true,
        liveMessageIds: {'s'},
      );
      expect(projection.kind, RowKind.messageRow);
      expect(projection.retry, isNotNull);
      expect(projection.inFlight, isTrue);
      expect(projection.copyKey, 'copy-message-0');
    });

    test('an empty history projects to no rows', () {
      expect(computeRowProjections(TurnFacts(messages: const [])), isEmpty);
    });
  });

  group('in-flow lines', () {
    test(
      'an interrupted turn projects its neutral stopped line on the marker',
      () {
        final projection = _row(1, [
          SessionMessage(id: 'u', role: 'user', created: 0),
          SessionMessage(id: 'i', role: 'idle', outcome: 'interrupted'),
        ]);
        expect(projection.stopped, isTrue);
        // A stop is not a failure: no error block, no retry line.
        expect(projection.failure, isNull);
        expect(projection.retry, isNull);
      },
    );

    test('a succeeded or pending marker carries no stopped line', () {
      for (final outcome in ['succeeded', null]) {
        final projection = _row(1, [
          SessionMessage(id: 'u', role: 'user', created: 0),
          SessionMessage(id: 'i', role: 'idle', outcome: outcome),
        ]);
        expect(projection.stopped, isFalse, reason: 'outcome $outcome');
      }
    });

    test(
      'an assistant row carries its in-flight retry line while it retries',
      () {
        final retry = const MessageRetry(
          attempt: 2,
          at: 12000,
          error: _rateLimitError,
        );
        final projection = _row(1, [
          SessionMessage(id: 'u', role: 'user', created: 0),
          SessionMessage(id: 'a', role: 'assistant', retry: retry, created: 1),
        ]);
        expect(projection.retry, retry);
        // The retry is not yet terminal: no failure block while it runs.
        expect(projection.failure, isNull);
      },
    );

    test('a row whose retry cleared carries no retry line (no trace)', () {
      final projection = _row(1, [
        SessionMessage(id: 'u', role: 'user', created: 0),
        SessionMessage(id: 'a', role: 'assistant', text: 'answer', created: 1),
      ]);
      expect(projection.retry, isNull);
    });

    test('the exhausted-retry failure block rides the error-carrying assistant '
        'row, not the marker', () {
      final retry = const MessageRetry(
        attempt: 3,
        at: 12000,
        error: _rateLimitError,
      );
      final projections = computeRowProjections(
        TurnFacts(
          messages: [
            SessionMessage(id: 'u', role: 'user', created: 1000), // 0
            SessionMessage(
              id: 'a',
              role: 'assistant',
              error: _rateLimitError,
              retry: retry,
              created: 1100,
              completed: 1900,
            ), // 1
            SessionMessage(id: 'i', role: 'idle', outcome: 'failed'), // 2
          ],
        ),
      );
      // The durable state carries the attempts, so the block shows them.
      expect(projections[1].failure, isNotNull);
      expect(projections[1].failure!.error, _rateLimitError);
      expect(projections[1].failure!.attempts, 3);
      // The marker closed the failed turn but carries no error itself.
      expect(projections[2].failure, isNull);
      // The exhausted-retry assistant row still shows its retry line.
      expect(projections[1].retry, retry);
    });

    test('the non-retryable failure block rides the idle marker itself', () {
      final projections = computeRowProjections(
        TurnFacts(
          messages: [
            SessionMessage(id: 'u', role: 'user', created: 1000), // 0
            SessionMessage(
              id: 'i',
              role: 'idle',
              outcome: 'failed',
              error: _noRouteError,
            ), // 1
          ],
        ),
      );
      // No assistant row exists (probe Q3): the block rides the marker.
      expect(projections[1].failure, isNotNull);
      expect(projections[1].failure!.error, _noRouteError);
      // No assistant row, no in-flight retry: no invented attempt count.
      expect(projections[1].failure!.attempts, isNull);
      // A failure is not a stop: no neutral stopped line.
      expect(projections[1].stopped, isFalse);
      expect(projections[0].failure, isNull);
    });

    test('an earlier failed turn keeps its block as the history loads', () {
      final projections = computeRowProjections(
        TurnFacts(
          messages: [
            SessionMessage(id: 'u0', role: 'user', created: 0), // 0
            SessionMessage(
              id: 'a0',
              role: 'assistant',
              error: _noRouteError,
              created: 1,
              completed: 9,
            ), // 1
            SessionMessage(id: 'i0', role: 'idle', outcome: 'failed'), // 2
            SessionMessage(id: 'u1', role: 'user', created: 10), // 3
            _step(10, id: 'a1'), // 4
          ],
        ),
      );
      expect(projections[1].failure, isNotNull);
      expect(projections[1].failure!.error, _noRouteError);
      // The window ends at its closing marker: the older block never
      // bleeds into the newer (still running) turn.
      expect(projections[3].failure, isNull);
      expect(projections[4].failure, isNull);
    });
  });

  group('live flags', () {
    test(
      'the live footer flag rides only the last row while the turn runs',
      () {
        final projections = computeRowProjections(
          TurnFacts(
            messages: [
              SessionMessage(id: 'u0', role: 'user', created: 0),
              _step(1, id: 'a0'),
              SessionMessage(id: 'i0', role: 'idle', created: 9),
              SessionMessage(id: 'u1', role: 'user', created: 10),
            ],
            turnActive: true,
          ),
        );
        expect(projections.map((row) => row.live), [false, false, false, true]);
      },
    );

    test('no row is live when the turn is not active', () {
      final projections = computeRowProjections(
        TurnFacts(
          messages: [
            SessionMessage(id: 'u', role: 'user', created: 0),
            _step(1, id: 'a'),
          ],
        ),
      );
      expect(projections.map((row) => row.live), [false, false]);
    });

    test('a message row is in-flight only while the turn streams into it', () {
      // The turn streams into row 1: in-flight.
      expect(
        _row(
          1,
          [
            SessionMessage(id: 'u', role: 'user', created: 0),
            SessionMessage(id: 'a1', role: 'assistant', created: 1),
          ],
          turnActive: true,
          liveMessageIds: {'a1'},
        ).inFlight,
        isTrue,
      );
      // A row the turn is not streaming into: not in-flight.
      expect(
        _row(
          0,
          [
            SessionMessage(id: 'u', role: 'user', created: 0),
            SessionMessage(id: 'a1', role: 'assistant', created: 1),
          ],
          turnActive: true,
          liveMessageIds: {'a1'},
        ).inFlight,
        isFalse,
      );
      // The turn is not active: nothing is in-flight, even a row whose id
      // the panel still tracks.
      expect(
        _row(
          1,
          [
            SessionMessage(id: 'u', role: 'user', created: 0),
            SessionMessage(id: 'a1', role: 'assistant', created: 1),
          ],
          liveMessageIds: {'a1'},
        ).inFlight,
        isFalse,
      );
      // A row without an id can never be matched in-flight.
      expect(
        _row(
          0,
          [SessionMessage(role: 'user', created: 0)],
          turnActive: true,
          liveMessageIds: {'a1'},
        ).inFlight,
        isFalse,
      );
    });

    test('the compaction in-flight flag rides the streaming marker', () {
      final history = [
        SessionMessage(id: 'c0', role: 'compaction', created: 0), // 0
        SessionMessage(
          id: 'c1',
          role: 'compaction',
          text: 'older summary',
          created: 1,
        ), // 1
      ];
      // The compaction streams into the live marker.
      expect(
        _row(
          0,
          history,
          compacting: true,
          compactionIndex: 0,
        ).compactionInFlight,
        isTrue,
      );
      // An older marker is not the one streaming.
      expect(
        _row(
          1,
          history,
          compacting: true,
          compactionIndex: 0,
        ).compactionInFlight,
        isFalse,
      );
      // No compaction in flight: no marker is flagged.
      expect(_row(0, history, compactionIndex: 0).compactionInFlight, isFalse);
      // A message row is never compaction-in-flight.
      expect(
        _row(
          0,
          [SessionMessage(id: 'u', role: 'user', created: 0)],
          compacting: true,
          compactionIndex: 0,
        ).compactionInFlight,
        isFalse,
      );
    });
  });

  group('footers (composed from computeTurnFooters)', () {
    test('a completed turn labels its closing marker row', () {
      final projections = computeRowProjections(
        TurnFacts(
          messages: [
            SessionMessage(role: 'user', text: 'go', created: 0),
            _step(0, id: 'a'),
            SessionMessage(id: 'i1', role: 'idle'),
          ],
          oldestLoaded: true,
        ),
      );
      expect(projections[2].footer, '1.5s · 0 compactions · 100.0 tok/s');
      expect(projections[0].footer, isNull);
      expect(projections[1].footer, isNull);
    });

    test('the active turn labels its last row with the live duration', () {
      final projection = _row(
        1,
        [
          SessionMessage(role: 'user', text: 'go', created: 0),
          // The step still streaming: no `completed` yet.
          SessionMessage(
            id: 'a',
            role: 'assistant',
            created: 1000,
            streamed: 1500,
            outputTokens: 50,
            reasoningTokens: 0,
          ),
        ],
        turnActive: true,
        now: 5000,
      );
      // Duration ticks from the prompt to the passed clock; the streaming
      // step carries no completed stats yet, so no tok/s.
      expect(projection.footer, '5.0s · 0 compactions');
      expect(projection.live, isTrue);
    });

    test('without a clock the active turn keeps its frozen label so far', () {
      final projection = _row(1, [
        SessionMessage(role: 'user', text: 'go', created: 0),
        _step(0, id: 'a'),
      ], turnActive: true);
      expect(projection.footer, '1.5s · 0 compactions · 100.0 tok/s');
    });
  });

  group('copy-key eligibility (issue #198)', () {
    test('a message row is copyable when it carries any content', () {
      // The body.
      expect(
        _row(0, [SessionMessage(role: 'user', text: 'go', created: 0)]).copyKey,
        'copy-message-0',
      );
      // The reasoning only.
      expect(
        _row(0, [
          SessionMessage(role: 'assistant', reasoning: 'hmm', created: 0),
        ]).copyKey,
        'copy-message-0',
      );
      // A tool card only.
      expect(
        _row(0, [
          SessionMessage(
            role: 'assistant',
            tools: const [ToolCall(name: 'read', status: 'completed')],
            created: 0,
          ),
        ]).copyKey,
        'copy-message-0',
      );
    });

    test('a message row without content is not copyable', () {
      expect(
        _row(0, [SessionMessage(role: 'user', created: 0)]).copyKey,
        isNull,
      );
    });

    test('a compaction marker is copyable only when it carries a summary', () {
      final history = [
        SessionMessage(id: 'c0', role: 'compaction', created: 0), // 0
        SessionMessage(
          id: 'c1',
          role: 'compaction',
          text: 'summary',
          created: 1,
        ), // 1
      ];
      expect(_row(0, history).copyKey, isNull);
      expect(_row(1, history).copyKey, 'copy-message-1');
    });

    test('an idle marker is never copyable', () {
      expect(
        _row(1, [
          SessionMessage(id: 'u', role: 'user', created: 0),
          SessionMessage(id: 'i', role: 'idle', created: 1),
        ]).copyKey,
        isNull,
      );
    });
  });

  group('the projection as a whole', () {
    test('one projection per row, in order, for equal facts', () {
      final messages = [
        SessionMessage(id: 'u', role: 'user', text: 'go', created: 0),
        _step(1, id: 'a'),
        SessionMessage(
          id: 'c',
          role: 'compaction',
          text: 'summary',
          created: 9,
        ),
        SessionMessage(
          id: 'i',
          role: 'idle',
          outcome: 'interrupted',
          created: 10,
        ),
      ];
      TurnFacts facts() => TurnFacts(
        messages: messages,
        turnActive: true,
        liveMessageIds: {'a'},
        compacting: true,
        compactionIndex: 2,
        oldestLoaded: true,
        now: 42,
      );
      final projections = computeRowProjections(facts());
      expect(projections.map((row) => row.kind), [
        RowKind.messageRow,
        RowKind.messageRow,
        RowKind.compactionMarker,
        RowKind.idleMarker,
      ]);
      // Each projection holds the row it projects.
      for (var i = 0; i < messages.length; i++) {
        expect(projections[i].message, messages[i]);
      }
      // Equal facts project to equal rows (the derivation is pure).
      expect(computeRowProjections(facts()), projections);
    });

    test('different turn facts project different rows', () {
      final messages = [
        SessionMessage(id: 'u', role: 'user', created: 0),
        SessionMessage(id: 'a', role: 'assistant', created: 1),
      ];
      final idle = computeRowProjections(TurnFacts(messages: messages));
      final active = computeRowProjections(
        TurnFacts(messages: messages, turnActive: true, liveMessageIds: {'a'}),
      );
      expect(idle, isNot(equals(active)));
      expect(active[1].live, isTrue);
      expect(active[1].inFlight, isTrue);
    });
  });
}
