import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/sessions/cancel_dedup.dart';

/// The cancel's follow-on dedup (issue #258): the one pure, per-session
/// classifier that answers the same-turn question — *is this
/// `session.execution.interrupted` terminal the follow-on of a cancel that
/// was already announced?* (issue #164).
///
/// This is the rule's single home: the push dispatcher and the sound mapper
/// each feed one [CancelDedup] instance from their own event stream, and
/// both read the same verdicts. Driven **directly** — no dispatcher, no
/// mapper, no stream — the suite pins the classifier's contract:
///
/// - the cancel's follow-on terminal is the cancel's outcome (suppressed,
///   and only once — the marker is consumed);
/// - a turn's start clears a stale marker (a terminal missed, e.g. across a
///   restart), so the fresh turn's own terminal is never suppressed;
/// - the marker is per session (one session's cancel never suppresses
///   another's outcomes);
/// - a terminal with no preceding cancel is a genuine interrupt.
void main() {
  group('CancelDedup (issue #258)', () {
    late CancelDedup dedup;

    setUp(() {
      dedup = CancelDedup();
    });

    test('a cancel and its follow-on terminal are one outcome: the follow-on '
        'is suppressed, and only once (the marker is consumed)', () {
      dedup.cancelled('ses_1');
      // The service-settled terminal of the cancelled turn: already
      // announced as the cancel, so suppressed.
      expect(dedup.isCancelledFollowOn('ses_1'), isTrue);
      // The marker is consumed: a second terminal for the same session is
      // not the cancel's follow-on (it would be a genuine interrupt).
      expect(dedup.isCancelledFollowOn('ses_1'), isFalse);
    });

    test('a fresh turn start makes the next terminal genuine: cancel → '
        'interrupted → started → interrupted', () {
      dedup.cancelled('ses_1');
      // The cancelled turn's terminal: the follow-on, suppressed.
      expect(dedup.isCancelledFollowOn('ses_1'), isTrue);
      // The session starts a fresh turn…
      dedup.started('ses_1');
      // …and that turn's terminal is its own outcome, not the old cancel's.
      expect(dedup.isCancelledFollowOn('ses_1'), isFalse);
    });

    test('a stale marker (a terminal missed, e.g. across a restart) is '
        'cleared by the next turn start: cancel → started → interrupted', () {
      dedup.cancelled('ses_1');
      // The follow-on terminal never arrives (the bridge restarts in
      // between), so the marker would sit stale and suppress the *next*
      // turn's genuine interrupt — unless the start clears it.
      dedup.started('ses_1');
      expect(
        dedup.isCancelledFollowOn('ses_1'),
        isFalse,
        reason: 'the fresh turn\'s terminal is its own outcome',
      );
    });

    test('the dedup is per session: one session\'s cancel does not suppress '
        'another session\'s interrupted terminal', () {
      dedup.cancelled('ses_1');
      expect(
        dedup.isCancelledFollowOn('ses_2'),
        isFalse,
        reason: 'ses_2 never cancelled',
      );
      // And consuming ses_1's own follow-on still leaves ses_2 untouched.
      expect(dedup.isCancelledFollowOn('ses_1'), isTrue);
      expect(dedup.isCancelledFollowOn('ses_2'), isFalse);
    });

    test('a terminal with no preceding cancel is a genuine interrupt', () {
      expect(dedup.isCancelledFollowOn('ses_1'), isFalse);
    });

    test('cancels of two sessions are tracked independently: each '
        'follow-on is suppressed exactly once', () {
      dedup.cancelled('ses_1');
      dedup.cancelled('ses_2');
      expect(dedup.isCancelledFollowOn('ses_1'), isTrue);
      expect(dedup.isCancelledFollowOn('ses_2'), isTrue);
      // Both markers consumed: nothing left to suppress.
      expect(dedup.isCancelledFollowOn('ses_1'), isFalse);
      expect(dedup.isCancelledFollowOn('ses_2'), isFalse);
    });

    test('a start without a cancel is a no-op', () {
      dedup.started('ses_1');
      expect(dedup.isCancelledFollowOn('ses_1'), isFalse);
    });

    test('a cancel after a consumed follow-on re-marks the session: '
        'cancel → interrupted → cancel → interrupted', () {
      dedup.cancelled('ses_1');
      expect(dedup.isCancelledFollowOn('ses_1'), isTrue);
      // The same session cancels a later turn: the marker is re-added, so
      // that turn's terminal is its follow-on again.
      dedup.cancelled('ses_1');
      expect(dedup.isCancelledFollowOn('ses_1'), isTrue);
    });
  });
}
