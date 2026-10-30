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
import 'package:opencodebridge/bridge/sessions/paths.dart';
import 'package:opencodebridge/bridge/sessions/session_store.dart';
import 'package:opencodebridge/bridge/terminal/terminal_window.dart';
import 'package:opencodebridge/bridge/terminal/window_manager.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/model/session_detail.dart';

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

  group('BridgeServer structured view', () {
    late BridgeServer server;
    late Uri base;
    late Directory dir;
    late _FakeService service;
    late SessionStore store;

    const detail = SessionDetail(
      id: 'ses_one',
      title: 'one',
      location: '/one',
      cost: 0.75,
      tokens: TokenUsage(
        input: 10,
        output: 5,
        reasoning: 1,
        cacheRead: 2,
        cacheWrite: 0,
      ),
      outcome: 'succeeded',
    );
    const messages = [
      SessionMessage(role: 'user', text: 'hi'),
      SessionMessage(
        role: 'assistant',
        text: 'hello',
        tools: [ToolCall(name: 'bash', status: 'running')],
      ),
    ];
    const permissions = [
      PermissionRequest(id: 'per_1', action: 'shell', resources: ['ls']),
    ];

    setUp(() async {
      dir = await Directory.systemTemp.createTemp(
        'opencodebridge-srv-structured',
      );
      service = _FakeService(
        detail: detail,
        messages: messages,
        permissions: permissions,
      );
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

    test('GET /api/sessions/{id} returns the detail', () async {
      final (status, body) = await _get(base, 'api/sessions/ses_one');
      expect(status, 200);
      expect(jsonDecode(body), detail.toJson());
    });

    test('GET /api/sessions/{id} is 404 for an unknown session', () async {
      final (status, body) = await _get(base, 'api/sessions/ses_missing');
      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
    });

    test('GET /api/sessions/{id} is 502 when the service is down', () async {
      service.failDetail = true;
      final (status, body) = await _get(base, 'api/sessions/ses_one');
      expect(status, 502);
      expect(jsonDecode(body), {'error': 'opencode_unreachable'});
    });

    test('GET /api/sessions/{id}/messages returns the history', () async {
      final (status, body) = await _get(
        base,
        'api/sessions/ses_one/messages',
      );
      expect(status, 200);
      expect(jsonDecode(body), [
        for (final m in messages) m.toJson(),
      ]);
    });

    test('GET /api/sessions/{id}/messages is 404 for an unknown session',
        () async {
          final (status, body) = await _get(
            base,
            'api/sessions/ses_missing/messages',
          );
          expect(status, 404);
          expect(jsonDecode(body), {'error': 'not_found'});
        });

    test('GET /api/sessions/{id}/messages is 502 when the service is down',
        () async {
          service.failMessages = true;
          final (status, body) = await _get(
            base,
            'api/sessions/ses_one/messages',
          );
          expect(status, 502);
          expect(jsonDecode(body), {'error': 'opencode_unreachable'});
        });

    test('POST /api/sessions/{id}/messages sends the prompt and is 202',
        () async {
          final (status, body) = await _postRaw(
            base,
            'api/sessions/ses_one/messages',
            jsonEncode({'text': 'hello there'}),
          );
          expect(status, 202);
          expect(body, isEmpty);
          expect(service.prompts, [('ses_one', 'hello there')]);
        });

    test('POST /api/sessions/{id}/messages with an invalid body is 400',
        () async {
          for (final raw in <String>['', 'not json', '{}', '{"text": ""}']) {
            final (status, body) = await _postRaw(
              base,
              'api/sessions/ses_one/messages',
              raw,
            );
            expect(status, 400, reason: raw);
            expect(jsonDecode(body), {'error': 'invalid_body'});
          }
          expect(service.prompts, isEmpty);
        });

    test('POST /api/sessions/{id}/messages is 404 for an unknown session',
        () async {
          final (status, body) = await _postRaw(
            base,
            'api/sessions/ses_missing/messages',
            jsonEncode({'text': 'hello'}),
          );
          expect(status, 404);
          expect(jsonDecode(body), {'error': 'not_found'});
          expect(service.prompts, isEmpty);
        });

    test('POST /api/sessions/{id}/messages is 502 when the service is down',
        () async {
          service.failPrompt = true;
          final (status, body) = await _postRaw(
            base,
            'api/sessions/ses_one/messages',
            jsonEncode({'text': 'hello'}),
          );
          expect(status, 502);
          expect(jsonDecode(body), {'error': 'opencode_unreachable'});
        });

    test('GET /api/sessions/{id}/permissions returns the pending requests',
        () async {
          final (status, body) = await _get(
            base,
            'api/sessions/ses_one/permissions',
          );
          expect(status, 200);
          expect(jsonDecode(body), [
            for (final p in permissions) p.toJson(),
          ]);
        });

    test('GET /api/sessions/{id}/permissions is 404 for an unknown session',
        () async {
          final (status, body) = await _get(
            base,
            'api/sessions/ses_missing/permissions',
          );
          expect(status, 404);
          expect(jsonDecode(body), {'error': 'not_found'});
        });

    test(
      'GET /api/sessions/{id}/permissions is 502 when the service is down',
      () async {
        service.failPermissions = true;
        final (status, body) = await _get(
          base,
          'api/sessions/ses_one/permissions',
        );
        expect(status, 502);
        expect(jsonDecode(body), {'error': 'opencode_unreachable'});
      },
    );

    test(
      'POST .../permissions/{requestID}/reply replies and is 204',
      () async {
        final (status, body) = await _postRaw(
          base,
          'api/sessions/ses_one/permissions/per_1/reply',
          jsonEncode({'reply': 'always'}),
        );
        expect(status, 204);
        expect(body, isEmpty);
        expect(service.replies, [('ses_one', 'per_1', PermissionReply.always)]);
      },
    );

    test(
      'POST .../permissions/{requestID}/reply with an invalid decision is 400',
      () async {
        for (final raw in <String>[
          '',
          'not json',
          '{}',
          '{"reply": "maybe"}',
          '{"reply": ""}',
        ]) {
          final (status, body) = await _postRaw(
            base,
            'api/sessions/ses_one/permissions/per_1/reply',
            raw,
          );
          expect(status, 400, reason: raw);
          expect(jsonDecode(body), {'error': 'invalid_body'});
        }
        expect(service.replies, isEmpty);
      },
    );

    test(
      'POST .../permissions/{requestID}/reply is 404 for an unknown request',
      () async {
        final (status, body) = await _postRaw(
          base,
          'api/sessions/ses_one/permissions/per_missing/reply',
          jsonEncode({'reply': 'once'}),
        );
        expect(status, 404);
        expect(jsonDecode(body), {'error': 'not_found'});
        expect(service.replies, isEmpty);
      },
    );

    test(
      'POST .../permissions/{requestID}/reply is 502 when the service is down',
      () async {
        service.failReply = true;
        final (status, body) = await _postRaw(
          base,
          'api/sessions/ses_one/permissions/per_1/reply',
          jsonEncode({'reply': 'reject'}),
        );
        expect(status, 502);
        expect(jsonDecode(body), {'error': 'opencode_unreachable'});
      },
    );
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

  group('BridgeServer windows', () {
    late BridgeServer server;
    late Uri base;
    late Directory dir;
    late File app;
    late File emulator;
    late _FakeService service;
    late SessionStore store;
    late SessionsBackend backend;
    late TerminalWindowManager windows;
    late EventHub hub;
    late List<String> windowEvents;
    var launches = 0;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('opencodebridge-srv-windows');
      launches = 0;
      // A "binary" (the attach client) that runs long until killed.
      app = File('${dir.path}/fake-app');
      app.writeAsStringSync('#!/bin/sh\nsleep 300\n');
      _chmod(app.path, '755');
      // An emulator that runs the attach client (its argv after `--`) as a
      // child and waits for it, like gnome-terminal --wait.
      emulator = File('${dir.path}/gnome-terminal');
      emulator.writeAsStringSync(
        '#!/bin/sh\n'
        'echo "\$@" > ${dir.path}/args.txt\n'
        'while [ \$# -gt 0 ]; do\n'
        '  if [ "\$1" = "--" ]; then shift; break; fi\n'
        '  shift\n'
        'done\n'
        '"\$@" &\n'
        'echo \$! > ${dir.path}/pid.txt\n'
        'wait\n',
      );
      _chmod(emulator.path, '755');
      service = _FakeService();
      store = await SessionStore.load(dir: dir);
      backend = SessionsBackend(service: service, store: store);
      windowEvents = <String>[];
      hub = EventHub(service: _FakeEventUpstream());
      windows = TerminalWindowManager(
        liveSessionIds: backend.liveSessionIds,
        spawner: TerminalWindowSpawner(
          emulators: (String name) =>
              name == 'gnome-terminal' ? emulator.path : null,
          launch: (List<String> argv) {
            launches++;
            return Process.start(argv.first, argv.sublist(1));
          },
        ),
        terminalBinary: app.path,
        windowToken: () => 'tok_1',
        onEvent: windowEvents.add,
      );
      server = await BridgeServer.start(
        port: 0,
        sessions: backend,
        events: hub,
        windows: windows,
      );
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
      await dir.delete(recursive: true);
    });

    test('GET /api/projects returns the project list', () async {
      final (status, body) = await _get(base, 'api/projects');
      expect(status, 200);
      expect(jsonDecode(body), [
        {'id': 'p1', 'name': 'proj-one', 'canonical': '/proj/one'},
        {'id': 'p2', 'name': 'proj-two', 'canonical': '/proj/two'},
      ]);
    });

    test('GET /api/projects is 502 when the service is down', () async {
      service.failProjects = true;
      final (status, body) = await _get(base, 'api/projects');
      expect(status, 502);
      expect(jsonDecode(body), {'error': 'opencode_unreachable'});
    });

    test('GET /api/projects is 503 without a sessions backend', () async {
      if (_hostHasServiceDescriptor()) return;
      final bare = await BridgeServer.start(port: 0);
      try {
        final (status, body) = await _get(bare.baseUri, 'api/projects');
        expect(status, 503);
        expect(jsonDecode(body), {'error': 'opencode_unavailable'});
      } finally {
        await bare.stop();
      }
    });

    test('POST /api/sessions creates the session, persists the id, opens the '
        'window, and returns it live', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions',
        jsonEncode({'project': 'p1'}),
      );

      expect(status, 201);
      expect(jsonDecode(body), {
        'id': 'ses_created',
        'title': 'created',
        'project': {'id': 'p1', 'name': 'proj-one'},
        'created': 400,
        'location': '/created',
        'active': false,
        'classification': 'app-launched-live',
      });
      expect(launches, 1);
      expect(backend.liveSessionIds, contains('ses_created'));
      // The persistence "add id" write happened at launch.
      expect((await SessionStore.load(dir: dir)).has('ses_created'), isTrue);
    });

    test('POST /api/sessions with an invalid body is 400', () async {
      for (final raw in <String>['', 'not json', '{}', '{"project": ""}']) {
        final (status, body) = await _postRaw(base, 'api/sessions', raw);
        expect(status, 400, reason: raw);
        expect(jsonDecode(body), {'error': 'invalid_body'});
      }
      expect(launches, 0);
      expect(store.ids(), isEmpty);
    });

    test('POST /api/sessions for an unknown project is 404', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions',
        jsonEncode({'project': 'p_missing'}),
      );
      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
      expect(launches, 0);
      expect(store.ids(), isEmpty);
    });

    test('POST /api/sessions is 502 when the service is down', () async {
      service.failCreate = true;
      final (status, body) = await _postRaw(
        base,
        'api/sessions',
        jsonEncode({'project': 'p1'}),
      );
      expect(status, 502);
      expect(jsonDecode(body), {'error': 'opencode_unreachable'});
      expect(launches, 0);
      expect(store.ids(), isEmpty);
    });

    test('POST /api/sessions is 500 window_unavailable and leaves the session '
        'persisted and closed', () async {
      final spawnless = TerminalWindowManager(
        liveSessionIds: backend.liveSessionIds,
        spawner: TerminalWindowSpawner(emulators: (String name) => null),
        terminalBinary: app.path,
        windowToken: () => 'tok_1',
      );
      final other = await BridgeServer.start(
        port: 0,
        sessions: backend,
        windows: spawnless,
      );
      try {
        final (status, body) = await _postRaw(
          other.baseUri,
          'api/sessions',
          jsonEncode({'project': 'p1'}),
        );
        expect(status, 500);
        expect(jsonDecode(body), {'error': 'window_unavailable'});
      } finally {
        await other.stop();
      }
      // The session still exists: persisted and closed — it can be reopened.
      expect((await SessionStore.load(dir: dir)).has('ses_created'), isTrue);
      expect(backend.liveSessionIds, isEmpty);
    });

    test('POST /api/sessions/{id}/window reopens a closed app-launched '
        'session', () async {
      store.add('ses_two');
      await store.save();

      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_two/window',
        '',
      );

      expect(status, 204);
      expect(body, isEmpty);
      expect(launches, 1);
      expect(backend.liveSessionIds, contains('ses_two'));
      expect(windows.isLive('ses_two'), isTrue);
    });

    test('POST /api/sessions/{id}/window is 404 for a session that was not '
        'app-launched', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/window',
        '',
      );
      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
      expect(launches, 0);
    });

    test('POST /api/sessions/{id}/window is 404 for a session gone from the '
        'service', () async {
      store.add('ses_two');
      await store.save();
      service.removedFromService.add('ses_two');

      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_two/window',
        '',
      );
      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
      expect(launches, 0);
    });

    test(
      'POST /api/sessions/{id}/window is 502 when the service is down',
      () async {
        store.add('ses_two');
        await store.save();
        service.failList = true;

        final (status, body) = await _postRaw(
          base,
          'api/sessions/ses_two/window',
          '',
        );
        expect(status, 502);
        expect(jsonDecode(body), {'error': 'opencode_unreachable'});
        expect(launches, 0);
      },
    );

    test('POST /api/sessions/{id}/window is 500 window_unavailable when the '
        'window cannot be spawned', () async {
      store.add('ses_two');
      await store.save();
      final spawnless = TerminalWindowManager(
        liveSessionIds: backend.liveSessionIds,
        spawner: TerminalWindowSpawner(emulators: (String name) => null),
        terminalBinary: app.path,
        windowToken: () => 'tok_1',
      );
      final other = await BridgeServer.start(
        port: 0,
        sessions: backend,
        windows: spawnless,
      );
      try {
        final (status, body) = await _postRaw(
          other.baseUri,
          'api/sessions/ses_two/window',
          '',
        );
        expect(status, 500);
        expect(jsonDecode(body), {'error': 'window_unavailable'});
      } finally {
        await other.stop();
      }
      expect(backend.liveSessionIds, isEmpty);
    });

    test('a window the user closes unflips live, emits terminal.closed, and '
        'writes no persistence', () async {
      // A window that closes on its own (the user closed it).
      emulator.writeAsStringSync('#!/bin/sh\nexit 0\n');
      store.add('ses_one');
      await store.save();

      await windows.openFor('ses_one');
      await _until(
        () =>
            windowEvents.isNotEmpty &&
            !backend.liveSessionIds.contains('ses_one'),
      );

      expect(windowEvents, hasLength(1));
      final frame = jsonDecode(windowEvents.single) as Map<String, Object?>;
      expect(frame['type'], 'terminal.closed');
      expect(frame['data'], {'sessionID': 'ses_one'});
      // Window close is an in-memory transition only: the record stays.
      expect((await SessionStore.load(dir: dir)).has('ses_one'), isTrue);
    });

    test('DELETE on a live app-launched session closes the window first, '
        'deletes, and emits session.closed', () async {
      store.add('ses_one');
      await store.save();
      await windows.openFor('ses_one');
      await _waitForFile('${dir.path}/pid.txt');
      final pid = int.parse(
        File('${dir.path}/pid.txt').readAsStringSync().trim(),
      );
      expect(Process.runSync('kill', ['-0', '$pid']).exitCode, 0);

      final tap = await _SseTap.open(base);
      try {
        await _until(() => tap.ready);
        final (status, body) = await _delete(base, 'api/sessions/ses_one');
        expect(status, 204);
        expect(body, isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          Process.runSync('kill', ['-0', '$pid']).exitCode,
          isNot(0),
          reason: 'the window must be closed before the delete answers',
        );
        expect(service.deleted, ['ses_one']);
        expect(backend.liveSessionIds, isEmpty);
        expect(windowEvents, isEmpty);
        await _until(
          () => tap.dataPayloads.any((p) => p.contains('session.closed')),
          message: 'expected the session.closed frame',
        );
        final frame = jsonDecode(
          tap.dataPayloads.firstWhere((p) => p.contains('session.closed')),
        ) as Map<String, Object?>;
        expect(frame['type'], 'session.closed');
        expect(frame['data'], {'sessionID': 'ses_one'});
      } finally {
        await tap.close();
      }
    });
  });
}

