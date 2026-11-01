import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/events_client.dart';

void main() {
  late HttpServer server;
  late Uri base;
  late int connections;
  late List<String> Function(int n) framesFor;
  late bool Function(int n) holdFor;
  late int Function(int n) statusFor;

  setUp(() async {
    connections = 0;
    framesFor = (n) => const <String>[];
    holdFor = (n) => false;
    statusFor = (n) => HttpStatus.ok;
    server = await HttpServer.bind('127.0.0.1', 0);
    base = Uri.parse('http://127.0.0.1:${server.port}/');
    server.listen((req) async {
      final resp = req.response;
      resp.bufferOutput = false;
      if (req.method != 'GET' || req.uri.path != '/api/events') {
        resp.statusCode = HttpStatus.notFound;
        await resp.close();
        return;
      }
      final n = ++connections;
      final status = statusFor(n);
      if (status != HttpStatus.ok) {
        resp.statusCode = status;
        resp.write('{"error":"boom"}');
        await resp.close();
        return;
      }
      resp.headers.contentType = ContentType.parse('text/event-stream');
      resp.write(': connected\n\n');
      for (final frame in framesFor(n)) {
        resp.write('data: $frame\n\n');
      }
      if (holdFor(n)) {
        await resp.done; // Hold open (like a live bridge connection).
      } else {
        await resp.close();
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  group('EventsClient', () {
    test('decodes every data frame into a BridgeEvent, in order', () async {
      final client = EventsClient(base, reconnectDelay: _tick);
      try {
        framesFor = (n) => [_payload(seq: 1), _native, _payload(seq: 2)];
        holdFor = (n) => true;
        final events = <BridgeEvent>[];
        final subscription = client.events.listen(events.add);
        await client.connect();
        await _until(() => events.length == 3);

        expect(events.map((e) => e.type), [
          'session.updated',
          'session.closed',
          'session.updated',
        ]);
        expect(events[0].id, 'evt_ses_x_1');
        expect(events[0].durable?.aggregateID, 'ses_x');
        expect(events[0].durable?.seq, 1);
        expect(
          events[1].durable,
          null,
          reason: 'bridge-native events carry no durable',
        );
        expect(events[1].data, {'id': 'ses_x'});
        expect(events[2].durable?.seq, 2);
        await subscription.cancel();
      } finally {
        await client.disconnect();
      }
    });

    test('continuous per-session seq produces no gap', () async {
      final client = EventsClient(base, reconnectDelay: _tick);
      try {
        framesFor = (n) => [
          _payload(seq: 1),
          _payload(seq: 2),
          _payload(seq: 3),
        ];
        holdFor = (n) => true;
        final events = <BridgeEvent>[];
        final gaps = <SessionGap>[];
        final eventsSub = client.events.listen(events.add);
        final gapsSub = client.gaps.listen(gaps.add);
        await client.connect();
        await _until(() => events.length == 3);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(_gapTuples(gaps), isEmpty);
        await eventsSub.cancel();
        await gapsSub.cancel();
      } finally {
        await client.disconnect();
      }
    });

    test('a jump in per-session seq is reported as a SessionGap', () async {
      final client = EventsClient(base, reconnectDelay: _tick);
      try {
        framesFor = (n) => [
          _payload(seq: 1),
          _payload(seq: 2),
          _payload(seq: 4),
        ];
        holdFor = (n) => true;
        final gaps = <SessionGap>[];
        final gapsSub = client.gaps.listen(gaps.add);
        final eventsSub = client.events.listen((_) {});
        await client.connect();
        await _until(() => gaps.length == 1);

        expect(_gapTuples(gaps), [('ses_x', 2, 4)]);
        await eventsSub.cancel();
        await gapsSub.cancel();
      } finally {
        await client.disconnect();
      }
    });

    test(
      'a gap spanning a reconnect is still detected (seq map survives)',
      () async {
        final client = EventsClient(base, reconnectDelay: _tick);
        try {
          framesFor = (n) => n == 1
              ? [_payload(seq: 1), _payload(seq: 2)]
              : [_payload(seq: 5)];
          holdFor = (n) => n == 2;
          final events = <BridgeEvent>[];
          final gaps = <SessionGap>[];
          final eventsSub = client.events.listen(events.add);
          final gapsSub = client.gaps.listen(gaps.add);
          await client.connect();
          await _until(
            () => connections >= 2 && gaps.length == 1,
            message: 'expected a gap across the reconnect',
          );

          expect(_gapTuples(gaps), [('ses_x', 2, 5)]);
          expect(events.map((e) => e.durable?.seq), [1, 2, 5]);
          await eventsSub.cancel();
          await gapsSub.cancel();
        } finally {
          await client.disconnect();
        }
      },
    );

    test('no false gap across a reconnect when the per-session seq stays '
        'continuous', () async {
      final client = EventsClient(base, reconnectDelay: _tick);
      try {
        framesFor = (n) =>
            n == 1 ? [_payload(seq: 1), _payload(seq: 2)] : [_payload(seq: 3)];
        holdFor = (n) => n == 2;
        final events = <BridgeEvent>[];
        final gaps = <SessionGap>[];
        final eventsSub = client.events.listen(events.add);
        final gapsSub = client.gaps.listen(gaps.add);
        await client.connect();
        await _until(
          () => connections >= 2 && events.length == 3,
          message: 'expected all three events',
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(events.map((e) => e.durable?.seq), [
          1,
          2,
          3,
        ], reason: 'the client reconnects and keeps receiving');
        expect(_gapTuples(gaps), isEmpty);
        await eventsSub.cancel();
        await gapsSub.cancel();
      } finally {
        await client.disconnect();
      }
    });

    test(
      'bridge-native events between durable seqs do not break continuity',
      () async {
        final client = EventsClient(base, reconnectDelay: _tick);
        try {
          framesFor = (n) => [
            _payload(seq: 1),
            _native,
            _payload(seq: 2),
            _native,
          ];
          holdFor = (n) => true;
          final events = <BridgeEvent>[];
          final gaps = <SessionGap>[];
          final eventsSub = client.events.listen(events.add);
          final gapsSub = client.gaps.listen(gaps.add);
          await client.connect();
          await _until(() => events.length == 4);
          await Future<void>.delayed(const Duration(milliseconds: 50));

          expect(
            events.length,
            4,
            reason: 'no-durable events are side-effects only, still delivered',
          );
          expect(_gapTuples(gaps), isEmpty);
          await eventsSub.cancel();
          await gapsSub.cancel();
        } finally {
          await client.disconnect();
        }
      },
    );

    test('sessions are tracked independently', () async {
      final client = EventsClient(base, reconnectDelay: _tick);
      try {
        framesFor = (n) => [
          _payload(aggregateID: 'ses_a', seq: 1),
          _payload(aggregateID: 'ses_b', seq: 1),
          _payload(aggregateID: 'ses_a', seq: 3),
        ];
        holdFor = (n) => true;
        final gaps = <SessionGap>[];
        final events = <BridgeEvent>[];
        final eventsSub = client.events.listen(events.add);
        final gapsSub = client.gaps.listen(gaps.add);
        await client.connect();
        await _until(() => gaps.length == 1);

        expect(_gapTuples(gaps), [
          ('ses_a', 1, 3),
        ], reason: 'a gap in one session must not touch the others');
        await eventsSub.cancel();
        await gapsSub.cancel();
      } finally {
        await client.disconnect();
      }
    });

    test('a fresh aggregate establishes its baseline without a gap, whatever '
        'its first seq', () async {
      final client = EventsClient(base, reconnectDelay: _tick);
      try {
        framesFor = (n) => [_payload(aggregateID: 'ses_new', seq: 42)];
        holdFor = (n) => true;
        final events = <BridgeEvent>[];
        final gaps = <SessionGap>[];
        final eventsSub = client.events.listen(events.add);
        final gapsSub = client.gaps.listen(gaps.add);
        await client.connect();
        await _until(() => events.length == 1);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(_gapTuples(gaps), isEmpty);
        await eventsSub.cancel();
        await gapsSub.cancel();
      } finally {
        await client.disconnect();
      }
    });

    test('a failing bridge is retried, then the stream works', () async {
      final client = EventsClient(base, reconnectDelay: _tick);
      try {
        statusFor = (n) =>
            n == 1 ? HttpStatus.internalServerError : HttpStatus.ok;
        framesFor = (n) => n == 1 ? const <String>[] : [_payload(seq: 1)];
        holdFor = (n) => n == 2;
        final events = <BridgeEvent>[];
        final eventsSub = client.events.listen(events.add);
        await client.connect();
        await _until(
          () => connections >= 2 && events.length == 1,
          message: 'expected an event after the retry',
        );

        expect(events.first.durable?.seq, 1);
        await eventsSub.cancel();
      } finally {
        await client.disconnect();
      }
    });

    test('a malformed data frame is skipped, not fatal', () async {
      final client = EventsClient(base, reconnectDelay: _tick);
      try {
        framesFor = (n) => ['{not json', _payload(seq: 1)];
        holdFor = (n) => true;
        final events = <BridgeEvent>[];
        final eventsSub = client.events.listen(events.add);
        await client.connect();
        await _until(() => events.length == 1);

        expect(events.first.durable?.seq, 1);
        await eventsSub.cancel();
      } finally {
        await client.disconnect();
      }
    });

    test(
      'reconnect() opens a fresh connection and the seq map survives',
      () async {
        final client = EventsClient(base, reconnectDelay: _tick);
        try {
          // The live bridge holds every connection open. The connection opened
          // by reconnect() (#2) delivers seq 3, skipping seq 2 — the event
          // lost while the app was backgrounded.
          framesFor = (n) => n == 1 ? [_payload(seq: 1)] : [_payload(seq: 3)];
          holdFor = (n) => true;
          final events = <BridgeEvent>[];
          final gaps = <SessionGap>[];
          final eventsSub = client.events.listen(events.add);
          final gapsSub = client.gaps.listen(gaps.add);
          await client.connect();
          await _until(() => events.length == 1);
          expect(connections, 1);

          await client.reconnect();
          await _until(
            () => connections >= 2 && events.length == 2,
            message: 'expected a fresh connection that keeps receiving',
          );

          expect(events.map((e) => e.durable?.seq), [
            1,
            3,
          ], reason: 'the fresh connection keeps receiving');
          // seq 2 was missed across the drop, yet the gap is still reported:
          // the per-session seq map survived the reconnect.
          await _until(() => gaps.length == 1);
          expect(_gapTuples(gaps), [('ses_x', 1, 3)]);
          await eventsSub.cancel();
          await gapsSub.cancel();
        } finally {
          await client.disconnect();
        }
      },
    );

    test('reconnect() while stopped simply connects', () async {
      final client = EventsClient(base, reconnectDelay: _tick);
      try {
        framesFor = (n) => [_payload(seq: 1)];
        holdFor = (n) => true;
        final events = <BridgeEvent>[];
        final eventsSub = client.events.listen(events.add);

        await client.reconnect();
        await _until(() => events.length == 1);
        expect(events.first.durable?.seq, 1);
        await eventsSub.cancel();
      } finally {
        await client.disconnect();
      }
    });

    test('disconnect() stops receiving and does not reconnect', () async {
      final client = EventsClient(base, reconnectDelay: _tick);
      try {
        framesFor = (n) => [_payload(seq: 1)];
        holdFor = (n) =>
            true; // The connection stays open; nothing more arrives.
        final events = <BridgeEvent>[];
        final eventsSub = client.events.listen(events.add);
        await client.connect();
        await _until(() => events.length == 1);

        await client.disconnect();
        // Give a (misbehaving) client time to process more or reconnect.
        await Future<void>.delayed(const Duration(milliseconds: 150));

        expect(
          events,
          hasLength(1),
          reason: 'no events are processed after disconnect()',
        );
        expect(
          connections,
          1,
          reason: 'disconnect() must stop the loop, not start a reconnect',
        );
        await eventsSub.cancel();
      } finally {
        await client.disconnect();
      }
    });
  });
}

const _tick = Duration(milliseconds: 5);

List<(String, int, int)> _gapTuples(List<SessionGap> gaps) =>
    gaps.map((g) => (g.aggregateID, g.lastSeen, g.received)).toList();

String _payload({String aggregateID = 'ses_x', int seq = 1}) => jsonEncode({
  'id': 'evt_${aggregateID}_$seq',
  'created': seq,
  'type': 'session.updated',
  'data': {'n': seq},
  'durable': {'aggregateID': aggregateID, 'seq': seq, 'version': 1},
});

const _native =
    '{"id":"evt_native","created":0,"type":"session.closed",'
    '"data":{"id":"ses_x"}}';

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
