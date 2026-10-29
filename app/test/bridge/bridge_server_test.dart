import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/bridge_server.dart';
import 'package:opencodebridge/bridge/events/bridge_event.dart';
import 'package:opencodebridge/bridge/events/event_hub.dart';
import 'package:opencodebridge/bridge/events/opencode_event_service.dart';
import 'package:opencodebridge/bridge/health.dart';
import 'package:opencodebridge/bridge/sessions/backend.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';
import 'package:opencodebridge/bridge/sessions/session_store.dart';

void main() {
  group('BridgeServer', () {
    late BridgeServer server;
    late Uri base;

    setUp(() async {
      server = await BridgeServer.start(
        port: 0,
        health: () => const HealthReport(
          bridge: ComponentStatus.ok,
          opencode: ComponentStatus.unreachable,
          docker: ComponentStatus.ok,
        ),
      );
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
    });

    test('GET /api/health answers 200 with the report as JSON', () async {
      final client = HttpClient();
      try {
        final request = await client.getUrl(base.replace(path: 'api/health'));
        final response = await request.close();
        expect(response.statusCode, 200);
        final body = await response.transform(const Utf8Decoder()).join();
        expect(jsonDecode(body), {
          'bridge': 'ok',
          'opencode': 'unreachable',
          'docker': 'ok',
        });
      } finally {
        client.close(force: true);
      }
    });

    test('unknown paths are 404', () async {
      final client = HttpClient();
      try {
        final request = await client.getUrl(base.replace(path: 'api/nope'));
        final response = await request.close();
        expect(response.statusCode, 404);
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
    });

    test('POST /api/health is not the health route', () async {
      final client = HttpClient();
      try {
        final request = await client.postUrl(base.replace(path: 'api/health'));
        final response = await request.close();
        expect(response.statusCode, 404);
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
    });
  });

  group('BridgeServer defaults', () {
    test(
      'default report: bridge ok, opencode and docker not configured',
      () async {
        final server = await BridgeServer.start(port: 0);
        try {
          final client = HttpClient();
          final request = await client.getUrl(
            server.baseUri.replace(path: 'api/health'),
          );
          final response = await request.close();
          expect(response.statusCode, 200);
          final body = await response.transform(const Utf8Decoder()).join();
          client.close(force: true);
          expect(jsonDecode(body), {
            'bridge': 'ok',
            'opencode': 'not_configured',
            'docker': 'not_configured',
          });
        } finally {
          await server.stop();
        }
      },
    );

    test('listens on loopback only', () async {
      final server = await BridgeServer.start(port: 0);
      try {
        expect(server.baseUri.host, '127.0.0.1');
      } finally {
        await server.stop();
      }
    });

    test('default port is the fixed bridge port', () {
      expect(BridgeServer.defaultPort, 48201);
    });
  });

  group('BridgeServer sessions', () {
    late BridgeServer server;
    late Uri base;
    late Directory dir;
    late _FakeService service;
    late SessionStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp(
        'opencodebridge-srv-sessions',
      );
      service = _FakeService();
      store = await SessionStore.load(dir: dir);
      server = await BridgeServer.start(
        port: 0,
        sessions: SessionsBackend(service: service, store: store),
      );
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
      await dir.delete(recursive: true);
    });

    test('GET /api/sessions returns the merged rows, newest first', () async {
      // ses_two is persisted but not live -> app-launched-closed.
      store.add('ses_two');
      await store.save();

      final (status, body) = await _get(base, 'api/sessions');
      expect(status, 200);
      final rows = (jsonDecode(body) as List).cast<Map<String, Object?>>();
      expect(rows.map((r) => r['id']), ['ses_two', 'ses_three', 'ses_one']);
      expect(rows[0], {
        'id': 'ses_two',
        'title': 'two',
        'project': {'id': 'p1', 'name': 'proj-one'},
        'created': 300,
        'location': '/two',
        'active': false,
        'classification': 'app-launched-closed',
      });
      expect(rows[1]['active'], true);
      expect(rows[1]['classification'], 'external');
    });

    test(
      'DELETE /api/sessions/{id} answers 204 and removes the record',
      () async {
        store.add('ses_one');
        await store.save();

        final (status, body) = await _delete(base, 'api/sessions/ses_one');
        expect(status, 204);
        expect(body, isEmpty);
        expect(service.deleted, ['ses_one']);
        expect((await SessionStore.load(dir: dir)).has('ses_one'), isFalse);
      },
    );

    test('DELETE of a session unknown to the service is 404', () async {
      final (status, body) = await _delete(base, 'api/sessions/ses_missing');
      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
      expect(service.deleted, isEmpty);
    });

    test('DELETE failing on the service is 502 and keeps the record', () async {
      store.add('ses_boom');
      await store.save();

      final (status, body) = await _delete(base, 'api/sessions/ses_boom');
      expect(status, 502);
      expect(jsonDecode(body), {'error': 'opencode_unreachable'});
      expect((await SessionStore.load(dir: dir)).has('ses_boom'), isTrue);
    });

    test('GET /api/sessions is 502 when the service is down', () async {
      service.failList = true;
      final (status, body) = await _get(base, 'api/sessions');
      expect(status, 502);
      expect(jsonDecode(body), {'error': 'opencode_unreachable'});
    });

    test('DELETE /api/sessions without an id is 404', () async {
      final (status, _) = await _delete(base, 'api/sessions');
      expect(status, 404);
    });
  });

  group('BridgeServer events', () {
    late BridgeServer server;
    late Uri base;
    late Directory dir;
    late _FakeService service;
    late SessionStore store;
    late _FakeEventUpstream upstream;
    late EventHub hub;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('opencodebridge-srv-events');
      upstream = _FakeEventUpstream();
      hub = EventHub(service: upstream);
      service = _FakeService();
      store = await SessionStore.load(dir: dir);
      server = await BridgeServer.start(
        port: 0,
        sessions: SessionsBackend(service: service, store: store),
        events: hub,
      );
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
      await dir.delete(recursive: true);
    });

    test('GET /api/events streams opencode events verbatim as SSE', () async {
      final tap = await _SseTap.open(base);
      try {
        expect(tap.contentType, 'text/event-stream');
        await _until(
          () => tap.ready,
          message: 'expected the initial `: connected` comment',
        );
        upstream.add(OpencodeEvent(raw: _payload(1), type: 'session.updated'));
        await _until(
          () => tap.dataPayloads.length == 1,
          message: 'expected the verbatim data frame',
        );
        expect(tap.dataPayloads, [_payload(1)]);
        expect(
          tap.raw,
          isNot(contains('event:')),
          reason: 'the stream has data: frames only, no event: line',
        );
      } finally {
        await tap.close();
      }
    });

    test('a successful DELETE emits a bridge-native session.closed on the '
        'stream', () async {
      store.add('ses_one');
      await store.save();
      final tap = await _SseTap.open(base);
      try {
        await _until(() => tap.ready);
        final (status, _) = await _delete(base, 'api/sessions/ses_one');
        expect(status, 204);
        await _until(
          () => tap.dataPayloads.any((p) => p.contains('session.closed')),
          message: 'expected the session.closed frame',
        );
        final frame = jsonDecode(
          tap.dataPayloads.firstWhere((p) => p.contains('session.closed')),
        ) as Map<String, Object?>;
        expect(frame['type'], 'session.closed');
        expect(frame['data'], {'sessionID': 'ses_one'});
        expect(
          frame.containsKey('durable'),
          isFalse,
          reason: 'bridge-native events carry no durable seq',
        );
      } finally {
        await tap.close();
      }
    });

    test('a failed DELETE does not emit session.closed', () async {
      final tap = await _SseTap.open(base);
      try {
        await _until(() => tap.ready);
        final (status, _) = await _delete(base, 'api/sessions/ses_missing');
        expect(status, 404);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(tap.dataPayloads, isEmpty);
      } finally {
        await tap.close();
      }
    });

    test('two concurrent SSE connections receive identical frames', () async {
      final a = await _SseTap.open(base);
      final b = await _SseTap.open(base);
      try {
        await _until(() => a.ready && b.ready);
        upstream.add(OpencodeEvent(raw: _payload(1), type: 'session.updated'));
        await _until(() => a.dataPayloads.length == 1);
        hub.emit(
          bridgeEvent(
            type: BridgeEventType.sessionClosed,
            data: {'sessionID': 'ses_one'},
          ),
        );
        await _until(() => a.dataPayloads.length == 2);
        upstream.add(OpencodeEvent(raw: _payload(2), type: 'session.updated'));
        await _until(
          () => a.dataPayloads.length == 3 && b.dataPayloads.length == 3,
          message: 'expected both connections to receive all three frames',
        );
        expect(
          a.dataPayloads,
          b.dataPayloads,
          reason: 'a raw SSE client and the app must see identical frames',
        );
        expect(a.frames, b.frames);
      } finally {
        await a.close();
        await b.close();
      }
    });
  });
}

