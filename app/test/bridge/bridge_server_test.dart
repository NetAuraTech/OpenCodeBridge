import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/afk/afk_component.dart';
import 'package:opencodebridge/bridge/afk/afk_settings.dart';
import 'package:opencodebridge/bridge/afk/afk_store.dart';
import 'package:opencodebridge/bridge/bridge_server.dart';
import 'package:opencodebridge/bridge/docker/docker_backend.dart';
import 'package:opencodebridge/bridge/events/bridge_event.dart';
import 'package:opencodebridge/bridge/events/event_hub.dart';
import 'package:opencodebridge/bridge/events/opencode_event_service.dart';
import 'package:opencodebridge/bridge/fs/fs_service.dart';
import 'package:opencodebridge/bridge/health.dart';
import 'package:opencodebridge/bridge/notify/fcm_sender.dart';
import 'package:opencodebridge/bridge/notify/firebase_service_account.dart';
import 'package:opencodebridge/bridge/notify/notify_service.dart';
import 'package:opencodebridge/bridge/sessions/backend.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';
import 'package:opencodebridge/bridge/sessions/order_store.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service_boot.dart';
import 'package:opencodebridge/bridge/sessions/paths.dart';
import 'package:opencodebridge/bridge/tunnel/cloudflared_binary.dart';
import 'package:opencodebridge/bridge/tunnel/cloudflared_config.dart';
import 'package:opencodebridge/bridge/tunnel/tunnel_supervisor.dart';
import 'package:opencodebridge/model/command.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/model/question.dart';
import 'package:opencodebridge/model/session_detail.dart';
import 'package:opencodebridge/notify/notify_kind.dart';

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

  group('BridgeServer host opencode boot (issue #153)', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('opencodebridge-boot-bridge');
    });

    tearDown(() async {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test(
      'a port conflict fails before the boot runs (no orphaned service)',
      () async {
        // A second server-mode instance: the port is already bound (the first
        // instance). The conflict must surface at the bridge port bind,
        // before any opencode service is spawned.
        final taken = await ServerSocket.bind('127.0.0.1', 0);
        try {
          final booter = _BootFake(dir).booter();
          await expectLater(
            () =>
                BridgeServer.start(port: taken.port, bootstrapOpencode: booter),
            throwsA(isA<SocketException>()),
          );
          expect(booter.result, isNull, reason: 'the boot never ran');
        } finally {
          await taken.close();
        }
      },
    );

    test('a failed boot degrades: health unreachable, sessions 503, '
        'the tunnel still starts', () async {
      if (_hostHasServiceDescriptor()) return;
      final boot = _BootFake(dir);
      boot.cli = null; // No opencode at all: the boot fails.
      // The tunnel still starts (it is independent of the opencode boot).
      // A real-looking supervisor whose child is faked: the binary is
      // seeded so `ensure()` needs no download, and the config is valid.
      final tunnelDir = await Directory('${dir.path}/cloudflared').create();
      await File('${tunnelDir.path}/cloudflared').writeAsString('the binary');
      await File('${tunnelDir.path}/version')
          .writeAsString(CloudflaredBinary.pinnedVersion);
      final configFile = File('${dir.path}/cloudflared.yml');
      await configFile.writeAsString(
        'tunnel: my-tunnel\n'
        'credentials-file: ${dir.path}/creds.json\n'
        'ingress:\n'
        '  - hostname: bridge.example.com\n'
        '    service: http://127.0.0.1:48201\n',
      );
      final tunnelSpawned = <List<String>>[];
      final tunnel = TunnelSupervisor(
        binary: CloudflaredBinary(dir: tunnelDir),
        configFile: CloudflaredConfigFile(file: configFile),
        spawner: (List<String> argv) async {
          tunnelSpawned.add(argv);
          return _NoopTunnelProcess();
        },
        // Nothing holds the metrics port (no real /proc probing in the test).
        portHolder: (int port) async => null,
      );
      final server = await BridgeServer.start(
        port: 0,
        bootstrapOpencode: boot.booter(),
        tunnel: tunnel,
      );
      try {
        final (status, body) = await _get(server.baseUri, 'api/health');
        expect(status, 200);
        expect(jsonDecode(body), {
          'bridge': 'ok',
          'opencode': 'unreachable',
          'docker': 'not_configured',
        });
        final (sessionsStatus, sessionsBody) = await _get(
          server.baseUri,
          'api/sessions',
        );
        expect(sessionsStatus, 503);
        expect(jsonDecode(sessionsBody), {'error': 'opencode_unavailable'});
        // The tunnel is unaffected by the failed boot.
        expect(tunnelSpawned, hasLength(1));
      } finally {
        await server.stop();
      }
    });

    test('a failed boot is visible on the log surface (opencode.boot on the '
        'unified stream)', () async {
      final upstream = _FakeEventUpstream();
      final hub = EventHub(service: upstream);
      final connection = _RecordingEventConnection();
      // The connection is live before start: the boot log is flushed onto
      // the unified stream as opencode.boot events (the app connects its
      // SSE during/after boot the same way).
      hub.add(connection);
      final boot = _BootFake(dir);
      boot.cli = null; // The boot fails (no opencode CLI).
      final server = await BridgeServer.start(
        port: 0,
        events: hub,
        bootstrapOpencode: boot.booter(),
      );
      try {
        expect(connection.payloads, isNotEmpty);
        final frame =
            jsonDecode(connection.payloads.single) as Map<String, Object?>;
        expect(frame['type'], BridgeEventType.opencodeBoot);
        final data = frame['data'] as Map<String, Object?>;
        expect(
          data['line'],
          contains('no opencode CLI'),
          reason: 'the failure reason is on the log surface',
        );
      } finally {
        await server.stop();
        await hub.close();
      }
    });

    test(
      'a successful boot reports opencode ok and the stop kills the child',
      () async {
        if (_hostHasServiceDescriptor()) return;
        final boot = _BootFake(dir);
        boot.cli = '/bin/opencode';
        boot.serviceAnswers = true;
        boot.emitReadyOnSpawn = true; // The child reports ready on spawn.
        final server = await BridgeServer.start(
          port: 0,
          bootstrapOpencode: boot.booter(),
        );
        try {
          final (status, body) = await _get(server.baseUri, 'api/health');
          expect(status, 200);
          expect(jsonDecode(body), {
            'bridge': 'ok',
            'opencode': 'ok',
            'docker': 'not_configured',
          });
        } finally {
          await server.stop();
        }
        expect(boot.childKilled, isTrue, reason: 'the app stops its child');
        expect(boot.marker.existsSync(), isFalse);
        expect(boot.descriptor.existsSync(), isFalse);
      },
    );

    test(
      'the bridge stop never touches an attached (case 3) service',
      () async {
        final boot = _BootFake(dir);
        boot.serviceAnswers = true; // The user's service answers.
        await boot.descriptor.writeAsString(
          '{"url":"http://127.0.0.1:4200","password":"u"}',
        );
        final server = await BridgeServer.start(
          port: 0,
          bootstrapOpencode: boot.booter(),
        );
        try {
          final (status, body) = await _get(server.baseUri, 'api/health');
          expect(status, 200);
          // Attached to the user's service: opencode is up.
          expect((jsonDecode(body) as Map<String, Object?>)['opencode'], 'ok');
        } finally {
          await server.stop();
        }
        expect(
          boot.signals,
          isEmpty,
          reason: 'the user’s service is never stopped',
        );
        expect(boot.argvs, isEmpty, reason: 'nothing was spawned');
        expect(
          boot.descriptor.existsSync(),
          isTrue,
          reason: 'the user’s descriptor is never deleted',
        );
      },
    );
  });

  group('BridgeServer sessions', () {
    late BridgeServer server;
    late Uri base;
    late _FakeService service;

    setUp(() async {
      service = _FakeService();
      server = await BridgeServer.start(
        port: 0,
        sessions: SessionsBackend(
          service: service,
          orderStore: _InMemoryOrderStore(),
        ),
      );
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
    });

    test('GET /api/sessions returns the rows, newest first', () async {
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
        'waiting': false,
        'pinned': false,
        'archived': false,
      });
      expect(rows[1]['active'], true);
      expect(rows[1]['waiting'], false);
      // The archived fact rides every row (issue #234): ses_three is
      // archived on the service, so its row carries the flag — and it is
      // still listed (the seam is faithful; the app filters its surface).
      expect(rows[1]['archived'], true);
    });

    test('GET /api/sessions rows carry the waiting fact per pending '
        'permission/question (issue #208)', () async {
      service.pendingPermissionsBySession['ses_two'] = [
        const PermissionRequest(id: 'per_2', action: 'shell', resources: []),
      ];
      // ses_one answers its permission lookup empty (so the question
      // lookup runs) and then its pending form.
      service.pendingPermissionsBySession['ses_one'] = const [];
      service.pendingQuestionsBySession['ses_one'] = [
        const QuestionForm(id: 'q_1', title: 'Questions', questions: []),
      ];

      final (status, body) = await _get(base, 'api/sessions');
      expect(status, 200);
      final rows = (jsonDecode(body) as List).cast<Map<String, Object?>>();

      final byId = {for (final row in rows) row['id'] as String: row};
      // A pending permission request -> waiting true.
      expect(byId['ses_two']!['waiting'], true);
      // A pending question form -> waiting true (and it is not active).
      expect(byId['ses_one']!['waiting'], true);
      expect(byId['ses_one']!['active'], false);
      // Nothing pending -> waiting false.
      expect(byId['ses_three']!['waiting'], false);
    });

    test('DELETE /api/sessions/{id} answers 204', () async {
      final (status, body) = await _delete(base, 'api/sessions/ses_one');
      expect(status, 204);
      expect(body, isEmpty);
      expect(service.deleted, ['ses_one']);
    });

    test('DELETE of a session unknown to the service is 404', () async {
      final (status, body) = await _delete(base, 'api/sessions/ses_missing');
      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
      expect(service.deleted, isEmpty);
    });

    test('DELETE failing on the service is 502', () async {
      final (status, body) = await _delete(base, 'api/sessions/ses_boom');
      expect(status, 502);
      expect(jsonDecode(body), {'error': 'opencode_unreachable'});
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
    late _FakeService service;

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
      service = _FakeService(
        detail: detail,
        messages: messages,
        permissions: permissions,
      );
      server = await BridgeServer.start(
        port: 0,
        sessions: SessionsBackend(
          service: service,
          orderStore: _InMemoryOrderStore(),
        ),
      );
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
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
      final (status, body) = await _get(base, 'api/sessions/ses_one/messages');
      expect(status, 200);
      expect(jsonDecode(body), [for (final m in messages) m.toJson()]);
    });

    test(
      'GET /api/sessions/{id}/messages/page returns a bounded page',
      () async {
        // Issue #124's paged read: the wrapper body, the service's page.
        final (status, body) = await _get(
          base,
          'api/sessions/ses_one/messages/page',
          query: 'limit=10',
        );
        expect(status, 200);
        final decoded = jsonDecode(body) as Map<String, Object?>;
        expect(decoded['messages'], [for (final m in messages) m.toJson()]);
        expect(decoded['cursor'], isNull);
        // The limit and cursor reach the service.
        expect(service.lastPageLimit, 10);
        expect(service.lastPageCursor, isNull);
      },
    );

    test('GET /api/sessions/{id}/messages/page forwards the cursor', () async {
      final (status, body) = await _get(
        base,
        'api/sessions/ses_one/messages/page',
        query: 'limit=5&cursor=5',
      );
      expect(status, 200);
      expect(jsonDecode(body), isA<Map<String, Object?>>());
      expect(service.lastPageLimit, 5);
      expect(service.lastPageCursor, '5');
    });

    test(
      'GET /api/sessions/{id}/messages/page is 404 for an unknown session',
      () async {
        final (status, body) = await _get(
          base,
          'api/sessions/ses_missing/messages/page',
        );
        expect(status, 404);
        expect(jsonDecode(body), {'error': 'not_found'});
      },
    );

    test(
      'GET /api/sessions/{id}/messages/page is 502 on a service failure',
      () async {
        service.failMessages = true;
        final (status, body) = await _get(
          base,
          'api/sessions/ses_one/messages/page',
        );
        expect(status, 502);
        expect(jsonDecode(body), {'error': 'opencode_unreachable'});
      },
    );

    test('GET /api/sessions/{id} carries the service Active fact', () async {
      // Issue #124: the backend folds the service's active list into the
      // detail the structured view reads. The fake's active list holds
      // ses_three, not the detail's ses_one.
      final (status, body) = await _get(base, 'api/sessions/ses_one');
      expect(status, 200);
      expect((jsonDecode(body) as Map<String, Object?>)['active'], false);
    });

    test(
      'GET /api/sessions/{id}/messages is 404 for an unknown session',
      () async {
        final (status, body) = await _get(
          base,
          'api/sessions/ses_missing/messages',
        );
        expect(status, 404);
        expect(jsonDecode(body), {'error': 'not_found'});
      },
    );

    test(
      'GET /api/sessions/{id}/messages is 502 when the service is down',
      () async {
        service.failMessages = true;
        final (status, body) = await _get(
          base,
          'api/sessions/ses_one/messages',
        );
        expect(status, 502);
        expect(jsonDecode(body), {'error': 'opencode_unreachable'});
      },
    );

    test(
      'POST /api/sessions/{id}/messages sends the prompt and is 202',
      () async {
        final (status, body) = await _postRaw(
          base,
          'api/sessions/ses_one/messages',
          jsonEncode({'text': 'hello there'}),
        );
        expect(status, 202);
        expect(body, isEmpty);
        expect(service.prompts, const [('ses_one', 'hello there', null, null)]);
      },
    );

    test('POST /api/sessions/{id}/messages forwards files and skills unchanged '
        'and is 202', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/messages',
        jsonEncode({
          'text': 'read the notes',
          'files': [
            {
              'uri': 'file:///proj/one/notes.md',
              'name': 'notes.md',
              'description': 'field notes',
              'source': {'path': '/proj/one/notes.md'},
              'mention': {'start': 0, 'end': 12},
            },
            // A clipboard image (issue #72): a data-URI entry, forwarded
            // unchanged to the service.
            {'uri': 'data:image/png;base64,iVBORw0KGgo=', 'name': 'clipboard'},
          ],
          'skills': [
            {'id': 'orbs'},
          ],
        }),
      );
      expect(status, 202);
      expect(body, isEmpty);
      final prompt = service.prompts.single;
      expect(prompt.$1, 'ses_one');
      expect(prompt.$2, 'read the notes');
      expect(prompt.$3, [
        {
          'uri': 'file:///proj/one/notes.md',
          'name': 'notes.md',
          'description': 'field notes',
          'source': {'path': '/proj/one/notes.md'},
          'mention': {'start': 0, 'end': 12},
        },
        {'uri': 'data:image/png;base64,iVBORw0KGgo=', 'name': 'clipboard'},
      ]);
      expect(prompt.$4, [
        {'id': 'orbs'},
      ]);
    });

    test('POST /api/sessions/{id}/messages with a malformed attachment array '
        'is 400', () async {
      for (final raw in <String>[
        jsonEncode({'text': 'hi', 'files': 'nope'}),
        jsonEncode({
          'text': 'hi',
          'files': [1],
        }),
        jsonEncode({'text': 'hi', 'skills': 'nope'}),
        jsonEncode({
          'text': 'hi',
          'skills': [1],
        }),
      ]) {
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

    test('POST /api/sessions/{id}/messages is 502 when the service rejects an '
        'attachment', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/messages',
        jsonEncode({
          'text': 'read it',
          'files': [
            {'uri': 'file:///proj/one/missing.txt', 'name': 'missing.txt'},
          ],
        }),
      );
      expect(status, 502);
      expect(jsonDecode(body), {'error': 'opencode_unreachable'});
      expect(service.prompts, isEmpty);
    });

    test(
      'POST /api/sessions/{id}/messages with an invalid body is 400',
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
      },
    );

    test(
      'POST /api/sessions/{id}/messages is 404 for an unknown session',
      () async {
        final (status, body) = await _postRaw(
          base,
          'api/sessions/ses_missing/messages',
          jsonEncode({'text': 'hello'}),
        );
        expect(status, 404);
        expect(jsonDecode(body), {'error': 'not_found'});
        expect(service.prompts, isEmpty);
      },
    );

    test(
      'POST /api/sessions/{id}/messages is 502 when the service is down',
      () async {
        service.failPrompt = true;
        final (status, body) = await _postRaw(
          base,
          'api/sessions/ses_one/messages',
          jsonEncode({'text': 'hello'}),
        );
        expect(status, 502);
        expect(jsonDecode(body), {'error': 'opencode_unreachable'});
      },
    );

    test(
      'GET /api/sessions/{id}/permissions returns the pending requests',
      () async {
        final (status, body) = await _get(
          base,
          'api/sessions/ses_one/permissions',
        );
        expect(status, 200);
        expect(jsonDecode(body), [for (final p in permissions) p.toJson()]);
      },
    );

    test(
      'GET /api/sessions/{id}/permissions is 404 for an unknown session',
      () async {
        final (status, body) = await _get(
          base,
          'api/sessions/ses_missing/permissions',
        );
        expect(status, 404);
        expect(jsonDecode(body), {'error': 'not_found'});
      },
    );

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

    test('POST .../permissions/{requestID}/reply replies and is 204', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/permissions/per_1/reply',
        jsonEncode({'reply': 'always'}),
      );
      expect(status, 204);
      expect(body, isEmpty);
      expect(service.replies, [('ses_one', 'per_1', PermissionReply.always)]);
    });

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

  group('BridgeServer question forms (issue #50)', () {
    late BridgeServer server;
    late Uri base;
    late _FakeService service;

    const detail = SessionDetail(
      id: 'ses_one',
      title: 'one',
      location: '/one',
      cost: 0.75,
      tokens: TokenUsage(
        input: 1,
        output: 1,
        reasoning: 0,
        cacheRead: 0,
        cacheWrite: 0,
      ),
      outcome: 'succeeded',
    );
    const questions = [
      QuestionForm(
        id: 'form_1',
        title: 'Questions',
        questions: [
          Question(
            header: 'Confirm',
            question: 'Proceed with the deployment?',
            multiple: false,
            custom: false,
            options: [
              QuestionOption(label: 'Yes'),
              QuestionOption(label: 'No'),
            ],
          ),
          Question(
            header: 'Pick',
            question: 'Choose some',
            multiple: true,
            custom: true,
            options: [
              QuestionOption(label: 'A'),
              QuestionOption(label: 'B'),
            ],
          ),
        ],
      ),
    ];

    setUp(() async {
      service = _FakeService(detail: detail, questions: questions);
      server = await BridgeServer.start(
        port: 0,
        sessions: SessionsBackend(
          service: service,
          orderStore: _InMemoryOrderStore(),
        ),
      );
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
    });

    test(
      'GET /api/sessions/{id}/questions returns the pending forms',
      () async {
        final (status, body) = await _get(
          base,
          'api/sessions/ses_one/questions',
        );
        expect(status, 200);
        expect(jsonDecode(body), [for (final f in questions) f.toJson()]);
      },
    );

    test(
      'GET /api/sessions/{id}/questions is 404 for an unknown session',
      () async {
        final (status, body) = await _get(
          base,
          'api/sessions/ses_missing/questions',
        );
        expect(status, 404);
        expect(jsonDecode(body), {'error': 'not_found'});
      },
    );

    test(
      'GET /api/sessions/{id}/questions is 502 when the service is down',
      () async {
        service.failQuestions = true;
        final (status, body) = await _get(
          base,
          'api/sessions/ses_one/questions',
        );
        expect(status, 502);
        expect(jsonDecode(body), {'error': 'opencode_unreachable'});
      },
    );

    test('POST .../questions/{formID}/answer answers and is 204', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/questions/form_1/answer',
        jsonEncode({
          'answers': [
            ['Yes'],
            ['A', 'extra'],
          ],
        }),
      );
      expect(status, 204);
      expect(body, isEmpty);
      _expectAnswered(service, 'form_1', [
        ['Yes'],
        ['A', 'extra'],
      ]);
    });

    test(
      'POST .../questions/{formID}/answer accepts a bare answers array',
      () async {
        final (status, body) = await _postRaw(
          base,
          'api/sessions/ses_one/questions/form_1/answer',
          jsonEncode([
            ['No'],
            ['B'],
          ]),
        );
        expect(status, 204);
        expect(body, isEmpty);
        _expectAnswered(service, 'form_1', [
          ['No'],
          ['B'],
        ]);
      },
    );

    test(
      'POST .../questions/{formID}/answer with an invalid body is 400',
      () async {
        for (final raw in <String>[
          '',
          'not json',
          '{}',
          '{"answers": "nope"}',
        ]) {
          final (status, body) = await _postRaw(
            base,
            'api/sessions/ses_one/questions/form_1/answer',
            raw,
          );
          expect(status, 400, reason: raw);
          expect(jsonDecode(body), {'error': 'invalid_body'});
        }
        expect(service.answered, isEmpty);
      },
    );

    test(
      'POST .../questions/{formID}/answer is 404 for an unknown form',
      () async {
        final (status, body) = await _postRaw(
          base,
          'api/sessions/ses_one/questions/form_missing/answer',
          jsonEncode({
            'answers': [
              ['Yes'],
            ],
          }),
        );
        expect(status, 404);
        expect(jsonDecode(body), {'error': 'not_found'});
        expect(service.answered, isEmpty);
      },
    );

    test(
      'POST .../questions/{formID}/answer is 502 when the service is down',
      () async {
        service.failAnswer = true;
        final (status, body) = await _postRaw(
          base,
          'api/sessions/ses_one/questions/form_1/answer',
          jsonEncode({
            'answers': [
              ['Yes'],
              ['A'],
            ],
          }),
        );
        expect(status, 502);
        expect(jsonDecode(body), {'error': 'opencode_unreachable'});
      },
    );

    test(
      'DELETE /api/sessions/{id}/questions/{formID} dismisses and is 204',
      () async {
        final (status, _) = await _delete(
          base,
          'api/sessions/ses_one/questions/form_1',
        );
        expect(status, 204);
        expect(service.questionDismissed, [('ses_one', 'form_1')]);
      },
    );

    test('DELETE .../questions/{formID} is 404 for an unknown form', () async {
      final (status, _) = await _delete(
        base,
        'api/sessions/ses_one/questions/form_missing',
      );
      expect(status, 404);
      expect(service.questionDismissed, isEmpty);
    });

    test(
      'DELETE .../questions/{formID} is 502 when the service is down',
      () async {
        service.failDismiss = true;
        final (status, _) = await _delete(
          base,
          'api/sessions/ses_one/questions/form_1',
        );
        expect(status, 502);
      },
    );
  });

  group('BridgeServer `/` command menu (issue #46)', () {
    late BridgeServer server;
    late Uri base;
    late _FakeService service;

    const detail = SessionDetail(
      id: 'ses_one',
      title: 'one',
      location: '/one',
      cost: 0,
      tokens: TokenUsage(
        input: 0,
        output: 0,
        reasoning: 0,
        cacheRead: 0,
        cacheWrite: 0,
      ),
      outcome: null,
    );

    setUp(() async {
      service = _FakeService(detail: detail);
      server = await BridgeServer.start(
        port: 0,
        sessions: SessionsBackend(
          service: service,
          orderStore: _InMemoryOrderStore(),
        ),
      );
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
    });

    test(
      'GET /api/sessions/{id}/commands lists the project commands',
      () async {
        final (status, body) = await _get(
          base,
          'api/sessions/ses_one/commands',
        );
        expect(status, 200);
        expect(jsonDecode(body), [
          {'name': 'deploy', 'description': 'ship it'},
        ]);
      },
    );

    test(
      'POST /api/sessions/{id}/commands/{name} runs the command and is 202',
      () async {
        final (status, body) = await _postRaw(
          base,
          'api/sessions/ses_one/commands/deploy',
          jsonEncode({'text': 'prod'}),
        );
        expect(status, 202);
        expect(body, isEmpty);
        expect(service.commandsRun, [('ses_one', 'deploy', 'prod')]);
      },
    );

    test(
      'POST .../commands/{name} with a body-less body runs with empty text',
      () async {
        final (status, _) = await _postRaw(
          base,
          'api/sessions/ses_one/commands/deploy',
          '',
        );
        expect(status, 202);
        expect(service.commandsRun, [('ses_one', 'deploy', '')]);
      },
    );

    test('POST .../commands/{name} is 404 for an unknown session', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_missing/commands/deploy',
        jsonEncode({'text': 'prod'}),
      );
      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
      expect(service.commandsRun, isEmpty);
    });

    test('GET /api/sessions/{id}/models lists the model registry', () async {
      final (status, body) = await _get(base, 'api/sessions/ses_one/models');
      expect(status, 200);
      expect(jsonDecode(body), [
        {
          'id': 'm1',
          'providerID': 'prov',
          'name': 'Model One',
          'variants': ['high'],
        },
      ]);
    });

    test('GET /api/sessions/{id}/model returns the current model', () async {
      final (status, body) = await _get(base, 'api/sessions/ses_one/model');
      expect(status, 200);
      expect(jsonDecode(body), {
        'model': {'id': 'm1', 'providerID': 'prov'},
      });
    });

    test('POST /api/sessions/{id}/models sets the model and is 204', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/models',
        jsonEncode({
          'model': {'id': 'm2', 'providerID': 'prov2', 'variant': 'high'},
        }),
      );
      expect(status, 204);
      expect(body, isEmpty);
      expect(service.modelsSet, [
        (
          'ses_one',
          const ModelRef(id: 'm2', providerId: 'prov2', variant: 'high'),
        ),
      ]);
    });

    test('POST .../models with no model in the body is 400', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/models',
        jsonEncode({}),
      );
      expect(status, 400);
      expect(jsonDecode(body), {'error': 'invalid_body'});
      expect(service.modelsSet, isEmpty);
    });

    test('GET /api/sessions/{id}/agents lists the agent registry', () async {
      final (status, body) = await _get(base, 'api/sessions/ses_one/agents');
      expect(status, 200);
      expect(jsonDecode(body), [
        {'id': 'a1', 'name': 'Agent One', 'description': 'does things'},
      ]);
    });

    test('POST /api/sessions/{id}/agents sets the agent and is 204', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/agents',
        jsonEncode({'agent': 'a2'}),
      );
      expect(status, 204);
      expect(body, isEmpty);
      expect(service.agentsSet, [('ses_one', 'a2')]);
    });

    test('POST .../agents with no agent in the body is 400', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/agents',
        jsonEncode({}),
      );
      expect(status, 400);
      expect(jsonDecode(body), {'error': 'invalid_body'});
      expect(service.agentsSet, isEmpty);
    });

    test('GET /api/sessions/{id}/skills lists the skill registry', () async {
      final (status, body) = await _get(base, 'api/sessions/ses_one/skills');
      expect(status, 200);
      expect(jsonDecode(body), [
        {'id': 'sk1', 'name': 'Skill One', 'description': 'a skill'},
      ]);
    });

    test(
      'POST /api/sessions/{id}/skills/{id} activates the skill and is 204',
      () async {
        final (status, body) = await _postRaw(
          base,
          'api/sessions/ses_one/skills/sk2',
          '',
        );
        expect(status, 204);
        expect(body, isEmpty);
        expect(service.skillsActivated, [('ses_one', 'sk2')]);
      },
    );

    test(
      'GET /api/sessions/{id}/files lists the session files per token',
      () async {
        final (status, body) = await _get(
          base,
          'api/sessions/ses_one/files',
          query: 'query=main',
        );
        expect(status, 200);
        expect(jsonDecode(body), ['src/main.dart', 'pubspec.yaml']);
        expect(service.filesSearched, [('ses_one', 'main')]);
      },
    );

    test(
      'GET /api/sessions/{id}/files is 404 for an unknown session',
      () async {
        final (status, _) = await _get(
          base,
          'api/sessions/ses_missing/files',
          query: 'query=main',
        );
        expect(status, 404);
        expect(service.filesSearched, isEmpty);
      },
    );

    test('POST .../compact, /undo, /redo each is 204', () async {
      for (final sub in const ['compact', 'undo', 'redo']) {
        final (status, body) = await _postRaw(
          base,
          'api/sessions/ses_one/$sub',
          '',
        );
        expect(status, 204, reason: sub);
        expect(body, isEmpty, reason: sub);
      }
      expect(service.compacted, ['ses_one']);
      expect(service.undos, ['ses_one']);
      expect(service.redos, ['ses_one']);
    });

    test('POST .../compact is 502 when the service is down', () async {
      service.failCompact = true;
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/compact',
        '',
      );
      expect(status, 502);
      expect(jsonDecode(body), {'error': 'opencode_unreachable'});
      expect(service.compacted, isEmpty);
    });

    test('POST .../compact is 404 for an unknown session', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_missing/compact',
        '',
      );
      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
    });

    test('POST .../cancel cancels the turn and is 204', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/cancel',
        '',
      );
      expect(status, 204);
      expect(body, isEmpty);
      expect(service.cancelled, ['ses_one']);
    });

    // The cancel's bridge-native `session.turn.cancelled` (issue #164): these
    // tests wire a live event hub so the tracker sees the stream and the SSE
    // tap can read the emitted frame. Each test owns its server (the command
    // group's setUp has no hub).
    Future<
      ({
        BridgeServer server,
        _SseTap tap,
        _FakeEventUpstream upstream,
        EventHub hub,
      })
    >
    cancelEventServer() async {
      final upstream = _FakeEventUpstream();
      final hub = EventHub(service: upstream);
      final server = await BridgeServer.start(
        port: 0,
        sessions: SessionsBackend(
          service: service,
          orderStore: _InMemoryOrderStore(),
        ),
        events: hub,
      );
      final tap = await _SseTap.open(server.baseUri);
      await _until(() => tap.ready);
      return (server: server, tap: tap, upstream: upstream, hub: hub);
    }

    Future<void> closeCancelEventServer(
      ({
        BridgeServer server,
        _SseTap tap,
        _FakeEventUpstream upstream,
        EventHub hub,
      })
      ctx,
    ) async {
      await ctx.tap.close();
      await ctx.server.stop();
      await ctx.hub.close();
    }

    test('POST .../cancel on a running turn emits session.turn.cancelled with '
        'the in-flight message id, no durable seq', () async {
      final ctx = await cancelEventServer();
      try {
        // The session is running a turn: the tracker opens it on the start
        // event and names the in-flight message off the stream.
        _emitExecStarted(ctx.upstream, 'ses_one');
        _emitStepStarted(ctx.upstream, 'ses_one', 'msg_inflight');
        // Wait until the hub has fanned the turn out to the tap: the tracker
        // (fanned out first, synchronously) has already processed it, so the
        // cancel reads a caught-up in-flight state.
        await _until(
          () => ctx.tap.dataPayloads.any(
            (p) => p.contains('"type":"session.step.started"'),
          ),
          message: 'expected the step frame on the stream',
        );

        final (status, body) = await _postRaw(
          ctx.server.baseUri,
          'api/sessions/ses_one/cancel',
          '',
        );
        expect(status, 204);
        expect(body, isEmpty);
        expect(service.cancelled, ['ses_one']);
        await _until(
          () => ctx.tap.dataPayloads.any((p) => p.contains('turn.cancelled')),
          message: 'expected the session.turn.cancelled frame',
        );
        final frame = jsonDecode(
          ctx.tap.dataPayloads.firstWhere((p) => p.contains('turn.cancelled')),
        ) as Map<String, Object?>;
        expect(frame['type'], 'session.turn.cancelled');
        expect(frame['data'], {
          'sessionID': 'ses_one',
          'messageID': 'msg_inflight',
        });
        expect(
          frame.containsKey('durable'),
          isFalse,
          reason: 'bridge-native events carry no durable seq',
        );
      } finally {
        await closeCancelEventServer(ctx);
      }
    });

    test('POST .../cancel on a running turn with no in-flight message names '
        'the session only', () async {
      final ctx = await cancelEventServer();
      try {
        // The turn is running but no message has been named yet. Wait for the
        // start frame to reach the tap so the tracker has processed it.
        _emitExecStarted(ctx.upstream, 'ses_one');
        await _until(
          () => ctx.tap.dataPayloads.any(
            (p) => p.contains('"type":"session.execution.started"'),
          ),
          message: 'expected the start frame on the stream',
        );

        final (status, _) = await _postRaw(
          ctx.server.baseUri,
          'api/sessions/ses_one/cancel',
          '',
        );
        expect(status, 204);
        await _until(
          () => ctx.tap.dataPayloads.any((p) => p.contains('turn.cancelled')),
        );
        final frame = jsonDecode(
          ctx.tap.dataPayloads.firstWhere((p) => p.contains('turn.cancelled')),
        ) as Map<String, Object?>;
        expect(frame['data'], {'sessionID': 'ses_one'});
      } finally {
        await closeCancelEventServer(ctx);
      }
    });

    test(
      'POST .../cancel on an idle session emits no turn.cancelled event',
      () async {
        final ctx = await cancelEventServer();
        try {
          // The session is idle: no turn running, no message in flight.
          final (status, _) = await _postRaw(
            ctx.server.baseUri,
            'api/sessions/ses_one/cancel',
            '',
          );
          expect(status, 204);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(
            ctx.tap.dataPayloads.where((p) => p.contains('turn.cancelled')),
            isEmpty,
            reason: 'an idle cancel must not emit a turn-cancelled event',
          );
        } finally {
          await closeCancelEventServer(ctx);
        }
      },
    );

    test('POST .../cancel does not emit turn.cancelled when the service is '
        'down', () async {
      final ctx = await cancelEventServer();
      try {
        _emitExecStarted(ctx.upstream, 'ses_one');
        service.failCancel = true;
        final (status, _) = await _postRaw(
          ctx.server.baseUri,
          'api/sessions/ses_one/cancel',
          '',
        );
        expect(status, 502);
        expect(service.cancelled, isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          ctx.tap.dataPayloads.where((p) => p.contains('turn.cancelled')),
          isEmpty,
          reason: 'a failed cancel carries nothing out',
        );
      } finally {
        await closeCancelEventServer(ctx);
      }
    });

    test('POST .../cancel is 502 when the service is down', () async {
      service.failCancel = true;
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/cancel',
        '',
      );
      expect(status, 502);
      expect(jsonDecode(body), {'error': 'opencode_unreachable'});
      expect(service.cancelled, isEmpty);
    });

    test('POST .../cancel is 502 for an unsupported service, then 204 once it '
        'restarts serving /interrupt (re-probe)', () async {
      // The service has no interrupt route: the cancel refuses with the
      // typed CancelUnsupportedError, which the bridge maps to 502
      // opencode_unreachable — never a 500 (issue #160).
      service.cancelUnsupported = true;
      var (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/cancel',
        '',
      );
      expect(status, 502);
      expect(jsonDecode(body), {'error': 'opencode_unreachable'});
      expect(service.cancelled, isEmpty);
      // The service restarts upgraded, now serving the interrupt route. The
      // remembered "no" is not final: the same cancel re-probes and lands.
      service.cancelUnsupported = false;
      (status, body) = await _postRaw(base, 'api/sessions/ses_one/cancel', '');
      expect(status, 204);
      expect(body, isEmpty);
      expect(service.cancelled, ['ses_one']);
    });

    test('POST .../cancel is 404 for an unknown session', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_missing/cancel',
        '',
      );
      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
    });

    test('POST .../cancel is 503 without a sessions backend', () async {
      if (_hostHasServiceDescriptor()) return;
      final bare = await BridgeServer.start(port: 0);
      try {
        final (status, body) = await _postRaw(
          bare.baseUri,
          'api/sessions/ses_one/cancel',
          '',
        );
        expect(status, 503);
        expect(jsonDecode(body), {'error': 'opencode_unavailable'});
      } finally {
        await bare.stop();
      }
    });

    test(
      'POST /api/sessions/{id}/fork returns the forked session id',
      () async {
        final (status, body) = await _postRaw(
          base,
          'api/sessions/ses_one/fork',
          '',
        );
        expect(status, 200);
        expect(jsonDecode(body), {'id': 'ses_forked'});
        expect(service.forks, ['ses_one']);
      },
    );

    test('POST .../rename renames the session and is 204', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/rename',
        jsonEncode({'title': 'renamed'}),
      );
      expect(status, 204);
      expect(body, isEmpty);
      expect(service.renamed, ['renamed']);
    });

    test('POST .../rename with an empty title is 400', () async {
      for (final raw in <String>[
        jsonEncode({}),
        jsonEncode({'title': ''}),
        jsonEncode({'title': '   '}),
      ]) {
        final (status, body) = await _postRaw(
          base,
          'api/sessions/ses_one/rename',
          raw,
        );
        expect(status, 400, reason: raw);
        expect(jsonDecode(body), {'error': 'invalid_body'});
      }
      expect(service.renamed, isEmpty);
    });

    test('POST .../move changes the working directory and is 204', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/move',
        jsonEncode({'directory': '/elsewhere'}),
      );
      expect(status, 204);
      expect(body, isEmpty);
      expect(service.moved, ['/elsewhere']);
    });

    test('POST .../move with an empty directory is 400', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/move',
        jsonEncode({}),
      );
      expect(status, 400);
      expect(jsonDecode(body), {'error': 'invalid_body'});
      expect(service.moved, isEmpty);
    });

    test('POST .../btw returns the side answer', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/btw',
        jsonEncode({'prompt': 'why?'}),
      );
      expect(status, 200);
      expect(jsonDecode(body), {'text': 'answer to why?'});
      expect(service.btws, [('ses_one', 'why?')]);
    });

    test('POST .../btw with an empty prompt is 400', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/btw',
        jsonEncode({}),
      );
      expect(status, 400);
      expect(jsonDecode(body), {'error': 'invalid_body'});
      expect(service.btws, isEmpty);
    });

    test('POST .../archive with {"archived":true} maps 1:1 to the service '
        'PATCH and is 204 (issue #234)', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/archive',
        jsonEncode({'archived': true}),
      );
      expect(status, 204);
      expect(body, isEmpty);
      expect(service.archived, [('ses_one', true)]);
    });

    test('POST .../archive with {"archived":false} unarchives '
        '(issue #234)', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/ses_one/archive',
        jsonEncode({'archived': false}),
      );
      expect(status, 204);
      expect(body, isEmpty);
      expect(service.archived, [('ses_one', false)]);
    });

    test('POST .../archive with a malformed or missing bool body is 400 '
        '(issue #234)', () async {
      for (final raw in <String>[
        jsonEncode({}),
        jsonEncode({'archived': 'true'}),
        jsonEncode({'archived': 1}),
        jsonEncode({'wrong': true}),
        '',
      ]) {
        final (status, body) = await _postRaw(
          base,
          'api/sessions/ses_one/archive',
          raw,
        );
        expect(status, 400, reason: raw);
        expect(jsonDecode(body), {'error': 'invalid_body'}, reason: raw);
      }
      expect(service.archived, isEmpty);
    });

    test(
      'POST .../archive for an unknown session is 404 (issue #234)',
      () async {
        final (status, body) = await _postRaw(
          base,
          'api/sessions/ses_missing/archive',
          jsonEncode({'archived': true}),
        );
        expect(status, 404);
        expect(jsonDecode(body), {'error': 'not_found'});
        expect(service.archived, isEmpty);
      },
    );

    test('GET .../export, /diff, /stats return the service payload', () async {
      for (final (sub, payload) in const [
        ('export', '{"info":"export"}'),
        ('diff', '{"diff":true}'),
        ('stats', '{"stats":true}'),
      ]) {
        final (status, body) = await _get(base, 'api/sessions/ses_one/$sub');
        expect(status, 200, reason: sub);
        expect(jsonDecode(body), payload, reason: sub);
      }
    });

    test('an unknown per-session command subpath is 404', () async {
      final (status, body) = await _get(base, 'api/sessions/ses_one/nosuch');
      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
    });

    test('the global command payloads are served', () async {
      for (final (path, payload) in const [
        ('api/usage', '{"usage":true}'),
        ('api/mcp', '{"mcps":true}'),
        ('api/plugins', '{"plugins":true}'),
        ('api/integrations', '{"integrations":true}'),
        ('api/status', '{"status":true}'),
      ]) {
        final (status, body) = await _get(base, path);
        expect(status, 200, reason: path);
        expect(jsonDecode(body), payload, reason: path);
      }
    });

    test('GET .../usage is 502 when the service is down', () async {
      service.failUsage = true;
      final (status, body) = await _get(base, 'api/usage');
      expect(status, 502);
      expect(jsonDecode(body), {'error': 'opencode_unreachable'});
    });

    test('POST /api/pair returns the pairing payload', () async {
      final (status, body) = await _postRaw(base, 'api/pair', '');
      expect(status, 200);
      expect(jsonDecode(body), '{"pair":true}');
    });

    test('POST /api/reload reloads and is 204', () async {
      final (status, body) = await _postRaw(base, 'api/reload', '');
      expect(status, 204);
      expect(body, isEmpty);
    });

    test(
      'GET /api/worktrees returns the payload with the session resolved',
      () async {
        final (status, body) = await _get(
          base,
          'api/worktrees',
          query: 'sessionID=ses_one',
        );
        expect(status, 200);
        expect(jsonDecode(body), '{"worktrees":true}');
      },
    );

    test('GET /api/worktrees without a session id is 400', () async {
      final (status, body) = await _get(base, 'api/worktrees');
      expect(status, 400);
      expect(jsonDecode(body), {'error': 'invalid_request'});
    });

    test(
      'POST /api/integrations/{id}/connect starts the flow and is 200',
      () async {
        final (status, body) = await _postRaw(
          base,
          'api/integrations/gitlab/connect',
          jsonEncode({'methodID': 'oauth1'}),
        );
        expect(status, 200);
        expect(jsonDecode(body), '{"connect":true}');
        expect(service.integrationsConnected, [('gitlab', 'oauth1')]);
      },
    );

    test('POST .../connect without a methodID is 400', () async {
      final (status, body) = await _postRaw(
        base,
        'api/integrations/gitlab/connect',
        jsonEncode({}),
      );
      expect(status, 400);
      expect(jsonDecode(body), {'error': 'invalid_body'});
      expect(service.integrationsConnected, isEmpty);
    });
  });

  group('BridgeServer session order (issue #237)', () {
    late BridgeServer server;
    late Uri base;
    late _FakeService service;
    late _FakeEventUpstream upstream;
    late EventHub hub;
    late Directory dir;
    late File file;

    setUp(() async {
      service = _FakeService();
      upstream = _FakeEventUpstream();
      hub = EventHub(service: upstream);
      dir = await Directory.systemTemp.createTemp('oc-order-route');
      file = File('${dir.path}/session-order.json');
      server = await BridgeServer.start(
        port: 0,
        sessions: SessionsBackend(
          service: service,
          orderStore: SessionOrderStore(file: file),
        ),
        events: hub,
      );
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
      await dir.delete(recursive: true);
    });

    test(
      'PATCH /api/sessions/{id}/order sets the position and is 204',
      () async {
        final (status, body) = await _patchRaw(
          base,
          'api/sessions/ses_one/order',
          jsonEncode({'position': 2}),
        );
        expect(status, 204);
        expect(body, isEmpty);

        final (listStatus, listBody) = await _get(base, 'api/sessions');
        expect(listStatus, 200);
        final rows = (jsonDecode(listBody) as List)
            .cast<Map<String, Object?>>();
        // The pinned block (position ascending) comes before the unpinned
        // newest-created block, and the row carries the pinned fact.
        expect(rows.map((r) => r['id']), ['ses_one', 'ses_two', 'ses_three']);
        expect(rows[0]['pinned'], true);
        expect(rows[1]['pinned'], false);
        expect(rows[2]['pinned'], false);
      },
    );

    test('a fractional position is accepted as a num', () async {
      final (status, _) = await _patchRaw(
        base,
        'api/sessions/ses_one/order',
        jsonEncode({'position': 1.5}),
      );
      expect(status, 204);
      expect(jsonDecode(file.readAsStringSync()), {
        'ses_one': 1.5,
      }, reason: 'the position is persisted as the num it was sent as');
    });

    test('position null clears the pin and is 204', () async {
      await _patchRaw(
        base,
        'api/sessions/ses_one/order',
        jsonEncode({'position': 0}),
      );

      final (status, body) = await _patchRaw(
        base,
        'api/sessions/ses_one/order',
        jsonEncode({'position': null}),
      );
      expect(status, 204);
      expect(body, isEmpty);

      final (listStatus, listBody) = await _get(base, 'api/sessions');
      expect(listStatus, 200);
      final rows = (jsonDecode(listBody) as List).cast<Map<String, Object?>>();
      // Back to the newest-created order among the unpinned.
      expect(rows.map((r) => r['id']), ['ses_two', 'ses_three', 'ses_one']);
      expect(rows.every((r) => r['pinned'] == false), isTrue);
    });

    test('a missing position field clears the pin and is 204', () async {
      await _patchRaw(
        base,
        'api/sessions/ses_one/order',
        jsonEncode({'position': 0}),
      );

      final (status, body) = await _patchRaw(
        base,
        'api/sessions/ses_one/order',
        jsonEncode({}),
      );
      expect(status, 204);
      expect(body, isEmpty);
      expect(file.existsSync(), isFalse);
    });

    test('an unknown session id is 404', () async {
      final (status, body) = await _patchRaw(
        base,
        'api/sessions/ses_missing/order',
        jsonEncode({'position': 0}),
      );
      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
      expect(file.existsSync(), isFalse);
    });

    // The light probe (issue #272): the pin write's existence check is one
    // identity read on the service, not a walk of the paginated session
    // list — the cost is asserted here, on the route.
    test('an absent id is 404 on the probe, with the paginated list never '
        'walked (issue #272)', () async {
      final (status, body) = await _patchRaw(
        base,
        'api/sessions/ses_missing/order',
        jsonEncode({'position': 0}),
      );
      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
      // The cost: the validation spent one probe and zero list walks.
      expect(service.probedIds, ['ses_missing']);
      expect(service.listSessionsCalls, 0);
    });

    test('a present id is 204, the pin is persisted, the event is emitted, and '
        'the paginated list is never walked (issue #272)', () async {
      final tap = await _SseTap.open(base);
      try {
        await _until(() => tap.ready);
        final (status, body) = await _patchRaw(
          base,
          'api/sessions/ses_one/order',
          jsonEncode({'position': 0}),
        );
        expect(status, 204);
        expect(body, isEmpty);
        // The pin is persisted on the store the backend was given.
        expect(jsonDecode(file.readAsStringSync()), {'ses_one': 0});
        // The event rides the route, as before.
        await _until(
          () => tap.dataPayloads.any((p) => p.contains('order.changed')),
          message: 'expected the session.order.changed frame',
        );
        final frame = jsonDecode(
          tap.dataPayloads.firstWhere((p) => p.contains('order.changed')),
        ) as Map<String, Object?>;
        expect(frame['type'], 'session.order.changed');
        expect(frame['data'], {'sessionID': 'ses_one', 'position': 0});
        // The cost: one probe, and the list (walked by a later GET
        // /api/sessions) was not spent on the validation.
        expect(service.probedIds, ['ses_one']);
        expect(service.listSessionsCalls, 0);
      } finally {
        await tap.close();
      }
    });

    for (final malformed in [
      jsonEncode({'position': 'two'}),
      jsonEncode({
        'position': {'n': 1},
      }),
      jsonEncode({
        'position': ['0'],
      }),
      jsonEncode(['not', 'an', 'object']),
      'not json at all',
    ]) {
      test('a malformed body ($malformed) is 400', () async {
        final (status, body) = await _patchRaw(
          base,
          'api/sessions/ses_one/order',
          malformed,
        );
        expect(status, 400);
        expect(jsonDecode(body), {'error': 'invalid_body'});
        expect(file.existsSync(), isFalse);
      });
    }

    test(
      'a successful set emits a bridge-native session.order.changed',
      () async {
        final tap = await _SseTap.open(base);
        try {
          await _until(() => tap.ready);
          final (status, _) = await _patchRaw(
            base,
            'api/sessions/ses_one/order',
            jsonEncode({'position': 0}),
          );
          expect(status, 204);
          await _until(
            () => tap.dataPayloads.any((p) => p.contains('order.changed')),
            message: 'expected the session.order.changed frame',
          );
          final frame = jsonDecode(
            tap.dataPayloads.firstWhere((p) => p.contains('order.changed')),
          ) as Map<String, Object?>;
          expect(frame['type'], 'session.order.changed');
          expect(frame['data'], {'sessionID': 'ses_one', 'position': 0});
          expect(
            frame.containsKey('durable'),
            isFalse,
            reason: 'bridge-native events carry no durable seq',
          );
        } finally {
          await tap.close();
        }
      },
    );

    test('a successful clear emits session.order.changed with a null '
        'position', () async {
      await _patchRaw(
        base,
        'api/sessions/ses_one/order',
        jsonEncode({'position': 0}),
      );
      final tap = await _SseTap.open(base);
      try {
        await _until(() => tap.ready);
        final (status, _) = await _patchRaw(
          base,
          'api/sessions/ses_one/order',
          jsonEncode({'position': null}),
        );
        expect(status, 204);
        await _until(
          () => tap.dataPayloads.any((p) => p.contains('order.changed')),
          message: 'expected the session.order.changed frame',
        );
        final frame = jsonDecode(
          tap.dataPayloads.firstWhere((p) => p.contains('order.changed')),
        ) as Map<String, Object?>;
        expect(frame['type'], 'session.order.changed');
        expect(frame['data'], {'sessionID': 'ses_one', 'position': null});
        expect(frame.containsKey('durable'), isFalse);
      } finally {
        await tap.close();
      }
    });

    test('a rejected write (404/400) emits no order event', () async {
      final tap = await _SseTap.open(base);
      try {
        await _until(() => tap.ready);
        await _patchRaw(
          base,
          'api/sessions/ses_missing/order',
          jsonEncode({'position': 0}),
        );
        await _patchRaw(
          base,
          'api/sessions/ses_one/order',
          jsonEncode({'position': 'two'}),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(tap.dataPayloads, isEmpty);
      } finally {
        await tap.close();
      }
    });

    test(
      'the order survives a bridge restart (the store is persisted)',
      () async {
        await _patchRaw(
          base,
          'api/sessions/ses_three/order',
          jsonEncode({'position': 0}),
        );
        await server.stop();

        // A new bridge over the same app-owned file: the position is still
        // there, and the home list reads it back in the pinned block.
        final restarted = await BridgeServer.start(
          port: 0,
          sessions: SessionsBackend(
            service: service,
            orderStore: SessionOrderStore(file: file),
          ),
          events: hub,
        );
        try {
          final (status, body) = await _get(restarted.baseUri, 'api/sessions');
          expect(status, 200);
          final rows = (jsonDecode(body) as List).cast<Map<String, Object?>>();
          expect(rows.map((r) => r['id']), ['ses_three', 'ses_two', 'ses_one']);
          expect(rows[0]['pinned'], true);
        } finally {
          await restarted.stop();
        }
      },
    );

    test('a home-list read does not drop the pin of a session it does not see '
        '(issue #292: no prune on the read)', () async {
      // Seed the store with a position for ses_one; the first home-list read
      // is one in which ses_one is not visible (its service has it, but a
      // degraded pass / a waking orb / the boot window hides it), and the
      // next read sees it again.
      await _patchRaw(
        base,
        'api/sessions/ses_one/order',
        jsonEncode({'position': 0}),
      );
      service.removedFromService.add('ses_one');

      final (invisibleStatus, invisibleBody) = await _get(base, 'api/sessions');
      expect(invisibleStatus, 200);
      final invisibleRows = (jsonDecode(invisibleBody) as List)
          .cast<Map<String, Object?>>();
      expect(invisibleRows.map((r) => r['id']), ['ses_two', 'ses_three']);

      // The position survived the read that did not see the session: the
      // store file still carries it (today this read prunes it away).
      expect(
        file.existsSync(),
        isTrue,
        reason: 'the invisible read must not drop the stored position',
      );
      expect(jsonDecode(file.readAsStringSync()), {'ses_one': 0});

      // The session is visible again: the pin is back in the pinned block,
      // first (position 0), with the pinned fact on the row.
      service.removedFromService.remove('ses_one');
      final (status, body) = await _get(base, 'api/sessions');
      expect(status, 200);
      final rows = (jsonDecode(body) as List).cast<Map<String, Object?>>();
      expect(rows.map((r) => r['id']), ['ses_one', 'ses_two', 'ses_three']);
      expect(rows[0]['pinned'], isTrue);
    });

    test('an orb session pinned while its orb is stopped keeps the position '
        'across a bridge restart (issue #292: the wake window read does not '
        'prune)', () async {
      // Pin the session while it is visible.
      await _patchRaw(
        base,
        'api/sessions/ses_one/order',
        jsonEncode({'position': 0}),
      );
      // The pinned session is not visible on the first read of the
      // restarted bridge (the orb is stopped / crashed: its sessions are
      // absent from the composite list until the startup recovery wakes it).
      service.removedFromService.add('ses_one');
      await server.stop();

      // A fresh bridge over the same app-owned file — a new backend with a
      // new store instance, as a restart makes.
      final restarted = await BridgeServer.start(
        port: 0,
        sessions: SessionsBackend(
          service: service,
          orderStore: SessionOrderStore(file: file),
        ),
        events: hub,
      );
      try {
        // The first read after the restart lands in the wake window: the
        // pinned session is not visible on it.
        final (status, body) = await _get(restarted.baseUri, 'api/sessions');
        expect(status, 200);
        final rows = (jsonDecode(body) as List).cast<Map<String, Object?>>();
        expect(rows.map((r) => r['id']), ['ses_two', 'ses_three']);

        // The position the wake-window read did not see is still there.
        expect(
          file.existsSync(),
          isTrue,
          reason: 'the wake-window read must not drop the stored position',
        );
        expect(jsonDecode(file.readAsStringSync()), {'ses_one': 0});

        // The recovery wakes the orb: the session is visible again and the
        // pin is back in the pinned block, first.
        service.removedFromService.remove('ses_one');
        final (status2, body2) = await _get(restarted.baseUri, 'api/sessions');
        expect(status2, 200);
        final rowsAgain = (jsonDecode(body2) as List)
            .cast<Map<String, Object?>>();
        expect(rowsAgain.map((r) => r['id']), [
          'ses_one',
          'ses_two',
          'ses_three',
        ]);
        expect(rowsAgain[0]['pinned'], isTrue);
      } finally {
        await restarted.stop();
      }
    });

    test('a DELETE of a pinned session cleans its order entry (the observed '
        'deletion, issue #292)', () async {
      await _patchRaw(
        base,
        'api/sessions/ses_one/order',
        jsonEncode({'position': 0}),
      );

      final (status, _) = await _delete(base, 'api/sessions/ses_one');
      expect(status, 204);

      // The observed deletion removes the entry (no orphan growth): the
      // store is empty, so the file is gone.
      await _until(
        () => !file.existsSync(),
        message: 'the order entry to be cleaned on the observed deletion',
      );
    });

    test('a session.deleted on the stream cleans the order entry (the observed '
        'deletion by event only, issue #292)', () async {
      await _patchRaw(
        base,
        'api/sessions/ses_one/order',
        jsonEncode({'position': 0}),
      );

      // A service-side deletion the bridge only observes through the stream
      // (durable, the aggregate id names the session): the listener clears
      // the entry.
      upstream.add(
        OpencodeEvent(
          raw: jsonEncode({
            'id': 'evt_deleted',
            'type': 'session.deleted',
            'data': const <String, Object?>{},
            'durable': {'aggregateID': 'ses_one', 'seq': 1, 'version': 1},
          }),
          type: 'session.deleted',
        ),
      );

      await _until(
        () => !file.existsSync(),
        message: 'the order entry to be cleaned on the session.deleted event',
      );
    });

    test('a bridge-native session.closed cleans the order entry (the observed '
        'deletion by event only, issue #292)', () async {
      await _patchRaw(
        base,
        'api/sessions/ses_one/order',
        jsonEncode({'position': 0}),
      );

      // The bridge-native close (the data.sessionID shape, no durable): the
      // listener clears the entry the same way.
      hub.emit(
        bridgeEvent(
          type: BridgeEventType.sessionClosed,
          data: {'sessionID': 'ses_one'},
        ),
      );

      await _until(
        () => !file.existsSync(),
        message: 'the order entry to be cleaned on the session.closed event',
      );
    });

    test('the route writes through the store the backend was constructed with '
        '(issue #271: one write path, the app-owned file)', () async {
      // The route is served by the bridge (no separate store injection): the
      // store the route writes through is the one the backend was
      // constructed with (issue #271). Construct the backend with a store
      // on the app-owned file — the default path — and assert the route's
      // pin lands in that file, proving the write stays with the store the
      // backend owns.
      final markerFile = File(
        '${Platform.environment['HOME'] ?? '/'}'
        '/.config/opencodebridge/session-order.json',
      );
      final saved = markerFile.existsSync()
          ? markerFile.readAsStringSync()
          : null;
      final bare = await BridgeServer.start(
        port: 0,
        sessions: SessionsBackend(
          service: service,
          orderStore: SessionOrderStore(file: markerFile),
        ),
        events: hub,
      );
      try {
        final (status, _) = await _patchRaw(
          bare.baseUri,
          'api/sessions/ses_one/order',
          jsonEncode({'position': 0}),
        );
        expect(status, 204);
        expect(markerFile.existsSync(), isTrue);
        expect(jsonDecode(markerFile.readAsStringSync()), {'ses_one': 0});
      } finally {
        await bare.stop();
        if (saved == null) {
          await markerFile.delete();
        } else {
          markerFile.writeAsStringSync(saved);
        }
      }
    });

    test(
      'a body-less PATCH is 400 (the body is checked before the session)',
      () async {
        final (status, body) = await _patchRaw(
          base,
          'api/sessions/ses_missing/order',
          '',
        );
        expect(status, 400);
        expect(jsonDecode(body), {'error': 'invalid_body'});
      },
    );
  });

  group('BridgeServer events', () {
    late BridgeServer server;
    late Uri base;
    late _FakeService service;
    late _FakeEventUpstream upstream;
    late EventHub hub;

    setUp(() async {
      upstream = _FakeEventUpstream();
      hub = EventHub(service: upstream);
      service = _FakeService();
      server = await BridgeServer.start(
        port: 0,
        sessions: SessionsBackend(
          service: service,
          orderStore: _InMemoryOrderStore(),
        ),
        events: hub,
      );
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
    });

    test('GET /api/events streams opencode events verbatim as SSE', () async {
      final tap = await _SseTap.open(base);
      try {
        expect(
          tap.contentType,
          'text/event-stream; charset=utf-8',
          reason: 'the client decodes the stream as UTF-8',
        );
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

    test(
      'a non-ASCII delta arrives as UTF-8 and leaves the connection live',
      () async {
        final tap = await _SseTap.open(base);
        try {
          await _until(
            () => tap.ready,
            message: 'expected the initial `: connected` comment',
          );
          // One character at each UTF-8 width: é is 2 bytes, — and 中 are
          // 2/3 bytes. Under the old Latin-1 response default, — and 中 made
          // the write throw and the whole connection was dropped.
          upstream.add(
            OpencodeEvent(
              raw:
                  '{"id":"evt_u","created":1,"type":"session.text.delta",'
                  '"data":{"delta":"naïve — 中文"}}',
              type: 'session.text.delta',
            ),
          );
          await _until(
            () => tap.dataPayloads.length == 1,
            message: 'expected the non-ASCII delta frame',
          );
          expect(
            tap.dataPayloads.single,
            contains('naïve — 中文'),
            reason: 'the delta must arrive as UTF-8, verbatim',
          );
          // The connection must still be in the fan-out: a follow-up (pure
          // ASCII) frame must reach the very same tap.
          upstream.add(
            OpencodeEvent(raw: _payload(2), type: 'session.updated'),
          );
          await _until(
            () => tap.dataPayloads.length == 2,
            message:
                'expected the frame after the non-ASCII one (the '
                'connection must still be live)',
          );
          expect(tap.dataPayloads[1], _payload(2));
        } finally {
          await tap.close();
        }
      },
    );

    test('a successful DELETE emits a bridge-native session.closed on the '
        'stream', () async {
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

  group('BridgeServer sessions (create & projects)', () {
    late BridgeServer server;
    late Uri base;
    late _FakeService service;
    late SessionsBackend backend;
    late EventHub hub;

    setUp(() async {
      service = _FakeService();
      backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );
      hub = EventHub(service: _FakeEventUpstream());
      server = await BridgeServer.start(
        port: 0,
        sessions: backend,
        events: hub,
      );
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
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

    test(
      'POST /api/sessions creates the session on the service and returns it',
      () async {
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
          'waiting': false,
          'pinned': false,
          'archived': false,
        });
      },
    );

    test('POST /api/sessions with an invalid body is 400', () async {
      for (final raw in <String>['', 'not json', '{}', '{"project": ""}']) {
        final (status, body) = await _postRaw(base, 'api/sessions', raw);
        expect(status, 400, reason: raw);
        expect(jsonDecode(body), {'error': 'invalid_body'});
      }
    });

    test('POST /api/sessions for an unknown project is 404', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions',
        jsonEncode({'project': 'p_missing'}),
      );
      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
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
    });
  });

  group('BridgeServer sessions (create by directory, issue #54)', () {
    late BridgeServer server;
    late Uri base;
    late _FakeService service;
    late SessionsBackend backend;
    late EventHub hub;
    late Directory dir;

    setUp(() async {
      service = _FakeService();
      backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );
      hub = EventHub(service: _FakeEventUpstream());
      dir = await Directory.systemTemp.createTemp('oc-create-in');
      server = await BridgeServer.start(
        port: 0,
        sessions: backend,
        events: hub,
      );
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
      await dir.delete(recursive: true);
    });

    test(
      'POST /api/sessions with a directory creates the session there',
      () async {
        final (status, body) = await _postRaw(
          base,
          'api/sessions',
          jsonEncode({'directory': dir.path}),
        );

        expect(status, 201);
        expect(jsonDecode(body), {
          'id': 'ses_created_dir',
          'title': 'created in ${dir.path}',
          'project': {'id': 'p_dir', 'name': 'p_dir'},
          'created': 400,
          'location': dir.path,
          'active': false,
          'waiting': false,
          'pinned': false,
          'archived': false,
        });
      },
    );

    test(
      'POST /api/sessions with both a project and a directory is 400',
      () async {
        final (status, body) = await _postRaw(
          base,
          'api/sessions',
          jsonEncode({'project': 'p1', 'directory': dir.path}),
        );
        expect(status, 400);
        expect(jsonDecode(body), {'error': 'invalid_body'});
      },
    );

    test('POST /api/sessions with a relative directory is 400', () async {
      for (final raw in <String>[
        jsonEncode({'directory': 'relative/path'}),
        jsonEncode({'directory': './relative'}),
      ]) {
        final (status, body) = await _postRaw(base, 'api/sessions', raw);
        expect(status, 400, reason: raw);
        expect(jsonDecode(body), {'error': 'invalid_body'});
      }
    });

    test('POST /api/sessions for a missing directory is 404', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions',
        jsonEncode({'directory': '/definitely/not/a/real/path-oc-create-in'}),
      );
      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
    });

    test(
      'POST /api/sessions with a directory is 502 when the service is down',
      () async {
        service.failCreateInDirectory = true;
        final (status, body) = await _postRaw(
          base,
          'api/sessions',
          jsonEncode({'directory': dir.path}),
        );
        expect(status, 502);
        expect(jsonDecode(body), {'error': 'opencode_unreachable'});
      },
    );
  });

  group('BridgeServer fs (issue #54)', () {
    late BridgeServer server;
    late Uri base;
    late _FakeFsService fs;

    setUp(() async {
      fs = _FakeFsService();
      server = await BridgeServer.start(port: 0, fs: fs);
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
    });

    test('GET /api/fs/drives returns the host drives', () async {
      fs.drivesResult = const ['/mnt/data', '/'];
      final (status, body) = await _get(base, 'api/fs/drives');
      expect(status, 200);
      expect(jsonDecode(body), ['/mnt/data', '/']);
    });

    test(
      'GET /api/fs/directories lists the subdirectories of the path',
      () async {
        fs.subdirectoriesResult = {
          '/tmp': const ['/tmp/b', '/tmp/a'],
        };
        final (status, body) = await _get(
          base,
          'api/fs/directories',
          query: 'path=/tmp',
        );
        expect(status, 200);
        expect(jsonDecode(body), ['/tmp/b', '/tmp/a']);
        expect(fs.subdirectoriesCalled, ['/tmp']);
      },
    );

    test(
      'GET /api/fs/directories without a path is 400 invalid_path',
      () async {
        final (status, body) = await _get(base, 'api/fs/directories');
        expect(status, 400);
        expect(jsonDecode(body), {'error': 'invalid_path'});
        expect(fs.subdirectoriesCalled, isEmpty);
      },
    );

    test(
      'GET /api/fs/directories with a relative path is 400 invalid_path',
      () async {
        final (status, body) = await _get(
          base,
          'api/fs/directories',
          query: 'path=tmp/one',
        );
        expect(status, 400);
        expect(jsonDecode(body), {'error': 'invalid_path'});
        expect(fs.subdirectoriesCalled, isEmpty);
      },
    );

    test('GET /api/fs/directories maps the service FsErrors', () async {
      fs.subdirectoriesError = const FsError(FsErrorKind.notFound, '/tmp');
      var (status, body) = await _get(
        base,
        'api/fs/directories',
        query: 'path=/tmp',
      );
      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});

      fs.subdirectoriesError = const FsError(
        FsErrorKind.permissionDenied,
        '/tmp',
      );
      (status, body) = await _get(
        base,
        'api/fs/directories',
        query: 'path=/tmp',
      );
      expect(status, 403);
      expect(jsonDecode(body), {'error': 'permission_denied'});

      fs.subdirectoriesError = const FsError(FsErrorKind.badPath, 'tmp');
      (status, body) = await _get(
        base,
        'api/fs/directories',
        query: 'path=/tmp',
      );
      expect(status, 400);
      expect(jsonDecode(body), {'error': 'invalid_path'});
    });

    test('POST /api/fs/directories creates the directory', () async {
      final (status, body) = await _postRaw(
        base,
        'api/fs/directories',
        jsonEncode({'path': '/tmp/new'}),
      );
      expect(status, 201);
      expect(fs.createdDirectories, ['/tmp/new']);
    });

    test(
      'POST /api/fs/directories without an absolute path is 400 invalid_path',
      () async {
        var (status, body) = await _postRaw(
          base,
          'api/fs/directories',
          jsonEncode({'path': 'tmp/new'}),
        );
        expect(status, 400);
        expect(jsonDecode(body), {'error': 'invalid_path'});
        expect(fs.createdDirectories, isEmpty);

        (status, body) = await _postRaw(
          base,
          'api/fs/directories',
          jsonEncode({'nope': true}),
        );
        expect(status, 400);
        expect(jsonDecode(body), {'error': 'invalid_path'});
        expect(fs.createdDirectories, isEmpty);
      },
    );

    test('POST /api/fs/directories maps the service FsErrors', () async {
      fs.createDirectoryError = const FsError(
        FsErrorKind.alreadyExists,
        '/tmp/new',
      );
      var (status, body) = await _postRaw(
        base,
        'api/fs/directories',
        jsonEncode({'path': '/tmp/new'}),
      );
      expect(status, 409);
      expect(jsonDecode(body), {'error': 'already_exists'});

      fs.createDirectoryError = const FsError(FsErrorKind.notFound, '/tmp');
      (status, body) = await _postRaw(
        base,
        'api/fs/directories',
        jsonEncode({'path': '/tmp/new'}),
      );
      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
    });
  });

  group('BridgeServer docker', () {
    late BridgeServer server;
    late Uri base;
    late _FakeDockerBridge fake;

    setUp(() async {
      fake = _FakeDockerBridge();
      server = await BridgeServer.start(
        port: 0,
        docker: fake.backend,
        // The log keep-alive is what surfaces a client disconnect (and kills
        // the CLI child); shorten it so that is observable in a test.
        dockerLogKeepAlive: const Duration(milliseconds: 100),
      );
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
    });

    test('GET /api/docker/containers returns the container rows', () async {
      fake.runResult = const DockerCliResult(
        exitCode: 0,
        stdout:
            '{"Names": "web", "Image": "nginx:latest", "State": "running", '
            '"RunningFor": "2 hours ago"}\n'
            '{"Names": "db", "Image": "postgres:16", "State": "exited", '
            '"RunningFor": ""}\n',
        stderr: '',
      );

      final (status, body) = await _get(base, 'api/docker/containers');
      expect(status, 200);
      expect(jsonDecode(body), [
        {
          'name': 'web',
          'image': 'nginx:latest',
          'state': 'running',
          'uptime': '2 hours ago',
        },
        {
          'name': 'db',
          'image': 'postgres:16',
          'state': 'exited',
          'uptime': null,
        },
      ]);
    });

    test(
      'GET /api/docker/containers is 502 when the docker CLI fails',
      () async {
        fake.runResult = const DockerCliResult(
          exitCode: 1,
          stdout: '',
          stderr: 'Cannot connect to the Docker daemon',
        );

        final (status, body) = await _get(base, 'api/docker/containers');
        expect(status, 502);
        expect(jsonDecode(body), {'error': 'docker_unreachable'});
      },
    );

    test(
      'GET /api/docker/containers is 503 without a docker CLI on the host',
      () async {
        if (_hostHasDockerCli()) return;
        final bare = await BridgeServer.start(port: 0);
        try {
          final (status, body) = await _get(
            bare.baseUri,
            'api/docker/containers',
          );
          expect(status, 503);
          expect(jsonDecode(body), {'error': 'docker_unavailable'});
        } finally {
          await bare.stop();
        }
      },
    );

    test('POST .../action takes the action by name and answers 200', () async {
      final (status, body) = await _postRaw(
        base,
        'api/docker/containers/web/action',
        '{"action": "start"}',
      );
      expect(status, 200);
      expect(jsonDecode(body), {'name': 'web'});
      expect(fake.runArgs, [
        const ['start', 'web'],
      ]);

      final (status2, _) = await _postRaw(
        base,
        'api/docker/containers/web/action',
        '{"action": "stop"}',
      );
      expect(status2, 200);
      expect(fake.runArgs, [
        const ['start', 'web'],
        const ['stop', 'web'],
      ]);
    });

    test('POST .../action of an unknown container is 404', () async {
      fake.runResult = const DockerCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Error response from daemon: No such container: web',
      );

      final (status, body) = await _postRaw(
        base,
        'api/docker/containers/web/action',
        '{"action": "stop"}',
      );
      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
    });

    test('POST .../action with a daemon failure is 502', () async {
      fake.runResult = const DockerCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Cannot connect to the Docker daemon',
      );

      final (status, body) = await _postRaw(
        base,
        'api/docker/containers/web/action',
        '{"action": "stop"}',
      );
      expect(status, 502);
      expect(jsonDecode(body), {'error': 'docker_unreachable'});
    });

    test('POST .../action with an invalid body is 400', () async {
      final (statusA, bodyA) = await _postRaw(
        base,
        'api/docker/containers/web/action',
        'not json',
      );
      expect(statusA, 400);
      expect(jsonDecode(bodyA), {'error': 'invalid_body'});

      final (statusB, bodyB) = await _postRaw(
        base,
        'api/docker/containers/web/action',
        '{"action": "explode"}',
      );
      expect(statusB, 400);
      expect(jsonDecode(bodyB), {'error': 'invalid_body'});
      expect(fake.runArgs, isEmpty);
    });

    test('GET .../logs streams the container lines as SSE', () async {
      final tap = await _LogsTap.open(base, 'web');
      try {
        expect(tap.status, HttpStatus.ok);
        expect(tap.contentType, 'text/event-stream; charset=utf-8');
        await _until(() => fake.spawnArgs.isNotEmpty);
        expect(fake.spawnArgs.single, ['logs', '--follow', 'web']);

        fake.logsLines.add('alpha');
        fake.logsLines.add('beta');
        await _until(() => tap.dataPayloads.length >= 2);
        expect(tap.dataPayloads, ['alpha', 'beta']);
      } finally {
        await tap.close();
      }
      // The CLI child lives for the connection: the disconnect kills it.
      await _until(() => fake.children.last.killed);
    });

    test('GET .../logs without follow ends after the existing log', () async {
      final pending = _get(base, 'api/docker/containers/web/logs');
      await _until(() => fake.spawnArgs.isNotEmpty);
      expect(fake.spawnArgs.single, ['logs', 'web']);
      fake.logsLines.add('old line');
      await fake.logsLines.close();

      final (status, body) = await pending;
      expect(status, HttpStatus.ok);
      expect(body, ': connected\n\ndata: old line\n\n');
    });

    test('GET .../logs of an unknown container is 404', () async {
      fake.runResult = const DockerCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Error: No such container: web',
      );

      final (status, body) = await _get(base, 'api/docker/containers/web/logs');
      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
      expect(fake.spawnArgs, isEmpty);
    });

    test('GET .../logs with a daemon failure is 502', () async {
      fake.runResult = const DockerCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Cannot connect to the Docker daemon',
      );

      final (status, body) = await _get(base, 'api/docker/containers/web/logs');
      expect(status, 502);
      expect(jsonDecode(body), {'error': 'docker_unreachable'});
    });

    test('the docker paths do not swallow other routes', () async {
      final (statusA, _) = await _get(base, 'api/docker/containers/web/action');
      expect(statusA, 404); // GET is not the action route

      final (statusB, _) = await _postRaw(
        base,
        'api/docker/containers/action',
        '{"action": "start"}',
      );
      expect(statusB, 404); // the name is required

      final (statusC, _) = await _get(
        base,
        'api/docker/containers/web/logs/extra',
      );
      expect(statusC, 404);
    });

    test('a container exit is re-emitted on GET /api/events', () async {
      final hub = EventHub(service: _FakeEventUpstream());
      final docker = _FakeDockerBridge(emit: hub.emit);
      final server = await BridgeServer.start(
        port: 0,
        events: hub,
        docker: docker.backend,
      );
      try {
        final tap = await _SseTap.open(server.baseUri);
        try {
          await _until(() => tap.ready);
          docker.eventsLines.add(
            jsonEncode({
              'Action': 'die',
              'Actor': {
                'Attributes': {'exitCode': '0', 'name': 'web'},
              },
            }),
          );
          await _until(
            () => tap.dataPayloads.any(
              (p) => p.contains('docker.container.stopped'),
            ),
            message: 'expected the docker.container.stopped frame',
          );
          final payload = tap.dataPayloads.firstWhere(
            (p) => p.contains('docker.container.stopped'),
          );
          final frame = jsonDecode(payload) as Map<String, Object?>;
          expect(frame['type'], 'docker.container.stopped');
          expect(frame['data'], {'name': 'web'});
        } finally {
          await tap.close();
        }
      } finally {
        await server.stop();
      }
    });
  });

  group('BridgeServer compose', () {
    late BridgeServer server;
    late Uri base;
    late _FakeDockerBridge fake;
    late Directory temp;
    late Directory repo;
    late Directory bare;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('oc-compose-route');
      // A fixed repo name so the derived compose project name is stable.
      repo = Directory('${temp.path}/composeproj');
      await repo.create();
      await File('${repo.path}/docker-compose.yml')
          .writeAsString('services: {}\n');
      // A project directory without a compose file (must be skipped).
      bare = Directory('${temp.path}/bare');
      await bare.create();
      fake = _FakeDockerBridge();
      server = await BridgeServer.start(
        port: 0,
        sessions: SessionsBackend(
          service: _FakeService(
            overrideProjects: [
              OpencodeProject(id: 'p1', name: 'proj-one', canonical: repo.path),
              OpencodeProject(id: 'p2', name: 'proj-two', canonical: bare.path),
            ],
          ),
          orderStore: _InMemoryOrderStore(),
        ),
        docker: fake.backend,
      );
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
      await temp.delete(recursive: true);
    });

    test('GET /api/docker/compose lists the compose projects', () async {
      fake.runResults
        ..add(
          const DockerCliResult(exitCode: 0, stdout: 'web\ndb\n', stderr: ''),
        )
        ..add(
          const DockerCliResult(
            exitCode: 0,
            stdout: '{"Service": "db", "Name": "composeproj-db-1", "Image": "postgres:16", "State": "exited"}\n',
            stderr: '',
          ),
        );

      final (status, body) = await _get(base, 'api/docker/compose');
      expect(status, 200);
      final projects = (jsonDecode(body) as List).cast<Map<String, Object?>>();
      expect(projects, [
        {
          'id': Uri.encodeComponent(repo.path),
          'project': 'composeproj',
          'path': repo.path,
          'composeFile': '${repo.path}/docker-compose.yml',
          'services': [
            {'name': 'web', 'state': null, 'image': null, 'container': null},
            {
              'name': 'db',
              'state': 'exited',
              'image': 'postgres:16',
              'container': 'composeproj-db-1',
            },
          ],
        },
      ]);
      expect(fake.runArgs, [
        const ['compose', 'config', '--services'],
        const ['compose', 'ps', '--all', '--format', 'json'],
      ]);
      expect(fake.runWorkingDirs, [repo.path, repo.path]);
    });

    test(
      'GET /api/docker/compose skips projects without a compose file',
      () async {
        fake.runResults
          ..add(const DockerCliResult(exitCode: 0, stdout: 'web\n', stderr: ''))
          ..add(const DockerCliResult(exitCode: 0, stdout: '', stderr: ''));

        final (status, body) = await _get(base, 'api/docker/compose');
        expect(status, 200);
        final projects = (jsonDecode(body) as List)
            .cast<Map<String, Object?>>();
        expect(projects, hasLength(1));
        expect(projects.single['path'], repo.path);
        // Only the directory with a compose file ran docker.
        expect(fake.runWorkingDirs, [repo.path, repo.path]);
      },
    );

    test('GET /api/docker/compose with a compose failure is 502', () async {
      fake.runResults.add(
        const DockerCliResult(
          exitCode: 1,
          stdout: '',
          stderr: 'cannot connect to the daemon',
        ),
      );

      final (status, body) = await _get(base, 'api/docker/compose');
      expect(status, 502);
      expect(jsonDecode(body), {'error': 'docker_unreachable'});
    });

    test(
      'GET /api/docker/compose is 503 without a docker CLI on the host',
      () async {
        if (_hostHasDockerCli()) return;
        final noDocker = await BridgeServer.start(
          port: 0,
          sessions: SessionsBackend(
            service: _FakeService(overrideProjects: const []),
            orderStore: _InMemoryOrderStore(),
          ),
        );
        try {
          final (status, body) = await _get(
            noDocker.baseUri,
            'api/docker/compose',
          );
          expect(status, 503);
          expect(jsonDecode(body), {'error': 'docker_unavailable'});
        } finally {
          await noDocker.stop();
        }
      },
    );

    test(
      'GET /api/docker/compose without opencode projects is empty',
      () async {
        final empty = await BridgeServer.start(
          port: 0,
          sessions: SessionsBackend(
            service: _FakeService(overrideProjects: const []),
            orderStore: _InMemoryOrderStore(),
          ),
          docker: fake.backend,
        );
        try {
          final (status, body) = await _get(
            empty.baseUri,
            'api/docker/compose',
          );
          expect(status, 200);
          expect(jsonDecode(body), []);
        } finally {
          await empty.stop();
        }
      },
    );

    String actionPath() =>
        'api/docker/compose/${Uri.encodeComponent(repo.path)}/action';

    test('POST .../compose/{id}/action up starts the whole project', () async {
      final (status, body) = await _postRaw(
        base,
        actionPath(),
        '{"action": "up"}',
      );
      expect(status, 200);
      expect(jsonDecode(body), {'path': repo.path});
      expect(fake.runArgs, [
        const ['compose', 'up', '-d'],
      ]);
      expect(fake.runWorkingDirs, [repo.path]);
    });

    test('POST .../compose/{id}/action stop stops one service', () async {
      final (status, body) = await _postRaw(
        base,
        actionPath(),
        '{"action": "stop", "service": "db"}',
      );
      expect(status, 200);
      expect(jsonDecode(body), {'path': repo.path, 'service': 'db'});
      expect(fake.runArgs, [
        const ['compose', 'stop', 'db'],
      ]);
      expect(fake.runWorkingDirs, [repo.path]);
    });

    test('POST .../compose/{id}/action of an unknown action is 400', () async {
      final (status, body) = await _postRaw(
        base,
        actionPath(),
        '{"action": "restart"}',
      );
      expect(status, 400);
      expect(jsonDecode(body), {'error': 'invalid_body'});
      expect(fake.runArgs, isEmpty);
    });

    test(
      'POST .../compose/{id}/action without a compose file is 404',
      () async {
        final (status, body) = await _postRaw(
          base,
          'api/docker/compose/${Uri.encodeComponent(bare.path)}/action',
          '{"action": "up"}',
        );
        expect(status, 404);
        expect(jsonDecode(body), {'error': 'not_found'});
      },
    );

    test(
      'POST .../compose/{id}/action with a compose failure is 502',
      () async {
        fake.runResult = const DockerCliResult(
          exitCode: 1,
          stdout: '',
          stderr: 'no such service',
        );

        final (status, body) = await _postRaw(
          base,
          actionPath(),
          '{"action": "stop"}',
        );
        expect(status, 502);
        expect(jsonDecode(body), {'error': 'docker_unreachable'});
      },
    );
  });

  group('BridgeServer push registration (issue #24)', () {
    late BridgeServer server;
    late Uri base;
    late Directory dir;
    late NotifyService notify;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('opencodebridge-srv-notify');
      notify = NotifyService(sender: _NotifyFakeSender());
      server = await BridgeServer.start(
        port: 0,
        sessions: SessionsBackend(
          service: _FakeService(),
          orderStore: _InMemoryOrderStore(),
        ),
        notify: notify,
      );
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
      await dir.delete(recursive: true);
    });

    test('a valid registration is 200 and lands in the service', () async {
      final (status, body) = await _postRaw(
        base,
        'api/notify/device-token',
        '{"token":"tok_1","events":["permissionAsked","turnEnded"]}',
      );
      expect(status, 200);
      expect(jsonDecode(body), <String, Object?>{});
      expect(notify.deviceCount, 1);
      expect(notify.enabledKinds('tok_1'), {
        NotifyKind.permissionAsked,
        NotifyKind.turnEnded,
      });
    });

    test(
      'an empty events list registers the token with no push enabled',
      () async {
        final (status, _) = await _postRaw(
          base,
          'api/notify/device-token',
          '{"token":"tok_2","events":[]}',
        );
        expect(status, 200);
        expect(notify.enabledKinds('tok_2'), isEmpty);
      },
    );

    test('a re-registration with the same token replaces its events', () async {
      await _postRaw(
        base,
        'api/notify/device-token',
        '{"token":"tok_1","events":["turnEnded"]}',
      );
      await _postRaw(
        base,
        'api/notify/device-token',
        '{"token":"tok_1","events":[]}',
      );
      expect(notify.deviceCount, 1);
      expect(notify.enabledKinds('tok_1'), isEmpty);
    });

    test('a malformed body is 400 and registers nothing', () async {
      for (final body in const [
        'not json',
        '{}',
        '{"token":"","events":[]}',
        '{"token":"tok","events":["nope"]}',
        '{"token":"tok","events":"turnEnded"}',
      ]) {
        final (status, response) = await _postRaw(
          base,
          'api/notify/device-token',
          body,
        );
        expect(status, 400, reason: body);
        expect(jsonDecode(response), {'error': 'invalid_body'});
      }
      expect(notify.deviceCount, 0);
    });

    test(
      'without a service account the endpoint is 503 notify_unconfigured',
      () async {
        // Pin the credential to a missing path so the 503 path is
        // deterministic whatever account this machine holds (a dev host has
        // its own).
        final unconfigured = await BridgeServer.start(
          port: 0,
          sessions: SessionsBackend(
            service: _FakeService(),
            orderStore: _InMemoryOrderStore(),
          ),
          notifyCredential: '${dir.path}/no-such-account.json',
        );
        try {
          final (status, body) = await _postRaw(
            unconfigured.baseUri,
            'api/notify/device-token',
            '{"token":"tok_1","events":[]}',
          );
          expect(status, 503);
          expect(jsonDecode(body), {'error': 'notify_unconfigured'});
        } finally {
          await unconfigured.stop();
        }
      },
    );
  });

  group('BridgeServer push reload (issue #24)', () {
    late Directory dir;
    late String accountPath;

    /// The reload tests exercise the endpoint status and the disk re-read,
    /// not delivery: a no-op sender keeps them off the Admin-SDK singleton
    /// (its `FirebaseApp` is process-global and would collide across
    /// servers) and off the network.
    Future<FcmSender> fakeSender(FirebaseServiceAccount account) async =>
        _NotifyFakeSender();

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('opencodebridge-srv-reload');
      accountPath = '${dir.path}/service-account.json';
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test(
      'reloadNotify takes a saved service account live (503 → 200)',
      () async {
        final server = await BridgeServer.start(
          port: 0,
          sessions: SessionsBackend(
            service: _FakeService(),
            orderStore: _InMemoryOrderStore(),
          ),
          notifyCredential: accountPath,
          notifySenderFactory: fakeSender,
        );
        try {
          var (status, body) = await _postRaw(
            server.baseUri,
            'api/notify/device-token',
            '{"token":"tok_1","events":[]}',
          );
          expect(status, 503);
          expect(jsonDecode(body), {'error': 'notify_unconfigured'});

          FirebaseServiceAccount.install(kAccountJson, path: accountPath);
          await server.reloadNotify(
            path: accountPath,
            senderFactory: fakeSender,
          );

          (status, body) = await _postRaw(
            server.baseUri,
            'api/notify/device-token',
            '{"token":"tok_1","events":["turnEnded"]}',
          );
          expect(status, 200);
        } finally {
          await server.stop();
        }
      },
    );

    test(
      'reloadNotify reports unconfigured again when the file is gone',
      () async {
        FirebaseServiceAccount.install(kAccountJson, path: accountPath);
        final server = await BridgeServer.start(
          port: 0,
          sessions: SessionsBackend(
            service: _FakeService(),
            orderStore: _InMemoryOrderStore(),
          ),
          notifyCredential: accountPath,
          notifySenderFactory: fakeSender,
        );
        try {
          var (status, body) = await _postRaw(
            server.baseUri,
            'api/notify/device-token',
            '{"token":"tok_1","events":[]}',
          );
          expect(status, 200);

          await File(accountPath).delete();
          await server.reloadNotify(
            path: accountPath,
            senderFactory: fakeSender,
          );

          (status, body) = await _postRaw(
            server.baseUri,
            'api/notify/device-token',
            '{"token":"tok_1","events":[]}',
          );
          expect(status, 503);
          expect(jsonDecode(body), {'error': 'notify_unconfigured'});
        } finally {
          await server.stop();
        }
      },
    );
  });

  group('BridgeServer push label (issue #288)', () {
    late BridgeServer server;
    late Uri base;
    late _FakeService service;
    late _FakeEventUpstream upstream;
    late EventHub hub;
    late _NotifyFakeSender sender;
    late Directory dir;

    /// The push-label tests drive the **real** bridge wiring: the bridge
    /// builds its own [NotifyService] and [PushDispatcher] through
    /// [_defaultNotify] (whose default label closure is under test) and
    /// attaches the dispatcher to the injected [hub]; we tap that hub to
    /// emit. The device registers through the public endpoint (the
    /// dispatcher's [NotifyService] is internal), and a no-op sender keeps
    /// the tests off the Admin-SDK singleton and off the network.
    Future<FcmSender> fakeSender(FirebaseServiceAccount account) async =>
        sender;

    /// Emits a `session.turn.cancelled` push for [sessionID] through the
    /// bridge's hub and waits for the recording sender to receive it.
    Future<void> emitPush(String sessionID) async {
      hub.emit(
        bridgeEvent(
          type: BridgeEventType.turnCancelled,
          data: {'sessionID': sessionID},
        ),
      );
      await _until(
        () => sender.bodies.isNotEmpty,
        message: 'the push to arrive',
      );
    }

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('opencodebridge-push-label');
      final accountPath = '${dir.path}/service-account.json';
      FirebaseServiceAccount.install(kAccountJson, path: accountPath);
      service = _FakeService();
      upstream = _FakeEventUpstream();
      hub = EventHub(service: upstream);
      sender = _NotifyFakeSender();
      server = await BridgeServer.start(
        port: 0,
        sessions: SessionsBackend(
          service: service,
          orderStore: SessionOrderStore(
            file: File('${dir.path}/session-order.json'),
          ),
        ),
        events: hub,
        notifyCredential: accountPath,
        notifySenderFactory: fakeSender,
      );
      base = server.baseUri;
      // The dispatcher's [NotifyService] is built by the bridge (not exposed),
      // so the device registers through the public endpoint.
      final (status, _) = await _postRaw(
        base,
        'api/notify/device-token',
        '{"token":"tok_1","events":["turnEnded"]}',
      );
      expect(status, 200);
    });

    tearDown(() async {
      await server.stop();
      await dir.delete(recursive: true);
    });

    test('the push label is the probed title, not a home-list read', () async {
      await emitPush('ses_one');
      // The body is the title the single-session identity read returned.
      expect(sender.bodies.single, 'one');
      // The targeted read was used ...
      expect(service.probedIds, contains('ses_one'));
      // ... and no home-list read ran (no per-session waiting lookups).
      expect(service.listSessionsCalls, 0);
    });

    test('a missing session degrades the push label to the id (no crash, no '
        'empty push)', () async {
      // The probe 404s: the id is the body fallback, and the push still
      // goes out (the labeler only ever returns a non-empty string).
      await emitPush('ses_gone');
      expect(sender.bodies.single, 'ses_gone');
    });
  });

  group('BridgeServer AFK run push wiring (spec #376, T5)', () {
    // The AFK run's two "look now" events (spec #376, T5) ride the bridge's
    // real event hub and are mapped to the `afkRun` push kind by the bridge's
    // real [PushDispatcher] — through the real [_defaultNotify] wiring, whose
    // AFK-session resolver reads the bridge's **stored** AFK session (not the
    // run's issue, which has no session). The push deep-links: the PR push to
    // the PR's GitHub URL (external), the failure push to the AFK session
    // (in-app). A device registered for `afkRun` receives them; the PR push
    // is high priority. The dispatcher itself (titles, bodies, the per-kind
    // toggle) is covered by the push-dispatcher tests; this closes the
    // bridge-wiring loop the dispatcher test cannot (its resolver is a stub).

    late BridgeServer server;
    late Uri base;
    late _FakeService service;
    late _FakeEventUpstream upstream;
    late EventHub hub;
    late _NotifyFakeSender sender;
    late Directory dir;
    late AfkStore afkStore;
    late AfkComponent afk;

    Future<FcmSender> fakeSender(FirebaseServiceAccount account) async =>
        sender;

    /// Emits an `afk.pr_open` bridge event through the bridge's hub and waits
    /// for the recording sender to receive the push.
    Future<void> emitPrOpen() async {
      hub.emit(
        bridgeEvent(
          type: BridgeEventType.afkPrOpen,
          data: {
            'issueNumber': 7,
            'title': 'Add a README',
            'prNumber': 41,
            'prUrl': 'https://github.com/o/r/pull/41',
          },
        ),
      );
      await _until(() => sender.sent.isNotEmpty, message: 'the AFK push');
    }

    Future<void> emitFailed() async {
      hub.emit(
        bridgeEvent(
          type: BridgeEventType.afkFailed,
          data: {
            // The repo identity (spec #407, T3): the failure push's deep-link
            // resolves the failed repo's stored AFK session from this.
            'repo': 'o/r',
            'issueNumber': 7,
            'title': 'Add a README',
            'reason': 'model under load',
          },
        ),
      );
      await _until(() => sender.sent.isNotEmpty, message: 'the AFK push');
    }

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('opencodebridge-afk-push');
      final accountPath = '${dir.path}/service-account.json';
      FirebaseServiceAccount.install(kAccountJson, path: accountPath);
      service = _FakeService();
      upstream = _FakeEventUpstream();
      hub = EventHub(service: upstream);
      sender = _NotifyFakeSender();
      // The bridge's AFK component, on an app-owned store (the temp dir),
      // seeded with a stored AFK session id — the failure push's deep-link.
      afkStore = AfkStore(file: File('${dir.path}/afk.json'));
      afk = AfkComponent(backend: null, store: afkStore);
      server = await BridgeServer.start(
        port: 0,
        sessions: SessionsBackend(
          service: service,
          orderStore: SessionOrderStore(
            file: File('${dir.path}/session-order.json'),
          ),
        ),
        events: hub,
        notifyCredential: accountPath,
        notifySenderFactory: fakeSender,
        afk: afk,
      );
      base = server.baseUri;
      // The AFK session is armed (a repo armed, its id stored): the failure
      // push has a session to point at.
      afk.updateSettings(
        const AfkSettings(armedRepos: {'o/r'}, parallelOrbs: 5, model: ''),
      );
      await afkStore.setSessionId('o/r', 'ses_afk');
    });

    tearDown(() async {
      await server.stop();
      await dir.delete(recursive: true);
    });

    test('the AFK PR-open push reaches an afkRun device: high priority, '
        'deep-linking the PR URL (external)', () async {
      final (status, _) = await _postRaw(
        base,
        'api/notify/device-token',
        '{"token":"tok_1","events":["afkRun"]}',
      );
      expect(status, 200);

      await emitPrOpen();
      expect(sender.sent, hasLength(1));
      expect(sender.titles.single, 'AFK run : PR ouverte');
      expect(sender.bodies.single, 'Add a README · #7');
      expect(sender.links.single, 'https://github.com/o/r/pull/41');
      expect(sender.priorities.single, isTrue);
    });

    test('the AFK failure push reaches an afkRun device: high priority, '
        'deep-linking the bridge\'s stored AFK session (in-app)', () async {
      final (status, _) = await _postRaw(
        base,
        'api/notify/device-token',
        '{"token":"tok_1","events":["afkRun"]}',
      );
      expect(status, 200);

      await emitFailed();
      expect(sender.sent, hasLength(1));
      expect(sender.titles.single, 'AFK run : échec');
      expect(sender.bodies.single, 'Add a README · #7 — needs-triage');
      // The deep-link is the AFK session the bridge stored (the human reads
      // the agent's FAILED narration in place), not the issue.
      expect(sender.links.single, 'opencodebridge://session/ses_afk');
      expect(sender.priorities.single, isTrue);
    });

    test(
      'a device without the afkRun kind is silent for the AFK events',
      () async {
        // Registered for turnEnded only: the AFK event is not pushed to it.
        await _postRaw(
          base,
          'api/notify/device-token',
          '{"token":"tok_other","events":["turnEnded"]}',
        );
        hub.emit(
          bridgeEvent(
            type: BridgeEventType.afkPrOpen,
            data: {
              'issueNumber': 7,
              'title': 'Add a README',
              'prNumber': 41,
              'prUrl': 'https://github.com/o/r/pull/41',
            },
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(sender.sent, isEmpty);
      },
    );

    test('a device with only afkRun is silent for the other push kinds '
        '(the kinds are independent)', () async {
      // Registered for afkRun only: a turn-ended event is not pushed to it.
      await _postRaw(
        base,
        'api/notify/device-token',
        '{"token":"tok_afk","events":["afkRun"]}',
      );
      hub.emit(
        bridgeEvent(
          type: BridgeEventType.turnCancelled,
          data: {'sessionID': 'ses_afk'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sender.sent, isEmpty);
    });

    test('with no AFK session stored (not armed), the failure push is not '
        'sent (no session to point at); the PR push still is', () async {
      // The PR push needs no AFK session (it deep-links to the PR).
      await _postRaw(
        base,
        'api/notify/device-token',
        '{"token":"tok_1","events":["afkRun"]}',
      );
      await emitPrOpen();
      expect(sender.sent, hasLength(1));
      expect(sender.links.single, 'https://github.com/o/r/pull/41');

      // Clear the stored AFK session (the repo is still armed but has no
      // session): the failure push has nowhere to point, so it is not sent.
      await afkStore.setSessionId('o/r', null);
      sender.sent.clear();
      hub.emit(
        bridgeEvent(
          type: BridgeEventType.afkFailed,
          data: {
            'issueNumber': 7,
            'title': 'Add a README',
            'reason': 'model under load',
          },
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sender.sent, isEmpty);
    });
  });

  group('HttpEventConnection (the shared SSE writer)', () {
    test('the constructor owns the whole SSE response, set before the '
        '`: connected` flush', () async {
      final response = _FakeHttpResponse();
      final conn = HttpEventConnection(response);
      try {
        expect(response.writes, [': connected\n\n']);
        expect(response.firstWriteSnapshot, {
          HttpHeaders.contentTypeHeader: ContentType.parse(
            'text/event-stream; charset=utf-8',
          ).toString(),
          HttpHeaders.cacheControlHeader: 'no-cache',
          HttpHeaders.connectionHeader: 'keep-alive',
          'bufferOutput': false,
          'statusCode': HttpStatus.ok,
        }, reason: 'all the setup must be in place before the first byte');
      } finally {
        await conn.close();
      }
    });

    test('write() frames the payload as `data: <payload>\n\n`', () async {
      final response = _FakeHttpResponse();
      final conn = HttpEventConnection(response);
      try {
        await conn.write('log line');
        await conn.write('naïve — 中文');
        expect(response.writes, [
          ': connected\n\n',
          'data: log line\n\n',
          'data: naïve — 中文\n\n',
        ]);
      } finally {
        await conn.close();
      }
    });

    test(
      'the keep-alive comment paces at the caller-supplied interval',
      () async {
        final response = _FakeHttpResponse();
        final conn = HttpEventConnection(
          response,
          keepAliveInterval: const Duration(milliseconds: 50),
        );
        try {
          await _until(
            () =>
                response.writes.where((w) => w == ': keep-alive\n\n').length >=
                2,
            message: 'expected the periodic keep-alive comments',
          );
          expect(
            response.writes.where((w) => w.startsWith('data: ')),
            isEmpty,
            reason: 'the keep-alive is a comment, never a data frame',
          );
        } finally {
          await conn.close();
        }
      },
    );

    test('close() ends the response and completes done; later writes are '
        'dropped', () async {
      final response = _FakeHttpResponse();
      final conn = HttpEventConnection(response);

      await conn.close();
      expect(response.closed, isTrue);
      await expectLater(conn.done, completes);

      await conn.write('after close');
      expect(response.writes, [': connected\n\n']);
    });

    test(
      'a client disconnect completes done and stops the keep-alive',
      () async {
        final response = _FakeHttpResponse();
        final conn = HttpEventConnection(
          response,
          keepAliveInterval: const Duration(milliseconds: 50),
        );
        await _until(
          () =>
              response.writes.where((w) => w == ': keep-alive\n\n').isNotEmpty,
          message: 'expected a keep-alive before the disconnect',
        );
        final writesBefore = response.writes.length;
        response.clientDisconnect();

        await expectLater(conn.done, completes);
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(
          response.writes.length,
          writesBefore,
          reason: 'no byte may be written after the client is gone',
        );
        expect(response.closed, isFalse, reason: 'the bridge did not close it');
        await conn.write('after disconnect');
        expect(response.writes.length, writesBefore);
      },
    );
  });

  // ------------------------------------------------------------------------
  // The fresh-agent handoff's bridge wiring (spec #376, T6): the arming
  // ensures the AFK session (create or reuse) and the **first feed is a
  // bootstrap** when the session was just created (a wiped store's first arm,
  // or a lost session). A normal restart — the session the service still has —
  // reuses the id, so `id == before` and no bootstrap is sent. The run rows
  // are seeded AFTER [BridgeServer.start] (the startup reconciliation ran on
  // the then-empty store), so these tests make no real `gh` reads.
  group('BridgeServer AFK fresh-agent handoff (spec #376, T6)', () {
    late BridgeServer server;
    late _AfkHandoffService service;
    late AfkStore store;
    late Directory dir;

    tearDown(() async {
      await server.stop();
      await dir.delete(recursive: true);
    });

    Future<void> build() async {
      dir = await Directory.systemTemp.createTemp('oc-afk-handoff');
      store = AfkStore(file: File('${dir.path}/afk.json'));
      service = _AfkHandoffService(dir.path);
      final backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );
      // The repo's checkout is injected (the identity-based default
      // resolution — the first list-order project whose repo identity
      // equals the repo — is covered by the component tests against real
      // git checkouts; this bridge test focuses on the handoff wiring).
      final component = AfkComponent(
        backend: backend,
        store: store,
        directoryOf: (_, _) async => dir.path,
      );
      final hub = EventHub(service: _FakeEventUpstream());
      server = await BridgeServer.start(
        port: 0,
        sessions: backend,
        events: hub,
        afk: component,
      );
    }

    test('a wiped store arms a fresh AFK session and the first feed is the '
        'bootstrap listing the in-flight runs', () async {
      await build();
      // An in-flight run in the store (seeded after start: the startup
      // reconciliation ran on the empty store, so no GitHub read here).
      await store.updateRun(
        const AfkRun(
          ownerRepo: 'o/r',
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
          retryCount: 1,
          lastFailureReason: 'model under load',
        ),
      );
      final ids = await server.updateAfKSettings(
        const AfkSettings(armedRepos: {'o/r'}, parallelOrbs: 5, model: ''),
      );
      expect(ids, hasLength(1), reason: 'the newly armed repo is ensured');
      final id = ids.single;
      expect(id, 'ses_afk_1', reason: 'a fresh session is created');
      expect(service.createdCount, 1, reason: 'the agent is recreated');
      // The first feed is the bootstrap (the in-flight runs from the store),
      // sent to the recreated session.
      expect(service.prompts, hasLength(1));
      expect(service.prompts.single.$1, id);
      expect(
        service.prompts.single.$2,
        allOf(
          contains('#7'),
          contains('dispatched'),
          contains('retry 1'),
          contains('last failure: model under load'),
        ),
      );
    });

    test('a normal restart reuses the session the service still has: no '
        'recreation, no re-bootstrap (ids and full state persist)', () async {
      // The persisted session the service still has, seeded BEFORE the
      // component is built (so its manager is seeded with it: reuse, not
      // create).
      dir = await Directory.systemTemp.createTemp('oc-afk-handoff-reuse');
      store = AfkStore(file: File('${dir.path}/afk.json'));
      service = _AfkHandoffService(dir.path);
      service.present.add('ses_persisted');
      await store.setSessionId('o/r', 'ses_persisted');
      final backend = SessionsBackend(
        service: service,
        orderStore: _InMemoryOrderStore(),
      );
      final component = AfkComponent(
        backend: backend,
        store: store,
        directoryOf: (_, _) async => dir.path,
      );
      final hub = EventHub(service: _FakeEventUpstream());
      server = await BridgeServer.start(
        port: 0,
        sessions: backend,
        events: hub,
        afk: component,
      );
      // An in-flight run (seeded after start: the reconciliation ran on a
      // store with no run rows).
      await store.updateRun(
        const AfkRun(
          ownerRepo: 'o/r',
          issueNumber: 7,
          title: 'Add a README',
          state: 'dispatched',
        ),
      );
      final ids = await server.updateAfKSettings(
        const AfkSettings(armedRepos: {'o/r'}, parallelOrbs: 5, model: ''),
      );
      expect(
        ids.single,
        'ses_persisted',
        reason: 'the stored session is reused',
      );
      expect(service.createdCount, 0, reason: 'no new session is created');
      expect(service.prompts, isEmpty, reason: 'no re-bootstrap on reuse');
    });

    test('arming repo A bootstraps only A in-flight runs (a run of B never '
        'appears in A bootstrap, spec #407, AC3)', () async {
      await build();
      // In-flight runs in two repos (seeded after start: the startup
      // reconciliation ran on the empty store).
      await store.updateRun(
        const AfkRun(
          ownerRepo: 'o/a',
          issueNumber: 7,
          title: 'A run',
          state: 'dispatched',
        ),
      );
      await store.updateRun(
        const AfkRun(
          ownerRepo: 'o/b',
          issueNumber: 55,
          title: 'B run',
          state: 'dispatched',
        ),
      );
      // Arm only o/a: its session is created and bootstrapped with o/a runs.
      final ids = await server.updateAfKSettings(
        const AfkSettings(armedRepos: {'o/a'}, parallelOrbs: 5, model: ''),
      );
      expect(ids, hasLength(1), reason: 'only o/a is newly armed');
      expect(service.createdCount, 1, reason: 'only o/a session is created');
      // The bootstrap goes to o/a session and lists only o/a runs (never
      // o/b).
      expect(service.prompts, hasLength(1));
      expect(service.prompts.single.$1, ids.single);
      expect(
        service.prompts.single.$2,
        contains('#7'),
        reason: 'o/a run is in the bootstrap',
      );
      expect(
        service.prompts.single.$2,
        isNot(contains('#55')),
        reason: 'a run of another repo never appears',
      );
      // Arming o/b later creates o/b session and bootstraps o/b runs only.
      final more = await server.updateAfKSettings(
        const AfkSettings(
          armedRepos: {'o/a', 'o/b'},
          parallelOrbs: 5,
          model: '',
        ),
      );
      expect(more, hasLength(1), reason: 'only o/b is newly armed (o/a was)');
      expect(service.createdCount, 2);
      expect(service.prompts, hasLength(2));
      expect(
        service.prompts[1].$2,
        contains('#55'),
        reason: 'o/b run is in o/b bootstrap',
      );
      expect(service.prompts[1].$2, isNot(contains('#7')));
    });
  });
}

/// A recording [HttpResponse] for the shared-writer tests: it records what is
/// written to the response (verbatim bytes) and snapshots the response's state
/// at the first write, so a test can prove the setup predates the `: connected`
/// flush.
class _FakeHttpResponse implements HttpResponse {
  final _FakeHeaders _headers = _FakeHeaders();
  final List<String> writes = [];
  final Completer<void> _done = Completer<void>();
  final Map<String, Object?> firstWriteSnapshot = {};

  @override
  int statusCode = HttpStatus.ok;

  @override
  bool bufferOutput = true;
  bool closed = false;

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<void> get done => _done.future;

  /// Simulates the client going away (the TCP close that completes
  /// [HttpResponse.done]).
  void clientDisconnect() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void write(Object? object) {
    if (object is! String) return;
    if (firstWriteSnapshot.isEmpty) {
      firstWriteSnapshot
        ..[HttpHeaders.contentTypeHeader] = _headers.value(
          HttpHeaders.contentTypeHeader,
        )
        ..[HttpHeaders.cacheControlHeader] = _headers.value(
          HttpHeaders.cacheControlHeader,
        )
        ..[HttpHeaders.connectionHeader] = _headers.value(
          HttpHeaders.connectionHeader,
        )
        ..['bufferOutput'] = bufferOutput
        ..['statusCode'] = statusCode;
    }
    writes.add(object);
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<void> flush() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The minimal [HttpHeaders]: it records what the writer sets.
class _FakeHeaders implements HttpHeaders {
  final Map<String, Object?> _values = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      _values[name.toLowerCase()] = value;

  /// The value [set] under [name] (or `null`); a stored [ContentType]
  /// (the `content-type` header) is reported as its string form.
  @override
  String? value(String name) {
    final value = _values[name.toLowerCase()];
    if (value is ContentType) return value.toString();
    return value as String?;
  }

  @override
  ContentType? get contentType =>
      _values[HttpHeaders.contentTypeHeader] as ContentType?;

  @override
  set contentType(ContentType? contentType) {
    if (contentType == null) {
      _values.remove(HttpHeaders.contentTypeHeader);
    } else {
      _values[HttpHeaders.contentTypeHeader] = contentType;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The service account the push tests install (issue #24, #288): the key is
/// a real RSA PEM (the default sender parses it at construction), but no
/// delivery ever leaves the process (the recording sender stands in for it).
const String kPrivateKey =
    "-----BEGIN PRIVATE KEY-----\n"
    "MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQC8eiyvZu7imXnx\n"
    "ydajqaGBuR5yVYDtWpqvJJHWeWREipAJXTS/00Rf9nR2/tRC0ttrb95U2q2dCPPj\n"
    "kzoyH6O7XMjEm8zjBFYrHQEcbLH53m/5+RaAa7FOXaozM5IILu157Sc6cuB3dhiH\n"
    "otlUTZpoaM76jD7nEFckw/z9B1f7qBW2KqGWYrIdF2+RyGVMEEYOkQrQrmmW5BUu\n"
    "pXfe7TzbAnmmC0l8IQ3+UUSSiLTEsu0PlOhh298577P0HezEjYddzj4gY0OgFSHQ\n"
    "hfRvkC5PXyXVBUfsdo/5D+vuSkNrjxz+iszP8NHRFTx5H7nz4baXcx5VFtfn5iFU\n"
    "qstmMBEpAgMBAAECggEAAkQOPjgUsl7xuTtJ1CsdhNGYyPtX6tKSZj1gbvWD4/KN\n"
    "/3zSPeWgbm5oMUeIPfrqtiCQydCcsnT5eKCMHC7m8SFRDRMJ7CdA0XEecqzoWVaI\n"
    "HldVIstYpPZpjcbGkEhfJL56AKEBq5H9AsFtjy7FJtDuvxKZTX4T7B5aj+CrGTyD\n"
    "aKR/I1IUmtzzX4j9WpbOBMG6OlinhxKzt4/7FDJzxx37X0KjDVvUh0issWt35HO+\n"
    "0F0ea0xltv9cAsZRBh5bheQMY3bQOcUb/zQO7bCzL4fRvkiFylQxFjt/MKgMRbjP\n"
    "apEWYRZM0d9Hfp4IgoMj8joMn1DPXL33Y8R5L+YhoQKBgQDiT+k+kOzIfYq9dsNS\n"
    "IPtIQml6WHR62P5IQvWT0hRf4O6LTWtKd6oU4HMBDnf5xwGzA8UeigU8Mj+/763n\n"
    "XPjHbOCkE1Ckz8O5iVPx2hHlhx8Ythqpj5iqkrzqEXN6WdFRAda0AIvI4LNv9Tzm\n"
    "H0femnWbCf7h0tiUuyH+w7q0yQKBgQDVM63ccKfFp/rEtkwQ/XWz5dMrjnszwUZ+\n"
    "PltS6d3yw8/xrd/IbngQ1vf7G7ZMyUDg+zjE39FvCSAXEMzaQFglW9iDQvw4Wqrr\n"
    "KWf8aS47D30B6wuTFErlI9mXhZnDatM80Qphx73FA67PBr2KqsI6pWJJ3bziSRi3\n"
    "X4oIVyKJYQKBgG1Ih2pmE2FRdlC9a95Z/N3M7CBfXIgCBvCgHPRvytTtymNMVFYW\n"
    "aPRB2mcVNIxSNBjc5jA0GAkUfsJRnBmQRLYQdn3ksdmUVoBet0Gfu2qqEDMfpMpi\n"
    "hCdCSqWBHdFkU/aZO7OaW+X508xpkSnSyyLMVaQzdHhaF6nin6zlmWA5AoGAFqYA\n"
    "yDQnfnXTy+XZusxSHqRBhJUEPYFArdSN+wbhDxMCGhhwd2hU1OUhPsm42ftfKwdF\n"
    "BpUIOJVtlUWxnVXMh1t0aq1JAeuP0J97bnL1+Ewy6WtAtYUoV6MxUElfBkVo30MN\n"
    "qUmAvVcg0NlUdVCihXxgLpyhniBJweEiVrR69MECgYA07ebbgc3GBvHCIrcBMsrO\n"
    "bdFMCyh1yOTizML7qtoQKInrj0Y0yM0TX/Q4vdZFtepy89BTCA4RfOYg5xUB65Yw\n"
    "LMso5I/CHT5MsSAAlO7GyGWCDWRnZbg9Q5AuQLDrWjy8shiRvFyTncgzYeGXExSr\n"
    "PpRSVDvtElyBUiljh0ZkkQ==\n"
    "-----END PRIVATE KEY-----";

/// A fake project's service account: the key is a real RSA PEM (the default
/// sender parses it at construction), but no delivery happens in these tests.
final String kAccountJson = jsonEncode({
  'type': 'service_account',
  'project_id': 'opencodebridge-reload-test',
  'private_key': kPrivateKey,
  'client_email': 'firebase-adminsdk-test@opencodebridge-reload-test.iam.gserviceaccount.com',
  'client_id': '1234567890',
  'token_uri': 'https://oauth2.googleapis.com/token',
});

/// An in-memory [SessionOrderStore] for tests that construct a
/// [SessionsBackend] but never touch the order store (issue #271: the store
/// is required at construction). It keeps the positions in memory, never the
/// app-owned file, so a test's store does not leak onto the host.
class _InMemoryOrderStore implements SessionOrderStore {
  final Map<String, num> _positions = {};

  @override
  File get file => throw StateError('in-memory store has no file');

  @override
  Map<String, num> load() => Map<String, num>.from(_positions);

  @override
  Future<void> set(String id, num position) async {
    _positions[id] = position;
  }

  @override
  Future<void> clear(String id) async {
    _positions.remove(id);
  }
}

/// A minimal [OpencodeService] for the AFK fresh-agent handoff's bridge test
/// (spec #376, T6): it records the session create and the feeds (prompts) and
/// answers create/probe/projects/active from scripted state. Only the handoff
/// path's operations are implemented (the bridge wires only the sessions
/// backend + the AFK component here); an unexpected call throws, so a test
/// drift is loud, not silent.
class _AfkHandoffService implements OpencodeService {
  _AfkHandoffService(this.directory);

  /// The main checkout's directory (the session is created in it).
  final String directory;

  /// The ids the service still has (probe answers present for these; the
  /// reuse case seeds the persisted id here).
  final Set<String> present = {};

  int createdCount = 0;
  final List<
    (String, String, List<Map<String, Object?>>?, List<Map<String, Object?>>?)
  >
  prompts = [];

  @override
  Future<List<OpencodeProject>> projects() async => const [
    OpencodeProject(id: 'p1', name: 'proj', canonical: '/repo/main'),
  ];

  @override
  Future<OpencodeSession> createSessionInDirectory(
    String directory, {
    ModelRef? model,
    String? agent,
  }) async {
    createdCount++;
    final id = 'ses_afk_$createdCount';
    present.add(id);
    return OpencodeSession(
      id: id,
      title: 'AFK',
      projectId: 'p1',
      created: createdCount,
      location: directory,
    );
  }

  @override
  Future<OpencodeSession> probe(String id) async {
    if (!present.contains(id)) {
      throw const OpencodeServiceError(404, 'no such session');
    }
    return OpencodeSession(
      id: id,
      title: 'AFK',
      projectId: 'p1',
      created: 0,
      location: directory,
    );
  }

  @override
  Future<Set<String>> activeSessionIds() async => const {};

  @override
  Future<void> prompt(
    String id,
    String text, {
    List<Map<String, Object?>>? files,
    List<Map<String, Object?>>? skills,
  }) async {
    prompts.add((id, text, files, skills));
  }

  @override
  Future<List<OpencodeSession>> listSessions() async => const [];

  @override
  Future<Map<String, String>> projectNames() async => const {'p1': 'proj'};

  @override
  Future<bool> waitIdle(
    String id, {
    Duration timeout = const Duration(seconds: 25),
  }) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'not in the AFK handoff fake: ${invocation.memberName}',
  );
}

/// A scripted service for the sessions-endpoint tests.
class _FakeService implements OpencodeService {
  _FakeService({
    this.detail,
    this.messages = const [],
    this.permissions = const [],
    this.questions = const [],
    this.overrideProjects,
  });

  /// When set, [projects] returns these (the compose tests point one at a
  /// temp directory that actually holds a compose file).
  final List<OpencodeProject>? overrideProjects;

  final List<String> deleted = [];
  final Set<String> removedFromService = {};
  var failList = false;
  var failProjects = false;
  var failCreate = false;
  var failCreateInDirectory = false;
  var failDetail = false;
  var failMessages = false;
  var failPermissions = false;
  var failPrompt = false;
  var failReply = false;
  var failQuestions = false;
  var failAnswer = false;
  var failDismiss = false;
  var failCompact = false;
  var failCancel = false;
  var failUsage = false;

  /// The [listSessions] calls (the cost of the old paginated existence walk;
  /// the order route's probe path never walks the list — issue #272).
  var listSessionsCalls = 0;

  /// The ids [probe] was asked about (the order route's existence check,
  /// issue #272).
  final List<String> probedIds = [];

  /// Per-session pending permission requests (the waiting fact, issue #208):
  /// a session scripted here answers its own list; an unscripted session
  /// answers the shared [permissions].
  final Map<String, List<PermissionRequest>> pendingPermissionsBySession = {};

  /// Per-session pending question forms (the waiting fact, issue #208):
  /// a session scripted here answers its own list; an unscripted session
  /// answers the shared [questions].
  final Map<String, List<QuestionForm>> pendingQuestionsBySession = {};

  /// When true, [cancelTurn] refuses with the typed [CancelUnsupportedError]
  /// (the service has no interrupt route) instead of cancelling (issue #160).
  /// Mutable so the same fake can be "restarted upgraded" mid-test (the
  /// re-probe path).
  var cancelUnsupported = false;

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
  final List<QuestionForm> questions;

  final List<
    (String, String, List<Map<String, Object?>>?, List<Map<String, Object?>>?)
  >
  prompts = [];

  final List<(String, String, PermissionReply)> replies = [];

  final List<(String, String, List<List<String>>)> answered = [];

  final List<(String, String)> questionDismissed = [];

  @override
  Future<List<OpencodeSession>> listSessions() async {
    if (failList) throw const OpencodeServiceError(0, 'service down');
    listSessionsCalls++;
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
  Future<bool> waitIdle(
    String id, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final active = await activeSessionIds();
    return !active.contains(id);
  }

  @override
  Future<List<OpencodeProject>> projects() async {
    if (failProjects) throw const OpencodeServiceError(0, 'service down');
    final override = overrideProjects;
    if (override != null) return override;
    return const [
      OpencodeProject(id: 'p1', name: 'proj-one', canonical: '/proj/one'),
      OpencodeProject(id: 'p2', name: 'proj-two', canonical: '/proj/two'),
    ];
  }

  @override
  Future<OpencodeSession> createSession(
    String projectId, {
    ModelRef? model,
    String? agent,
  }) async {
    if (failCreate) throw const OpencodeServiceError(0, 'service down');
    final session = created[projectId];
    if (session == null) {
      throw const OpencodeServiceError(404, 'no such project');
    }
    return session;
  }

  /// The session [createSessionInDirectory] mints, at [directory] (issue
  /// #54's "New project").
  @override
  Future<OpencodeSession> createSessionInDirectory(
    String directory, {
    ModelRef? model,
    String? agent,
  }) async {
    if (failCreateInDirectory) {
      throw const OpencodeServiceError(0, 'service down');
    }
    return OpencodeSession(
      id: 'ses_created_dir',
      title: 'created in $directory',
      projectId: 'p_dir',
      created: 400,
      location: directory,
    );
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

  @override
  Future<void> archive(String id, bool archived) async {
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    this.archived.add((id, archived));
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

  /// The light identity read (issue #272): the scripted session when it
  /// exists, a service 404 otherwise — the order route's existence check.
  @override
  Future<OpencodeSession> probe(String id) async {
    probedIds.add(id);
    for (final session in const [_one, _two, _three]) {
      if (session.id == id && !removedFromService.contains(session.id)) {
        return session;
      }
    }
    throw const OpencodeServiceError(404, 'not found');
  }

  @override
  Future<List<SessionMessage>> getMessages(String id) async {
    if (failMessages) throw const OpencodeServiceError(0, 'service down');
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    return messages;
  }

  /// The last [getMessagesPage] call's limit and cursor (issue #124).
  int? lastPageLimit;
  String? lastPageCursor;

  @override
  Future<MessagePage> getMessagesPage(
    String id, {
    int limit = 50,
    String? cursor,
  }) async {
    lastPageLimit = limit;
    lastPageCursor = cursor;
    if (failMessages) throw const OpencodeServiceError(0, 'service down');
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    return MessagePage(messages: messages, nextCursor: null);
  }

  @override
  Future<void> prompt(
    String id,
    String text, {
    List<Map<String, Object?>>? files,
    List<Map<String, Object?>>? skills,
  }) async {
    if (failPrompt) throw const OpencodeServiceError(0, 'service down');
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    // The service rejects an unreadable file attachment with a 400 naming
    // the offending field (the TUI's @-mention failure mode).
    final unreadable = files?.any(
      (item) => ((item['uri'] as String?) ?? '').endsWith('/missing.txt'),
    );
    if (unreadable == true) {
      throw const OpencodeServiceError(400, 'files: no such file');
    }
    prompts.add((id, text, files, skills));
  }

  @override
  Future<List<PermissionRequest>> pendingPermissions(String id) async {
    if (failPermissions) throw const OpencodeServiceError(0, 'service down');
    final scripted = pendingPermissionsBySession;
    if (scripted.containsKey(id)) return scripted[id]!;
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

  // The structured view's question forms (issue #50): recorded, keyed to the
  // scripted session like the endpoint 5–9 ops above.

  @override
  Future<List<QuestionForm>> pendingQuestions(String id) async {
    if (failQuestions) throw const OpencodeServiceError(0, 'service down');
    final scripted = pendingQuestionsBySession;
    if (scripted.containsKey(id)) return scripted[id]!;
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    return questions;
  }

  @override
  Future<void> answerQuestion(
    String id,
    String formID,
    List<List<String>> answers,
  ) async {
    if (failAnswer) throw const OpencodeServiceError(0, 'service down');
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    if (!questions.any((f) => f.id == formID)) {
      throw const OpencodeServiceError(404, 'not found');
    }
    answered.add((id, formID, answers));
  }

  @override
  Future<void> dismissQuestion(String id, String formID) async {
    if (failDismiss) throw const OpencodeServiceError(0, 'service down');
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    if (!questions.any((f) => f.id == formID)) {
      throw const OpencodeServiceError(404, 'not found');
    }
    questionDismissed.add((id, formID));
  }

  // The structured view's `/` command menu (issue #46): recorded, keyed to
  // the structured session like the endpoint 5–9 ops above.

  final List<OpencodeCommand> commands = const [
    OpencodeCommand(name: 'deploy', description: 'ship it'),
  ];
  final List<ModelOption> models = const [
    ModelOption(
      id: 'm1',
      providerId: 'prov',
      name: 'Model One',
      variants: ['high'],
    ),
  ];
  final List<AgentOption> agents = const [
    AgentOption(id: 'a1', name: 'Agent One', description: 'does things'),
  ];
  final List<SkillOption> skills = const [
    SkillOption(id: 'sk1', name: 'Skill One', description: 'a skill'),
  ];
  final List<(String, String, String)> commandsRun = [];
  final List<(String, ModelRef)> modelsSet = [];
  final List<(String, String)> agentsSet = [];
  final List<(String, String)> skillsActivated = [];
  final List<String> compacted = [];
  final List<String> cancelled = [];
  final List<String> undos = [];
  final List<String> redos = [];
  final List<String> forks = [];
  final List<String> renamed = [];
  final List<String> moved = [];
  final List<(String, String)> btws = [];
  final List<(String, String)> integrationsConnected = [];
  final List<(String, bool)> archived = [];

  @override
  Future<List<OpencodeCommand>> listCommands() async => commands;

  @override
  Future<void> runCommand(String id, String name, String text) async {
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    commandsRun.add((id, name, text));
  }

  @override
  Future<List<ModelOption>> listModels() async => models;

  @override
  Future<ModelRef?> currentModel(String id) async =>
      const ModelRef(id: 'm1', providerId: 'prov');

  @override
  Future<void> setModel(String id, ModelRef model) async {
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    modelsSet.add((id, model));
  }

  @override
  Future<List<AgentOption>> listAgents() async => agents;

  @override
  Future<void> setAgent(String id, String agentId) async {
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    agentsSet.add((id, agentId));
  }

  @override
  Future<List<SkillOption>> listSkills() async => skills;

  @override
  Future<void> activateSkill(String id, String skillId) async {
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    skillsActivated.add((id, skillId));
  }

  @override
  Future<void> compact(String id) async {
    if (failCompact) throw const OpencodeServiceError(0, 'service down');
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    compacted.add(id);
  }

  @override
  Future<void> undo(String id) async {
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    undos.add(id);
  }

  @override
  Future<void> redo(String id) async {
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    redos.add(id);
  }

  @override
  Future<void> cancelTurn(String id) async {
    if (failCancel) throw const OpencodeServiceError(0, 'service down');
    if (cancelUnsupported) {
      throw const CancelUnsupportedError('this service has no interrupt route');
    }
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    cancelled.add(id);
  }

  @override
  Future<bool> canCancelTurn(String id) async => !cancelUnsupported;

  @override
  Future<String> fork(String id) async {
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    forks.add(id);
    return 'ses_forked';
  }

  @override
  Future<void> rename(String id, String title) async {
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    renamed.add(title);
  }

  @override
  Future<String> exportSession(String id) async {
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    return '{"info":"export"}';
  }

  @override
  Future<void> move(String id, String directory) async {
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    moved.add(directory);
  }

  @override
  Future<String> generate(String id, String prompt) async {
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    btws.add((id, prompt));
    return 'answer to $prompt';
  }

  @override
  Future<String> diff(String id) async {
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    return '{"diff":true}';
  }

  @override
  Future<String> stats(String id) async {
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    return '{"stats":true}';
  }

  @override
  Future<String> worktrees(String projectId) async => '{"worktrees":true}';

  final List<String> filesFound = const ['src/main.dart', 'pubspec.yaml'];
  final List<(String, String)> filesSearched = [];

  @override
  Future<List<String>> findFiles(String id, String query) async {
    if (!_known(id)) throw const OpencodeServiceError(404, 'not found');
    filesSearched.add((id, query));
    return filesFound;
  }

  @override
  Future<String> usage() async {
    if (failUsage) throw const OpencodeServiceError(0, 'service down');
    return '{"usage":true}';
  }

  @override
  Future<String> mcps() async => '{"mcps":true}';

  @override
  Future<String> integrations() async => '{"integrations":true}';

  @override
  Future<String> connectIntegration(
    String integrationId,
    String methodId,
  ) async {
    integrationsConnected.add((integrationId, methodId));
    return '{"connect":true}';
  }

  @override
  Future<String> status() async => '{"status":true}';

  @override
  Future<String> pair() async => '{"pair":true}';

  @override
  Future<void> reload() async {}

  @override
  Future<String> plugins() async => '{"plugins":true}';
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
  // The wire-contract row: an archived session is still listed (the seam is
  // faithful) and carries the flag (issue #234).
  archived: true,
);

/// Assert the question group's recorded answer: the (session, form) pair and
/// the answers, compared list by list (record `==` is identity on the answers
/// list field).
void _expectAnswered(
  _FakeService service,
  String formID,
  List<List<String>> answers,
) {
  expect(service.answered, hasLength(1));
  final (sid, fid, got) = service.answered.single;
  expect(sid, 'ses_one');
  expect(fid, formID);
  expect(got.length, answers.length);
  for (var i = 0; i < answers.length; i++) {
    expect(got[i], answers[i]);
  }
}

Future<(int, String)> _get(Uri base, String path, {String? query}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(base.replace(path: path, query: query));
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

Future<(int, String)> _patchRaw(Uri base, String path, String body) async {
  final client = HttpClient();
  try {
    final request = await client.patchUrl(base.replace(path: path));
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

/// A session-scoped opencode event on the unified stream (a durable seq names
/// the session): the wire shape the bridge's [TurnTracker] reads the turn from
/// (issue #164).
String _execRaw(String sessionID, String type, {Map<String, Object?>? data}) =>
    jsonEncode({
      'id': 'evt_$type',
      'type': type,
      'data': data ?? const <String, Object?>{},
      'durable': {'aggregateID': sessionID, 'seq': 1, 'version': 1},
    });

/// A turn opens for [sessionID] on the stream.
void _emitExecStarted(_FakeEventUpstream upstream, String sessionID) {
  upstream.add(
    OpencodeEvent(
      raw: _execRaw(sessionID, 'session.execution.started'),
      type: 'session.execution.started',
    ),
  );
}

/// A step names the in-flight [messageID] for [sessionID]'s running turn.
void _emitStepStarted(
  _FakeEventUpstream upstream,
  String sessionID,
  String messageID,
) {
  upstream.add(
    OpencodeEvent(
      raw: _execRaw(
        sessionID,
        'session.step.started',
        data: {'assistantMessageID': messageID},
      ),
      type: 'session.step.started',
    ),
  );
}

/// A scripted [FsService] for the fs endpoint tests: the drives and
/// subdirectory results are scripted, and an [FsError] can be injected.
class _FakeFsService implements FsService {
  List<String> drivesResult = const ['/'];
  FsError? drivesError;

  final List<String> subdirectoriesCalled = [];
  Map<String, List<String>> subdirectoriesResult = const {};
  FsError? subdirectoriesError;

  final List<String> createdDirectories = [];
  FsError? createDirectoryError;

  @override
  Future<List<String>> drives() async {
    final error = drivesError;
    if (error != null) throw error;
    return drivesResult;
  }

  @override
  Future<List<String>> subdirectories(String path) async {
    subdirectoriesCalled.add(path);
    final error = subdirectoriesError;
    if (error != null) throw error;
    return subdirectoriesResult[path] ?? const [];
  }

  @override
  Future<void> createDirectory(String path) async {
    final error = createDirectoryError;
    if (error != null) throw error;
    createdDirectories.add(path);
  }
}

/// A scripted docker backend for the route tests: the run seam is scripted,
/// and the spawn seam hands out a controllable child per command (`events`
/// gets the event-watch child, `logs` gets the log-stream child).
class _FakeDockerBridge {
  _FakeDockerBridge({void Function(String)? emit}) {
    _backend = DockerBackend(run: _run, spawn: _spawn, emit: emit);
  }

  final List<List<String>> runArgs = [];
  final List<String?> runWorkingDirs = [];
  final List<List<String>> spawnArgs = [];
  final List<_FakeDockerChild> children = [];
  DockerCliResult runResult = const DockerCliResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );
  final List<DockerCliResult> runResults = [];
  final StreamController<String> eventsLines = StreamController<String>();
  final StreamController<String> logsLines = StreamController<String>();
  late final DockerBackend _backend;

  DockerBackend get backend => _backend;

  Future<DockerCliResult> _run(
    List<String> argv, {
    String? workingDirectory,
  }) async {
    runArgs.add(List.of(argv));
    runWorkingDirs.add(workingDirectory);
    return runResults.isNotEmpty ? runResults.removeAt(0) : runResult;
  }

  Future<DockerProcess> _spawn(
    List<String> argv, {
    String? workingDirectory,
  }) async {
    spawnArgs.add(List.of(argv));
    final lines = argv.first == 'events' ? eventsLines : logsLines;
    final child = _FakeDockerChild(lines);
    children.add(child);
    return child.toProcess();
  }
}

/// One docker CLI child: its stdout is the given line controller, and
/// killing it closes the controller (like the CLI child exiting).
class _FakeDockerChild {
  _FakeDockerChild(this._lines);

  final StreamController<String> _lines;
  bool killed = false;

  DockerProcess toProcess() => DockerProcess(
    stdout: _lines.stream,
    stderr: const Stream.empty(),
    exitCode: Completer<int>().future,
    kill: kill,
  );

  Future<void> kill() async {
    if (killed) return;
    killed = true;
    await _lines.close();
  }
}

/// One raw connection to a container's log SSE stream, accumulating the
/// received frames (the seam a curl/DockerClient sees).
class _LogsTap {
  _LogsTap._(
    this._client,
    this.status,
    this._contentType,
    this._sub,
    this._buffer,
  );

  static Future<_LogsTap> open(Uri base, String name) async {
    final client = HttpClient();
    final request = await client.getUrl(
      base.replace(path: 'api/docker/containers/$name/logs', query: 'follow=1'),
    );
    final response = await request.close();
    final buffer = StringBuffer();
    final sub = response.transform(const Utf8Decoder()).listen(buffer.write);
    return _LogsTap._(
      client,
      response.statusCode,
      response.headers.contentType?.toString(),
      sub,
      buffer,
    );
  }

  final HttpClient _client;
  final int status;
  final String? _contentType;
  final StreamSubscription<String> _sub;
  final StringBuffer _buffer;

  String? get contentType => _contentType;

  /// The payloads of every `data:` frame, in order.
  List<String> get dataPayloads => _buffer
      .toString()
      .split('\n\n')
      .where((frame) => frame.startsWith('data: '))
      .map((frame) => frame.substring('data: '.length))
      .toList();

  Future<void> close() async {
    await _sub.cancel();
    _client.close(force: true);
  }
}

/// On a host with the docker CLI on PATH the bridge default builds a real
/// docker backend, so the 503 path is not observable there: the test marks
/// itself skipped and returns true.
bool _hostHasDockerCli() {
  if (findHostDocker() != null) {
    markTestSkipped(
      'the host has a docker CLI on PATH, so the bridge default builds a '
      'real docker backend',
    );
    return true;
  }
  return false;
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

/// A recording FCM transport for the push tests. The registration tests
/// record only the [token] (nothing is sent); the push-label tests record
/// the [bodies] so they can assert on the body the label closure resolved.
class _NotifyFakeSender extends FcmSender {
  final sent = <String>[];
  final bodies = <String>[];
  final links = <String>[];
  final titles = <String>[];
  final priorities = <bool>[];

  @override
  Future<void> send({
    required String token,
    required String title,
    required String body,
    required String link,
    bool highPriority = false,
  }) async {
    sent.add(token);
    bodies.add(body);
    links.add(link);
    titles.add(title);
    priorities.add(highPriority);
  }
}

/// A downstream event-connection recorder (the log-surface test): captures
/// every verbatim `data:` payload the hub writes, in order.
class _RecordingEventConnection implements EventConnection {
  final List<String> payloads = [];

  @override
  Future<void> write(String rawPayload) async => payloads.add(rawPayload);

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Completer<void>().future;
}

/// A supervised tunnel child (the degraded-boot test only wants to know the
/// tunnel was spawned, not to run it): `kill()` completes the exit code, so
/// the bridge's `stop()` does not wait out the grace period.
class _NoopTunnelProcess implements TunnelProcess {
  final Completer<int> _exited = Completer<int>();

  @override
  int get pid => 99999;

  @override
  Future<int> get exitCode => _exited.future;

  @override
  bool kill() {
    if (!_exited.isCompleted) _exited.complete(0);
    return true;
  }
}

/// A fake opencode child (issue #153 bridge tests): controllable stdout
/// (the `server listening on …` / `server password …` lines), a settable
/// liveness, and a kill that records the SIGTERM.
class _FakeBootChild implements OpencodeChild {
  @override
  final int pid = 424242;

  final _stdout = StreamController<List<int>>.broadcast();
  final _stderr = StreamController<List<int>>.broadcast();
  final _exited = Completer<int>();

  final List<ProcessSignal> kills = [];

  /// Whether the process is still alive.
  bool alive = true;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode {
    if (!alive && !_exited.isCompleted) _exited.complete(0);
    return _exited.future;
  }

  @override
  bool kill() {
    if (alive) kills.add(ProcessSignal.sigterm);
    die(0);
    return true;
  }

  void die(int code) {
    alive = false;
    if (!_exited.isCompleted) _exited.complete(code);
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }

  void emitLine(String line) => _stdout.add(utf8.encode('$line\n'));

  void emitListening(String url) => emitLine('server listening on $url');

  void emitPassword(String pw) => emitLine('server password $pw');
}

/// The fake host around [OpencodeServiceBooter] for the bridge tests:
/// records every spawn and signal and answers the probes. The marker and
/// descriptor live in [dir] (never the real `~/.local/state/opencode/`).
class _BootFake {
  _BootFake(this.dir);

  final Directory dir;

  final List<List<String>> argvs = [];
  final List<_FakeBootChild> spawned = [];

  /// The pids signalled, with the signal.
  final List<(int, ProcessSignal)> signals = [];

  /// The opencode CLI path; `null` → no CLI at all (the boot fails).
  String? cli;

  /// Whether the service at the resolved url answers the Basic-auth probe.
  bool serviceAnswers = false;

  /// When set, the spawned child reports ready on spawn (the `server
  /// listening on …` + `server password …` lines) and the service answers.
  bool emitReadyOnSpawn = false;

  String readyUrl = 'http://127.0.0.1:4096';

  bool get childKilled => spawned.isNotEmpty && spawned.first.kills.isNotEmpty;

  File get marker => File('${dir.path}/opencodebridge-child.json');

  File get descriptor => File('${dir.path}/service.json');

  OpencodeServiceBooter booter() {
    return OpencodeServiceBooter(
      cli: () async => cli,
      spawner: (List<String> argv) async {
        argvs.add(argv);
        final child = _FakeBootChild();
        spawned.add(child);
        if (emitReadyOnSpawn) {
          serviceAnswers = true;
          unawaited(
            Future<void>.delayed(const Duration(milliseconds: 10)).then((_) {
              child.emitListening(readyUrl);
              child.emitPassword('pw');
            }),
          );
        }
        return child;
      },
      kill: (int pid, ProcessSignal signal) async {
        signals.add((pid, signal));
        return true;
      },
      pidAlive: (int pid) {
        for (final child in spawned) {
          if (child.pid == pid && !child.alive) return false;
        }
        return true;
      },
      isPortFree: (int port) async => true,
      serviceProbe: (Uri url, String password) async => serviceAnswers,
      startTimeout: const Duration(seconds: 5),
      killGrace: const Duration(milliseconds: 50),
      marker: marker,
      descriptor: descriptor,
    );
  }
}