/// A scripted service for the sessions-endpoint tests.
class _FakeService implements OpencodeService {
  _FakeService({
    this.detail,
    this.messages = const [],
    this.permissions = const [],
  });

  final List<String> deleted = [];
  final Set<String> removedFromService = {};
  var failList = false;
  var failProjects = false;
  var failCreate = false;
  var failDetail = false;
  var failMessages = false;
  var failPermissions = false;
  var failPrompt = false;
  var failReply = false;

  /// The session id [createSession] mints, by project id.
  final Map<String, OpencodeSession> created = {
    'p1': const OpencodeSession(
      id: 'ses_created',
      title: 'created',
      projectId: 'p1',
      created: 400,
      location: '/created',
    ),
  };

  final SessionDetail? detail;
  final List<SessionMessage> messages;
  final List<PermissionRequest> permissions;

  final List<(String, String)> prompts = [];

  final List<(String, String, PermissionReply)> replies = [];

  @override
  Future<List<OpencodeSession>> listSessions() async {
    if (failList) throw const OpencodeServiceError(0, 'service down');
    return [
      for (final session in const [_one, _two, _three])
        if (!removedFromService.contains(session.id)) session,
    ];
  }

  @override
  Future<Map<String, String>> projectNames() async => const {
    'p1': 'proj-one',
    'p2': 'proj-two',
  };

