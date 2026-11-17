import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/session_detail.dart';
import 'package:opencodebridge/model/turn_active.dart';

const _zero = TokenUsage(
  input: 0,
  output: 0,
  reasoning: 0,
  cacheRead: 0,
  cacheWrite: 0,
);

/// A session detail with the service's [active] fact (and no cancel
/// capability of note) — the only detail field the Active rule reads.
SessionDetail _detail({bool active = false}) => SessionDetail(
  id: 'ses_1',
  title: 'external',
  location: '/x',
  cost: 0,
  tokens: _zero,
  outcome: null,
  active: active,
);

// -- The history shapes the rule reads -------------------------------------

/// A user prompt.
SessionMessage _user([String id = 'u']) =>
    SessionMessage(id: id, role: 'user', text: 'go', created: 0);

/// An assistant step: [completed] `null` while it streams (in-flight), set
/// once it finishes.
SessionMessage _step({String id = 'a', int? completed}) =>
    SessionMessage(id: id, role: 'assistant', completed: completed);

/// The turn-boundary marker that closes a turn.
SessionMessage _idle([String id = 'i']) => SessionMessage(id: id, role: 'idle');

/// A context-compaction marker (carries no Active signal of its own).
SessionMessage _compaction([String id = 'c']) =>
    SessionMessage(id: id, role: 'compaction');

/// A synthetic prompt (a steer-like row the rule treats like a user prompt).
SessionMessage _synthetic([String id = 's']) =>
    SessionMessage(id: id, role: 'synthetic');

/// One row of the Active table: the PREVIOUS decision (the ratchet input),
/// the freshly-read [detail] and [history], and the expected decision.
typedef _Case = ({
  String name,
  bool prev,
  SessionDetail detail,
  List<SessionMessage> history,
  bool active,
});

/// All the (active, tick, poll, live) rows are `active` for all four: while
/// Active the ticking clock, the retry poll, and the live footer's flag are
/// armed together; while settled, all are off. The table pins them as one.
final _table = <_Case>[
  // -- Settled: the history ends closed and the service lists it idle ----
  (
    name: 'opened idle: a completed turn ends on its closing marker',
    prev: false,
    detail: _detail(),
    history: [_user(), _step(completed: 1000), _idle()],
    active: false,
  ),
  (
    name: 'opened idle: an empty history (a fresh session)',
    prev: false,
    detail: _detail(),
    history: const [],
    active: false,
  ),
  (
    name: 'opened idle: a trailing compaction rides past the closing marker',
    prev: false,
    detail: _detail(),
    history: [_user(), _step(completed: 1000), _idle(), _compaction()],
    active: false,
  ),

  // -- Settled: the queued-vs-just-started ambiguity (issue #129) --------
  // A lone prompt after the newest idle marker is queued (not running): the
  // detail is idle, so it stays settled — the footer keeps the previous turn.
  (
    name:
        'queued prompt: a lone prompt after the closing marker stays '
        'settled (issue #129)',
    prev: false,
    detail: _detail(),
    history: [_user(), _step(completed: 1000), _idle(), _user('u2')],
    active: false,
  ),
  (
    name:
        'queued prompt: the same shape with no step and no marker stays '
        'settled',
    prev: false,
    detail: _detail(),
    history: [_user()],
    active: false,
  ),
  (
    name: 'queued prompt: a synthetic lone prompt stays settled',
    prev: false,
    detail: _detail(),
    history: [_synthetic()],
    active: false,
  ),

  // -- Settled: a mid-turn history arms the turn without the detail -------
  (
    name: 'opened mid-turn: a streaming step (no closing marker)',
    prev: false,
    detail: _detail(),
    history: [_user(), _step()],
    active: true,
  ),
  (
    name:
        'opened mid-turn: a steer prompt whose step precedes it (issue '
        '#123)',
    prev: false,
    detail: _detail(),
    history: [_idle(), _user(), _step(completed: 1000), _user('u2')],
    active: true,
  ),
  (
    name:
        'opened mid-turn: a steer in the first (unclosed) turn (issue '
        '#123)',
    prev: false,
    detail: _detail(),
    history: [_user(), _step(completed: 1000), _user('u2')],
    active: true,
  ),
  (
    name: 'opened mid-turn: an in-flight step with no prompt yet',
    prev: false,
    detail: _detail(),
    history: [_step()],
    active: true,
  ),

  // -- Active fact: the service lists the session Active ------------------
  // The detail is the authoritative word; it arms the footer even when the
  // history has not caught up (still ends on the previous turn's marker).
  (
    name:
        'active fact: the detail arms the turn (just started, prompt '
        'settled into the history)',
    prev: false,
    detail: _detail(active: true),
    history: [_user(), _step(completed: 1000), _idle(), _user('u2')],
    active: true,
  ),
  (
    name:
        'turn flip: the detail is Active while the normalize read still '
        'ends on the previous closing marker',
    prev: false,
    detail: _detail(active: true),
    history: [_user(), _step(completed: 1000), _idle()],
    active: true,
  ),

  // -- The ratchet: a turn already Active is closed only by the ----------
  // authoritative history (the read ending on its idle marker) cross-checked
  // against the detail — a missed end event can never leave it ticking.
  (
    name: 'ratchet: a finished turn (detail idle, history closed) settles',
    prev: true,
    detail: _detail(),
    history: [_user(), _step(completed: 1000), _idle()],
    active: false,
  ),
  (
    name:
        'ratchet: a running turn stays armed while the detail is still '
        'Active, even if the history ends on the old closing marker',
    prev: true,
    detail: _detail(active: true),
    history: [_user(), _step(completed: 1000), _idle()],
    active: true,
  ),
  (
    name:
        'ratchet: a running turn stays armed while its step is still '
        'in-flight, even if the detail has gone idle',
    prev: true,
    detail: _detail(),
    history: [_idle(), _user(), _step()],
    active: true,
  ),
  (
    name:
        'ratchet: a running turn stays armed (detail Active, history '
        'in-flight)',
    prev: true,
    detail: _detail(active: true),
    history: [_idle(), _user(), _step()],
    active: true,
  ),
];

