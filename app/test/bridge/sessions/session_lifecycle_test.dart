import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/events/turn_tracker.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';
import 'package:opencodebridge/bridge/sessions/session_lifecycle.dart';

/// The session-lifecycle module (issue #251, C1 of the turn-outcome series),
/// driven **directly** — no full HTTP route. These are the acceptance
/// criteria's module-level proofs:
///
/// - a cancel of a *running* turn reports `session.turn.cancelled` carrying
///   the in-flight message id;
/// - a cancel of a *non-running* turn emits no cancel-outcome event.
///
/// The turn state is read off a real [TurnTracker] fed the same wire events
/// the bridge's event hub would fan out (a turn opens on
/// `session.execution.started`; a step names the in-flight message).
void main() {
  group('SessionLifecycle.cancel (issue #251)', () {
    test('a cancel of a running turn reports session.turn.cancelled with the '
        'in-flight message id', () async {
      final tracker = TurnTracker();
      await _openTurn(tracker, 'ses_1', inFlight: 'msg_inflight');

      final cancels = <String>[];
      final emitted = <String>[];
      final lifecycle = SessionLifecycle(
        serviceCancel: (id) async => cancels.add(id),
        turnTracker: tracker,
        emit: emitted.add,
      );

      final outcome = await lifecycle.cancel('ses_1');

      // The service cancel ran, and the module decided to report a running
      // turn carrying the in-flight message.
      expect(cancels, ['ses_1']);
      expect(outcome.reported, isTrue);
      expect(outcome.messageID, 'msg_inflight');

      // The reported outcome is exactly one session.turn.cancelled frame,
      // with the session id and the in-flight message id.
      expect(emitted, hasLength(1));
      final frame = jsonDecode(emitted.single) as Map<String, Object?>;
      expect(frame['type'], 'session.turn.cancelled');
      expect(frame['data'], {
        'sessionID': 'ses_1',
        'messageID': 'msg_inflight',
      });
      // A bridge-native outcome: no durable seq (like session.closed).
      expect(frame.containsKey('durable'), isFalse);
    });

    test('a cancel of a running turn with no in-flight message reports the '
        'session only', () async {
      final tracker = TurnTracker();
      await _openTurn(tracker, 'ses_1'); // started, but no message named yet

      final cancels = <String>[];
      final emitted = <String>[];
      final lifecycle = SessionLifecycle(
        serviceCancel: (id) async => cancels.add(id),
        turnTracker: tracker,
        emit: emitted.add,
      );

      final outcome = await lifecycle.cancel('ses_1');

      expect(cancels, ['ses_1']);
      expect(outcome.reported, isTrue);
      expect(outcome.messageID, isNull);
      expect(emitted, hasLength(1));
      final frame = jsonDecode(emitted.single) as Map<String, Object?>;
      expect(frame['type'], 'session.turn.cancelled');
      expect(frame['data'], {'sessionID': 'ses_1'});
    });

    test(
      'a cancel of a non-running turn emits no cancel outcome event',
      () async {
        final tracker = TurnTracker(); // idle: no turn ever opened

        final cancels = <String>[];
        final emitted = <String>[];
        final lifecycle = SessionLifecycle(
          serviceCancel: (id) async => cancels.add(id),
          turnTracker: tracker,
          emit: emitted.add,
        );

        final outcome = await lifecycle.cancel('ses_idle');

        // The service still gets the cancel (an idle session accepts it
        // harmlessly), but the module reports nothing.
        expect(cancels, ['ses_idle']);
        expect(outcome.reported, isFalse);
        expect(outcome.messageID, isNull);
        expect(emitted, isEmpty, reason: 'an idle cancel emits no event');
      },
    );

    test(
      'a failed cancel propagates and emits no cancel outcome event',
      () async {
        final tracker = TurnTracker();
        await _openTurn(tracker, 'ses_1', inFlight: 'msg_inflight');

        final cancels = <String>[];
        final emitted = <String>[];
        final lifecycle = SessionLifecycle(
          serviceCancel: (id) async {
            cancels.add(id);
            throw const CancelUnsupportedError(
              'this service has no interrupt route',
            );
          },
          turnTracker: tracker,
          emit: emitted.add,
        );

        await expectLater(
          lifecycle.cancel('ses_1'),
          throwsA(isA<CancelUnsupportedError>()),
        );

        // The service was asked, but the refusal carries nothing out: no
        // cancel-outcome event, and the turn is left running for the retry.
        expect(cancels, ['ses_1']);
        expect(emitted, isEmpty, reason: 'a failed cancel carries nothing out');
        expect(tracker.isRunning('ses_1'), isTrue);
      },
    );

    test(
      'with no turn tracker the cancel never reports a running turn',
      () async {
        // A bridge with a cancel-capable service but no hub: the module
        // still cancels, but with no turn state it cannot report a running
        // turn, so it emits nothing.
        final cancels = <String>[];
        final emitted = <String>[];
        final lifecycle = SessionLifecycle(
          serviceCancel: (id) async => cancels.add(id),
          // turnTracker: null, emit: null
        );

        final outcome = await lifecycle.cancel('ses_1');

        expect(cancels, ['ses_1']);
        expect(outcome.reported, isFalse);
        expect(emitted, isEmpty);
      },
    );
  });
}

/// Open [sessionID]'s turn on [tracker]: `session.execution.started` (the turn
/// opens), and, when [inFlight] is named, a `session.step.started` that names
/// the in-flight assistant message. The wire shape is the same envelope the
/// bridge's event hub fans out to the tracker.
Future<void> _openTurn(
  TurnTracker tracker,
  String sessionID, {
  String? inFlight,
}) async {
  await tracker.write(
    jsonEncode({
      'id': 'evt_start',
      'type': 'session.execution.started',
      'data': <String, Object?>{},
      'durable': {'aggregateID': sessionID, 'seq': 1, 'version': 1},
    }),
  );
  if (inFlight != null) {
    await tracker.write(
      jsonEncode({
        'id': 'evt_step',
        'type': 'session.step.started',
        'data': {'assistantMessageID': inFlight},
        'durable': {'aggregateID': sessionID, 'seq': 2, 'version': 1},
      }),
    );
  }
}