/// A scripted service for the sessions-endpoint tests.
class _FakeService implements OpencodeService {
  final List<String> deleted = [];
  var failList = false;

  @override
  Future<List<OpencodeSession>> listSessions() async {
    if (failList) throw const OpencodeServiceError(0, 'service down');
    return const [_one, _two, _three];
  }

  @override
  Future<Map<String, String>> projectNames() async => const {
    'p1': 'proj-one',
    'p2': 'proj-two',
  };

  @override
  Future<Set<String>> activeSessionIds() async => const {'ses_three'};

  @override
  Future<void> deleteSession(String id) async {
    switch (id) {
      case 'ses_missing':
        throw const OpencodeServiceError(404, 'not found');
      case 'ses_boom':
        throw const OpencodeServiceError(500, 'boom');
      default:
        deleted.add(id);
    }
  }
}

const _one = OpencodeSession(
  id: 'ses_one',
  title: 'one',
  projectId: 'p1',
  created: 100,
  location: '/one',
);
const _two = OpencodeSession(
  id: 'ses_two',
  title: 'two',
  projectId: 'p1',
  created: 300,
  location: '/two',
);
const _three = OpencodeSession(
  id: 'ses_three',
  title: 'three',
  projectId: 'p2',
  created: 200,
  location: '/three',
);

