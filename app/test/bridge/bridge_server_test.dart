import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/bridge_server.dart';
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
