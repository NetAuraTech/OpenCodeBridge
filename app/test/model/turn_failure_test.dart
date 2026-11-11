import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/turn_stats.dart';

/// The provider rate-limit error of the captured in-flight fixtures
/// (issue #154's probe), reused here as the terminal error of an
/// exhausted-retry turn.
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

void main() {
  group('turnFailureAt (issue #157: the turn that failed its retries)', () {
    test(
      'an idle-only failure (no assistant row) reads its error off the idle',
      () {
        // The captured exhausted / forced-failure turn (issue #154): the
        // terminal error lands on the `idle` marker, no assistant row.
        final history = [
          SessionMessage(id: 'u1', role: 'user', text: 'go', created: 1000),
          SessionMessage(
            id: 'i1',
            role: 'idle',
            outcome: 'failed',
            error: _noRouteError,
          ),
        ];
        final failure = turnFailureAt(history, history.length - 1);
        expect(failure, isNotNull);
        expect(failure!.error, _noRouteError);
        // No assistant row, no in-flight retry: the durable state carries no
        // attempt count, so the block must not invent one.
        expect(failure.attempts, isNull);
      },
    );

    test('an assistant-carried terminal error (the exhausted-retry case)', () {
      final history = [
        SessionMessage(id: 'u1', role: 'user', text: 'go', created: 1000),
        SessionMessage(
          id: 'a1',
          role: 'assistant',
          error: _rateLimitError,
          created: 1100,
          completed: 1900,
        ),
        SessionMessage(id: 'i1', role: 'idle', outcome: 'failed'),
      ];
      final failure = turnFailureAt(history, history.length - 1);
      expect(failure, isNotNull);
      // The idle carries no error of its own: the block reads the turn's
      // terminal error off the assistant (the probe's Q3 distinction).
      expect(failure!.error, _rateLimitError);
      expect(failure.attempts, isNull);
    });

    test('the idle error wins over the assistant error when both are set', () {
      final history = [
        SessionMessage(id: 'u1', role: 'user', text: 'go', created: 1000),
        SessionMessage(id: 'a1', role: 'assistant', error: _rateLimitError),
        SessionMessage(
          id: 'i1',
          role: 'idle',
          outcome: 'failed',
          error: _noRouteError,
        ),
      ];
      final failure = turnFailureAt(history, history.length - 1);
      expect(failure!.error, _noRouteError);
    });

    test('the attempt count is carried only when the durable state has it', () {
      // The probe's rule: `retry` and `error` are never both on one message.
      // The in-flight row carries the count (a multi-step turn keeps them on
      // separate rows), the terminal row carries the failure.
      final history = [
        SessionMessage(id: 'u1', role: 'user', text: 'go', created: 1000),
        SessionMessage(
          id: 'a1',
          role: 'assistant',
          retry: const MessageRetry(
            attempt: 3,
            at: 1200,
            error: _rateLimitError,
          ),
        ),
        SessionMessage(id: 'a2', role: 'assistant', error: _rateLimitError),
        SessionMessage(id: 'i1', role: 'idle', outcome: 'failed'),
      ];
      final failure = turnFailureAt(history, history.length - 1);
      expect(failure, isNotNull);
      expect(failure!.error, _rateLimitError);
      // The block says how many attempts ran (3), and nothing more — it never
      // invents a maximum.
      expect(failure.attempts, 3);
    });

    test('a succeeded turn has no failure block', () {
      final history = [
        SessionMessage(id: 'u1', role: 'user', text: 'go', created: 1000),
        SessionMessage(id: 'a1', role: 'assistant', text: 'ok'),
        SessionMessage(id: 'i1', role: 'idle', outcome: 'succeeded'),
      ];
      expect(turnFailureAt(history, history.length - 1), isNull);
    });

    test('an interrupted turn is not a failure (no block, distinct label)', () {
      final history = [
        SessionMessage(id: 'u1', role: 'user', text: 'go', created: 1000),
        SessionMessage(id: 'a1', role: 'assistant', text: 'partial'),
        SessionMessage(id: 'i1', role: 'idle', outcome: 'interrupted'),
      ];
      expect(turnFailureAt(history, history.length - 1), isNull);
    });

    test('a failed marker with no error anywhere carries an empty block', () {
      // The verdict is `failed` but neither the idle nor the assistant
      // carried an error: the block still marks the turn as failed, and
      // carries no provider copy to render.
      final history = [
        SessionMessage(id: 'u1', role: 'user', text: 'go', created: 1000),
        SessionMessage(id: 'i1', role: 'idle', outcome: 'failed'),
      ];
      final failure = turnFailureAt(history, history.length - 1);
      expect(failure, isNotNull);
      expect(failure!.error, isNull);
    });

    test(
      'only the turn the marker closes is read: earlier failed turns do not leak',
      () {
        final history = [
          // An earlier turn that failed.
          SessionMessage(id: 'u0', role: 'user', text: 'go', created: 0),
          SessionMessage(
            id: 'i0',
            role: 'idle',
            outcome: 'failed',
            error: _noRouteError,
          ),
          // The turn `idle` closes: it succeeded.
          SessionMessage(id: 'u1', role: 'user', text: 'again', created: 100),
          SessionMessage(id: 'a1', role: 'assistant', text: 'ok'),
          SessionMessage(id: 'i1', role: 'idle', outcome: 'succeeded'),
        ];
        // The marker's own turn is the one walked back from it; the earlier
        // failure (the previous turn) must not bleed into it. i1 is index 4
        // (succeeded), i0 index 1 (failed).
        expect(turnFailureAt(history, 4), isNull);
        // …and the earlier marker still reads its own failure.
        expect(turnFailureAt(history, 1)!.error, _noRouteError);
      },
    );

    test('a marker in the middle of the history resolves its own turn', () {
      final history = [
        SessionMessage(id: 'u0', role: 'user', text: 'go', created: 0),
        SessionMessage(
          id: 'i0',
          role: 'idle',
          outcome: 'failed',
          error: _noRouteError,
        ),
        SessionMessage(id: 'u1', role: 'user', text: 'again', created: 100),
        SessionMessage(id: 'a1', role: 'assistant', text: 'ok'),
        SessionMessage(id: 'i1', role: 'idle', outcome: 'succeeded'),
        // A later turn, failed again.
        SessionMessage(id: 'u2', role: 'user', text: 'once more', created: 200),
        SessionMessage(
          id: 'i2',
          role: 'idle',
          outcome: 'failed',
          error: _noRouteError,
        ),
      ];
      // i2 (index 6) failed, i0 (index 1) failed, i1 (index 4) succeeded.
      expect(turnFailureAt(history, 6)!.error, _noRouteError);
      expect(turnFailureAt(history, 1)!.error, _noRouteError);
      expect(turnFailureAt(history, 4), isNull);
    });
  });

  group('latestTurnOutcome (issue #157: the header outcome chip)', () {
    test('the newest closing idle marker wins over the detail', () {
      final history = [
        SessionMessage(id: 'u0', role: 'user', text: 'go', created: 0),
        SessionMessage(id: 'a0', role: 'assistant', text: 'ok'),
        SessionMessage(id: 'i0', role: 'idle', outcome: 'succeeded'),
        SessionMessage(id: 'u1', role: 'user', text: 'again', created: 100),
        SessionMessage(
          id: 'i1',
          role: 'idle',
          outcome: 'failed',
          error: _noRouteError,
        ),
      ];
      // The detail still reports the previous turn's `succeeded` (stale);
      // the chip must show the newest turn's `failed`.
      expect(latestTurnOutcome(history, detailOutcome: 'succeeded'), 'failed');
    });

    test('it falls back to the detail when the history has no verdict', () {
      const history = [
        SessionMessage(id: 'u0', role: 'user', text: 'go', created: 0),
        SessionMessage(id: 'a0', role: 'assistant', text: 'ok'),
      ];
      expect(latestTurnOutcome(history, detailOutcome: 'succeeded'),
        'succeeded');
      expect(latestTurnOutcome(history, detailOutcome: null), isNull);
    });

    test('an interrupted verdict is surfaced, not conflated with a failure',
        () {
      const history = [
        SessionMessage(id: 'u0', role: 'user', text: 'go', created: 0),
        SessionMessage(
          id: 'i0',
          role: 'idle',
          outcome: 'interrupted',
        ),
      ];
      expect(latestTurnOutcome(history, detailOutcome: 'succeeded'),
        'interrupted');
    });

    test('a running turn (no closing marker) keeps the detail', () {
      const history = [
        SessionMessage(id: 'i0', role: 'idle', outcome: 'succeeded'),
        SessionMessage(id: 'u1', role: 'user', text: 'go', created: 100),
        SessionMessage(id: 'a1', role: 'assistant'),
      ];
      // The newest closing marker is the older `succeeded`; the running turn
      // has not closed, so the chip shows the last settled verdict.
      expect(latestTurnOutcome(history, detailOutcome: null), 'succeeded');
    });
  });
}
