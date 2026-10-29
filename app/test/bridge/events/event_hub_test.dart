import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/events/bridge_event.dart';
import 'package:opencodebridge/bridge/events/event_hub.dart';
import 'package:opencodebridge/bridge/events/opencode_event_service.dart';

void main() {
  late _FakeUpstream upstream;
  late EventHub hub;

  setUp(() {
    upstream = _FakeUpstream();
    hub = EventHub(service: upstream);
  });

  tearDown(() => hub.close());

  group('EventHub', () {
    test(
      'fans out every upstream event verbatim to every live connection',
      () async {
        final conn = _FakeConnection();
        hub.add(conn);
        expect(hub.connections, 1);

        upstream.add(OpencodeEvent(raw: _payload(1), type: 'session.updated'));
        upstream.add(OpencodeEvent(raw: _payload(2), type: 'session.updated'));
        await _until(() => conn.written.length == 2);

        expect(
          conn.written,
          [_payload(1), _payload(2)],
          reason:
              'payloads are re-emitted verbatim; the connection owns the '
              'SSE framing',
        );
      },
    );

    test(
      'two concurrent connections receive identical frames, in order',
      () async {
        final a = _FakeConnection();
        final b = _FakeConnection();
        hub.add(a);
        hub.add(b);

        final native = bridgeEvent(
          type: BridgeEventType.sessionClosed,
          data: {'id': 'ses_x'},
        );
        upstream.add(OpencodeEvent(raw: _payload(1), type: 'session.updated'));
        await _until(() => a.written.length == 1 && b.written.length == 1);
        hub.emit(native);
        await _until(() => a.written.length == 2 && b.written.length == 2);
        upstream.add(OpencodeEvent(raw: _payload(2), type: 'session.updated'));
        await _until(() => a.written.length == 3 && b.written.length == 3);

        expect(
          a.written,
          [_payload(1), native, _payload(2)],
          reason: 'opencode and bridge-native events share one ordered stream',
        );
        expect(
          b.written,
          a.written,
          reason: 'a raw SSE client and the app must see identical frames',
        );
      },
    );

    test(
      'a connection that goes away is dropped and stops receiving',
      () async {
        final gone = _FakeConnection();
        final live = _FakeConnection();
        hub.add(gone);
        hub.add(live);
        gone.disconnect();
        await _until(() => hub.connections == 1);

        upstream.add(OpencodeEvent(raw: _payload(1), type: 'session.updated'));
        await _until(() => live.written.length == 1);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          gone.written,
          isEmpty,
          reason: 'a dropped connection must not receive events',
        );
        expect(hub.connections, 1);
      },
    );

    test('a connection whose writes fail is not a fan-out failure', () async {
      final flaky = _FakeConnection();
      final live = _FakeConnection();
      hub.add(flaky);
      hub.add(live);
      flaky.failWrites = true;
      flaky.disconnect(); // The client's TCP close follows.
      upstream.add(OpencodeEvent(raw: _payload(1), type: 'session.updated'));
      await _until(() => live.written.length == 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(live.written, [_payload(1)]);
      expect(flaky.written, isEmpty);
    });

    test('add() after close() drops the connection immediately', () async {
      await hub.close();
      final conn = _FakeConnection();
      hub.add(conn);
      await _until(() => conn.closed);
      expect(hub.connections, 0);
    });

    test('close() closes live connections, the upstream service, and '
        'stops emitting', () async {
      final conn = _FakeConnection();
      hub.add(conn);
      upstream.add(OpencodeEvent(raw: _payload(1), type: 'session.updated'));
      await _until(() => conn.written.length == 1);

      await hub.close();
      expect(conn.closed, isTrue);
      expect(upstream.closed, isTrue);

      upstream.add(OpencodeEvent(raw: _payload(2), type: 'session.updated'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        conn.written,
        hasLength(1),
        reason: 'a closed hub must not emit after close',
      );
    });
  });
}

/// A scripted upstream event service: one broadcast controller.
class _FakeUpstream implements OpencodeEventService {
  final StreamController<OpencodeEvent> controller =
      StreamController<OpencodeEvent>.broadcast();
  var closed = false;

  void add(OpencodeEvent event) => controller.add(event);

  @override
  Stream<OpencodeEvent> get events => controller.stream;

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// An [EventConnection] that records what the hub writes to it.
class _FakeConnection implements EventConnection {
  final List<String> written = [];
  final Completer<void> _gone = Completer<void>();
  var failWrites = false;
  var closed = false;

  @override
  Future<void> write(String rawPayload) async {
    if (failWrites) throw StateError('client gone');
    written.add(rawPayload);
  }

  /// Simulate the client disconnecting on its own.
  void disconnect() => _markGone();

  @override
  Future<void> close() async {
    closed = true;
    _markGone();
  }

  void _markGone() {
    if (!_gone.isCompleted) _gone.complete();
  }

  @override
  Future<void> get done => _gone.future;
}

String _payload(int seq) =>
    '{"id":"evt_$seq","created":$seq,"type":"session.updated",'
    '"data":{"n":$seq},"durable":{"aggregateID":"ses_x","seq":$seq,"version":1}}';

Future<void> _until(
  bool Function() condition, {
  String message = 'condition',
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $message');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
