// The AFK run's state machine (spec #376, "The per-issue state machine
// (bridge-owned)", T3): the five states `idle → dispatched → pr-open →
// done` plus the terminal `failed`, and the per-action predicates — each
// tested against the full state set (every admissible transition, every
// refused one) as pure logic: no I/O, no network.

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/afk/afk_run_state.dart';

/// The full state set (spec #376): the four forward states, the terminal
/// `failed`, and two unknown strings outside the set (the refusal, not an
/// admission).
const _states = <(String, AfkRunStateKind?)>[
  ('idle', AfkRunStateKind.idle),
  ('dispatched', AfkRunStateKind.dispatched),
  ('pr-open', AfkRunStateKind.prOpen),
  ('done', AfkRunStateKind.done),
  ('failed', AfkRunStateKind.failed),
  ('pr_open', null),
  ('', null),
];

const _actions = ['dispatch', 'openPr', 'retry', 'fail', 'complete'];

/// The full transition matrix (spec #376's "Transitions"): for every state,
/// the actions admissible in it — the one table the exhaustive test and the
/// per-action tests both read, so the matrix and the predicates cannot drift
/// apart silently.
const _matrix = <String, Set<String>>{
  // The ready admission feeds the agent (the cap slot is enforced at the
  // spawn boundary, a later ticket).
  'idle': {'dispatch'},
  // In flight: the `PR opened` narration (bridge-confirmed) opens the PR,
  // a `FAILED` narration retries (retries remaining) or fails (exhausted).
  'dispatched': {'openPr', 'retry', 'fail'},
  // The human's review is the exit: the issue closes (a PR closed unmerged
  // also lands here) and the run is done.
  'pr-open': {'complete'},
  // Done is the end.
  'done': {},
  // Terminal for the system: only the deliberate retry (the human re-adds
  // `ready-for-agent`) re-dispatches it, with the counter reset.
  'failed': {'dispatch'},
};

AfkRunState _s(String wire) => AfkRunState.parse(wire);

bool _predicate(AfkRunState state, String action) => switch (action) {
  'dispatch' => state.canDispatch,
  'openPr' => state.canOpenPr,
  'retry' => state.canRetry,
  'fail' => state.canFail,
  'complete' => state.canComplete,
  _ => false,
};

void main() {
  group('AfkRunState.parse / kind', () {
    test('every named state parses to its kind, unknown strings refuse', () {
      for (final (wire, kind) in _states) {
        final state = AfkRunState.parse(wire);
        expect(state.wire, wire, reason: 'wire of $wire');
        expect(state.kind, kind, reason: 'kind of $wire');
        expect(state.isKnown, kind != null, reason: 'isKnown of $wire');
      }
    });
  });

  group('the per-action predicates — the full state set', () {
    test('canDispatch: idle (the admission) and failed (the deliberate '
        'retry) only', () {
      expect(_s('idle').canDispatch, isTrue);
      expect(_s('failed').canDispatch, isTrue);
      for (final (wire, _) in _states) {
        if (wire == 'idle' || wire == 'failed') continue;
        expect(_s(wire).canDispatch, isFalse, reason: wire);
      }
    });

    test('canOpenPr: only dispatched', () {
      expect(_s('dispatched').canOpenPr, isTrue);
      for (final (wire, _) in _states) {
        if (wire == 'dispatched') continue;
        expect(_s(wire).canOpenPr, isFalse, reason: wire);
      }
    });

    test('canRetry: only dispatched (the retry is a self-transition)', () {
      expect(_s('dispatched').canRetry, isTrue);
      for (final (wire, _) in _states) {
        if (wire == 'dispatched') continue;
        expect(_s(wire).canRetry, isFalse, reason: wire);
      }
    });

    test('canFail: only dispatched (retries exhausted)', () {
      expect(_s('dispatched').canFail, isTrue);
      for (final (wire, _) in _states) {
        if (wire == 'dispatched') continue;
        expect(_s(wire).canFail, isFalse, reason: wire);
      }
    });

    test('canComplete: only pr-open', () {
      expect(_s('pr-open').canComplete, isTrue);
      for (final (wire, _) in _states) {
        if (wire == 'pr-open') continue;
        expect(_s(wire).canComplete, isFalse, reason: wire);
      }
    });

    test('isTerminal: done and failed (the system stops acting)', () {
      expect(_s('done').isTerminal, isTrue);
      expect(_s('failed').isTerminal, isTrue);
      for (final (wire, _) in _states) {
        if (wire == 'done' || wire == 'failed') continue;
        expect(_s(wire).isTerminal, isFalse, reason: wire);
      }
    });

    test('the unknown states refuse every action (the refusal, not an '
        'admission)', () {
      for (final (wire, _) in _states) {
        if (AfkRunState.parse(wire).isKnown) continue;
        final state = _s(wire);
        expect(state.isKnown, isFalse);
        for (final action in _actions) {
          expect(_predicate(state, action), isFalse, reason: '$action/$wire');
        }
        expect(state.isTerminal, isFalse, reason: wire);
      }
    });
  });

  group('the exhaustive transition matrix', () {
    test('every admissible transition and every refused one', () {
      for (final (wire, _) in _states) {
        final state = _s(wire);
        final admissible = _matrix[wire] ?? const <String>{};
        for (final action in _actions) {
          expect(
            _predicate(state, action),
            admissible.contains(action),
            reason: '$action from $wire',
          );
        }
      }
    });

    test('the forward path idles through done, the failure path hands '
        'back', () {
      // The happy path, one step at a time (the spec's transition list).
      expect(_s('idle').canDispatch, isTrue);
      expect(_s('dispatched').canOpenPr, isTrue);
      expect(_s('pr-open').canComplete, isTrue);
      expect(_s('done').isTerminal, isTrue);
      expect(_s('done').canDispatch, isFalse);

      // The failure path: the retry loops on dispatched, the exhaustion
      // lands failed, and the deliberate retry returns to dispatched.
      expect(_s('dispatched').canRetry, isTrue);
      expect(_s('dispatched').canFail, isTrue);
      expect(_s('failed').canFail, isFalse);
      expect(_s('failed').canOpenPr, isFalse);
      expect(_s('failed').canDispatch, isTrue);
    });
  });
}