  @override
  Future<Set<String>> activeSessionIds() async => const {'ses_three'};

  @override
  Future<List<OpencodeProject>> projects() async {
    if (failProjects) throw const OpencodeServiceError(0, 'service down');
    return const [
      OpencodeProject(id: 'p1', name: 'proj-one', canonical: '/proj/one'),
      OpencodeProject(id: 'p2', name: 'proj-two', canonical: '/proj/two'),
    ];
  }

  @override
  Future<OpencodeSession> createSession(String projectId) async {
    if (failCreate) throw const OpencodeServiceError(0, 'service down');
    final session = created[projectId];
    if (session == null) {
      throw const OpencodeServiceError(404, 'no such project');
    }
    return session;
  }

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

  // The structured-view ops are keyed to the scripted session: any other id
  // is a 404, so the endpoint tests can exercise the unknown-session path.
  bool _known(String id) => detail != null && id == detail!.id;

  @override
  Future<SessionDetail> getDetail(String id) async {
    if (failDetail) throw const OpencodeServiceError(0, 'service down');
    final d = detail;
    if (d == null || id != d.id) {
      throw const OpencodeServiceError(404, 'not found');
    }
    return d;
  }

  @override
  Future<List<SessionMessage>> getMessages(String id) async {
    if (failMessages) throw const OpencodeServiceError(0, 'service down');
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    return messages;
  }