void main() {
  group('turnActive (the stateless rule of detail + history)', () {
    // The stateless core: with a settled previous decision the ratchet is
    // inert, so settleActive reduces to turnActive.
    for (final c in _table.where((c) => !c.prev)) {
      test(c.name, () {
        expect(turnActive(c.detail, c.history), c.active);
      });
    }
    test('the detail always wins when the service lists it Active', () {
      expect(turnActive(_detail(active: true), const []), isTrue);
      expect(
        turnActive(_detail(active: true), [
          _user(),
          _step(completed: 1000),
          _idle(),
        ]),
        isTrue,
      );
    });
  });

  group('settleActive (the view\'s reconciliation, incl. the ratchet)', () {
    // The full table, driven through settleActive from each case's previous
    // decision: (previous, detail, history) → (active, tick, poll, live).
    for (final c in _table) {
      test(c.name, () {
        final flags = settleActive(
          (active: c.prev, tick: c.prev, poll: c.prev, live: c.prev),
          c.detail,
          c.history,
        );
        // The four flags are the one decision: armed together while Active,
        // off together while settled.
        expect(flags.active, c.active, reason: c.name);
        expect(flags.tick, c.active, reason: '${c.name} — tick');
        expect(flags.poll, c.active, reason: '${c.name} — poll');
        expect(flags.live, c.active, reason: '${c.name} — live');
      });
    }

    test('a settled read is idempotent (no flapping across a repeat read)', () {
      final history = [_user(), _step(completed: 1000), _idle()];
      final settled = (active: false, tick: false, poll: false, live: false);
      for (var i = 0; i < 3; i++) {
        expect(settleActive(settled, _detail(), history), settled);
      }
    });

    test(
      'the gap case: a missed end event never leaves the footer ticking',
      () {
        // The turn ran and its end event was missed across a stream gap: the
        // view is still Active, but the authoritative re-read lands with the
        // detail idle and the history ending on the turn\'s closing marker.
        // It settles — the live footer can never tick on a finished turn.
        final prev = (active: true, tick: true, poll: true, live: true);
        final history = [_user(), _step(completed: 1000), _idle()];
        expect(settleActive(prev, _detail(), history).active, isFalse);
      },
    );

    test('the gap case: the cross-check keeps a running turn armed', () {
      // The same re-read, but the turn is genuinely still running (its step
      // is in-flight in the history, and/or the service still lists it
      // Active): the footer must NOT drop out.
      final prev = (active: true, tick: true, poll: true, live: true);
      final inFlight = [_idle(), _user(), _step()];
      expect(settleActive(prev, _detail(), inFlight).active, isTrue);
      expect(
        settleActive(prev, _detail(active: true), inFlight).active,
        isTrue,
      );
      expect(settleActive(prev, _detail(), [_user(), _step()]).active, isTrue);
    });
  });

  group('historyEndsOnIdle', () {
    test('true on a closing marker, skipping a trailing compaction', () {
      expect(
        historyEndsOnIdle([_user(), _step(completed: 1), _idle()]),
        isTrue,
      );
      expect(
        historyEndsOnIdle([
          _user(),
          _step(completed: 1),
          _idle(),
          _compaction(),
        ]),
        isTrue,
      );
    });
    test('false on an in-flight step, a lone prompt, or an empty history', () {
      expect(historyEndsOnIdle([_user(), _step()]), isFalse);
      expect(
        historyEndsOnIdle([_user(), _step(completed: 1), _idle(), _user('u2')]),
        isFalse,
      );
      expect(historyEndsOnIdle(const []), isFalse);
    });
  });
}
