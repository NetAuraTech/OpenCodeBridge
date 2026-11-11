import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/events/event_hub.dart';
import 'package:opencodebridge/bridge/events/opencode_event_service.dart';
import 'package:opencodebridge/bridge/events/turn_tracker.dart';

/// The in-flight message id the cancel needs (issue #164) is tracked off the
/// unified event stream: the service's active list is TUI-attached sessions
/// only, so the bridge re-derives a turn from `session.execution.*` and the
/// `assistantMessageID` the stream names while it runs.
void main() {
  // A session-scoped opencode event (a durable seq names the session).
  String ev(
    String type, {
    String session = 'ses_1',
    Map<String, Object?>? data,
  }) => jsonEncode({
    'id': 'evt_$type',
    'type': type,
    'data': data ?? const <String, Object?>{},
    'durable': {'aggregateID': session, 'seq': 1, 'version': 1},
  });

  late TurnTracker tracker;
  setUp(() => tracker = TurnTracker());

  test('idle: no turn is running and no in-flight message', () {
    expect(tracker.isRunning('ses_1'), isFalse);
    expect(tracker.inFlightMessageID('ses_1'), isNull);
  });

  test('a started turn is running, with no message named yet', () {
    tracker.write(ev('session.execution.started'));
    expect(tracker.isRunning('ses_1'), isTrue);
    expect(tracker.inFlightMessageID('ses_1'), isNull);
  });

  test(
    'the in-flight message is the last assistantMessageID the stream named',
    () {
      tracker.write(ev('session.execution.started'));
      tracker.write(
        ev('session.step.started', data: {'assistantMessageID': 'm1'}),
      );
      expect(tracker.inFlightMessageID('ses_1'), 'm1');
      // A later step names a new message; the last one wins.
      tracker.write(
        ev('session.step.ended', data: {'assistantMessageID': 'm1'}),
      );
      tracker.write(
        ev('session.step.started', data: {'assistantMessageID': 'm2'}),
      );
      tracker.write(
        ev(
          'session.text.delta',
          data: {'assistantMessageID': 'm2', 'delta': 'x'},
        ),
      );
      expect(tracker.inFlightMessageID('ses_1'), 'm2');
      expect(tracker.isRunning('ses_1'), isTrue);
    },
  );

  test(
    'a terminal outcome closes the turn and clears the in-flight message',
    () {
      tracker.write(ev('session.execution.started'));
      tracker.write(
        ev('session.step.started', data: {'assistantMessageID': 'm1'}),
      );
      tracker.write(ev('session.execution.succeeded'));
      expect(tracker.isRunning('ses_1'), isFalse);
      expect(tracker.inFlightMessageID('ses_1'), isNull);
    },
  );

  test('a failed turn closes the turn too', () {
    tracker.write(ev('session.execution.started'));
    tracker.write(ev('session.execution.failed'));
    expect(tracker.isRunning('ses_1'), isFalse);
  });

  test('an interrupted turn closes the turn too', () {
    tracker.write(ev('session.execution.started'));
    tracker.write(ev('session.execution.interrupted'));
    expect(tracker.isRunning('ses_1'), isFalse);
  });

  test('the bridge-native cancel event closes the tracked turn (no loop)', () {
    tracker.write(ev('session.execution.started'));
    tracker.write(
      ev('session.step.started', data: {'assistantMessageID': 'm1'}),
    );
    // Our own `session.turn.cancelled` (bridge-native, data.sessionID) closes
    // the turn so a second cancel reads the session idle.
    tracker.write(
      jsonEncode({
        'id': 'evt_cancelled',
        'type': 'session.turn.cancelled',
        'data': {'sessionID': 'ses_1', 'messageID': 'm1'},
      }),
    );
    expect(tracker.isRunning('ses_1'), isFalse);
    expect(tracker.inFlightMessageID('ses_1'), isNull);
  });

  test('sessions are tracked independently (the id is globally unique)', () {
    tracker.write(ev('session.execution.started', session: 'ses_a'));
    tracker.write(
      ev(
        'session.step.started',
        session: 'ses_a',
        data: {'assistantMessageID': 'ma'},
      ),
    );
    tracker.write(ev('session.execution.started', session: 'ses_b'));
    expect(tracker.isRunning('ses_a'), isTrue);
    expect(tracker.inFlightMessageID('ses_a'), 'ma');
    expect(tracker.isRunning('ses_b'), isTrue);
    expect(tracker.inFlightMessageID('ses_b'), isNull);
    tracker.write(ev('session.execution.succeeded', session: 'ses_a'));
    expect(tracker.isRunning('ses_a'), isFalse);
    expect(tracker.isRunning('ses_b'), isTrue);
  });

  test('an event with no session anywhere is ignored', () {
    tracker.write(
      jsonEncode({
        'id': 'evt_x',
        'type': 'session.execution.started',
        'data': const <String, Object?>{},
      }),
    );
    expect(tracker.isRunning('ses_1'), isFalse);
    // A malformed frame must not throw.
    tracker.write('not json at all');
    expect(tracker.isRunning('ses_1'), isFalse);
  });

  test('attached to the hub it tracks off the fanned-out stream', () async {
    final upstream = _FakeUpstream();
    final hub = EventHub(service: upstream);
    hub.add(tracker);
    upstream.add(
      OpencodeEvent(
        raw: ev('session.execution.started'),
        type: 'session.execution.started',
      ),
    );
    upstream.add(
      OpencodeEvent(
        raw: ev('session.step.started', data: {'assistantMessageID': 'm1'}),
        type: 'session.step.started',
      ),
    );
    await _until(() => tracker.isRunning('ses_1'));
    expect(tracker.inFlightMessageID('ses_1'), 'm1');
    await hub.close();
  });
}

class _FakeUpstream implements OpencodeEventService {
  final StreamController<OpencodeEvent> controller =
      StreamController<OpencodeEvent>.broadcast();
  void add(OpencodeEvent event) => controller.add(event);
  @override
  Stream<OpencodeEvent> get events => controller.stream;
  @override
  Future<void> close() async {}
}

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for the tracker to settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