  @override
  Future<void> prompt(String id, String text) async {
    if (failPrompt) throw const OpencodeServiceError(0, 'service down');
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    prompts.add((id, text));
  }

  @override
  Future<List<PermissionRequest>> pendingPermissions(String id) async {
    if (failPermissions) throw const OpencodeServiceError(0, 'service down');
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    return permissions;
  }

  @override
  Future<void> replyPermission(
    String id,
    String requestID,
    PermissionReply reply,
  ) async {
    if (failReply) throw const OpencodeServiceError(0, 'service down');
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    if (!permissions.any((p) => p.id == requestID)) {
      throw const OpencodeServiceError(404, 'not found');
    }
    replies.add((id, requestID, reply));
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

Future<(int, String)> _postRaw(Uri base, String path, String body) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(base.replace(path: path));
    request.headers.contentType = ContentType.json;
    if (body.isNotEmpty) {
      request.write(body);
    }
    final response = await request.close();
    final raw = await response.transform(const Utf8Decoder()).join();
    return (response.statusCode, raw);
  } finally {
    client.close(force: true);
  }
}

/// The emulator script writes [path] once the attach client child is up;
/// the spawn that triggers it resolves before that, so poll for the file.
Future<void> _waitForFile(String path) async {
  await _until(() => File(path).existsSync());
}

void _chmod(String path, String mode) => Process.runSync('chmod', [mode, path]);

/// On a host that publishes a shared opencode service descriptor the bridge
/// default builds a real sessions backend, so the 503 path is not
/// observable there.
/// On a host that publishes a shared opencode service descriptor the bridge
/// default builds a real sessions backend, so the 503 path is not
/// observable there: the test marks itself skipped and returns true.
bool _hostHasServiceDescriptor() {
  if (File('${homeDirectory()}/.local/state/opencode/service.json')
      .existsSync()) {
    markTestSkipped(
      'the host publishes a shared opencode service descriptor, so the '
      'bridge default builds a real sessions backend',
    );
    return true;
  }
  return false;
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