Future<(int, String)> _get(Uri base, String path) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(base.replace(path: path));
    final response = await request.close();
    final body = await response.transform(const Utf8Decoder()).join();
    return (response.statusCode, body);
  } finally {
    client.close(force: true);
  }
}

Future<(int, String)> _delete(Uri base, String path) async {
  final client = HttpClient();
  try {
    final request = await client.deleteUrl(base.replace(path: path));
    final response = await request.close();
    final body = await response.transform(const Utf8Decoder()).join();
    return (response.statusCode, body);
  } finally {
    client.close(force: true);
  }
}

/// A scripted upstream event service: one broadcast controller.
class _FakeEventUpstream implements OpencodeEventService {
  final StreamController<OpencodeEvent> controller =
      StreamController<OpencodeEvent>.broadcast();

  void add(OpencodeEvent event) => controller.add(event);

  @override
  Stream<OpencodeEvent> get events => controller.stream;

  @override
  Future<void> close() async {}
}

/// One raw SSE connection to `/api/events`, accumulating the raw bytes so a
/// test can assert on the exact frames (the seam a curl/EventsClient sees).
class _SseTap {
  _SseTap._(this._client, this._response, this._sub, this._buffer);

  static Future<_SseTap> open(Uri base) async {
    final client = HttpClient();
    final request = await client.getUrl(base.replace(path: 'api/events'));
    request.headers.set('accept', 'text/event-stream');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw StateError('events endpoint was not ok: ${response.statusCode}');
    }
    final buffer = StringBuffer();
    final sub = response.transform(const Utf8Decoder()).listen(buffer.write);
    return _SseTap._(client, response, sub, buffer);
  }

  final HttpClient _client;
  final HttpClientResponse _response;
  final StreamSubscription<String> _sub;
  final StringBuffer _buffer;

  String? get contentType => _response.headers.contentType?.toString();

  /// Everything received so far, verbatim.
  String get raw => _buffer.toString();

  /// The received frames: the stream split on the blank-line separator.
  List<String> get frames => _buffer
      .toString()
      .split('\n\n')
      .where((frame) => frame.isNotEmpty)
      .toList();

  /// True once the initial `: connected` comment (the header flush) arrived.
  bool get ready => frames.any((frame) => frame.startsWith(': connected'));

  /// The payloads of every `data:` frame, in order.
  List<String> get dataPayloads => frames
      .where((frame) => frame.startsWith('data: '))
      .map((frame) => frame.substring('data: '.length))
      .toList();

  Future<void> close() async {
    await _sub.cancel();
    _client.close(force: true);
  }
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
