import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/sessions/opencode_http_service.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/model/session_detail.dart';

/// A stand-in for the shared opencode service: it serves the four endpoints
/// the bridge needs, checks Basic auth, and paginates `GET /api/session` in
/// small pages to exercise the client's cursor loop.
void main() {
  const password = 'secret';
  // The service's `order=desc` (newest first) page order.
  final allSessions = [
    {
      'id': 'ses_3',
      'title': 'c',
      'projectID': 'p2',
      'time': {'created': 300},
      'location': {'directory': '/c'},
    },
    {
      'id': 'ses_2',
      'title': 'b',
      'projectID': 'p1',
      'time': {'created': 200},
      'location': {'directory': '/b'},
    },
    {
      'id': 'ses_1',
      'title': 'a',
      'projectID': 'p1',
      'time': {'created': 100},
      'location': {'directory': '/a'},
    },
  ];
  final projects = [
    {'id': 'p1', 'canonical': '/proj/one'},
    {'id': 'p2', 'canonical': '/proj/two', 'name': 'Two'},
  ];
  final active = <String, Object?>{
    'ses_2': {'type': 'running'},
  };
  const pageSize = 2;

  // The service's `Session.Info` for `ses_1` (the detail endpoint).
  final detailInfo = {
    'id': 'ses_1',
    'title': 'one',
    'cost': 1.5,
    'tokens': {
      'input': 100,
      'output': 50,
      'reasoning': 5,
      'cache': {'read': 10, 'write': 2},
    },
    'outcome': 'succeeded',
    'location': {'directory': '/one'},
    'time': {'created': 100, 'updated': 200},
    'model': {'id': 'mod1', 'providerID': 'prov1'},
  };

  // The detail of `ses_2`: the model is unknown to the registry, so the
  // context limit must fall back to `null`.
  final detailInfo2 = {
    'id': 'ses_2',
    'title': 'two',
    'cost': 0,
    'tokens': {
      'input': 0,
      'output': 0,
      'reasoning': 0,
      'cache': {'read': 0, 'write': 0},
    },
    'location': {'directory': '/two'},
    'model': {'id': 'unknown-model', 'providerID': 'prov2'},
  };

  // The service's model registry (the `limit.context` context windows).
  final modelRegistry = [
    {
      'id': 'mod1',
      'modelID': 'mod1',
      'providerID': 'prov1',
      'limit': {'context': 123456},
    },
  ];

  // The service's `Session.Message.Info` history for `ses_1` (endpoint 6).
  // The fake serves it newest-first in pages of at most 200 (the service's
  // pagination), and the 200 `synthetic` filler items push the history past
  // one full page so the client's loop is exercised. The `system` item must
  // be skipped by the client.
  final historyMessages = <Map<String, Object?>>[
    {
      'type': 'user',
      'id': 'm1',
      'time': {'created': 1},
      'text': 'do the thing',
    },
    {
      'type': 'assistant',
      'id': 'm2',
      'time': {'created': 2},
      'agent': 'a',
      'model': 'm',
      'tokens': {
        'input': 100,
        'output': 50,
        'reasoning': 0,
        'cache': {'read': 5000, 'write': 10},
      },
      'content': [
        {'type': 'text', 'text': 'working'},
        {
          'type': 'tool',
          'id': 't1',
          'name': 'bash',
          'time': {'created': 3},
          'state': {
            'status': 'running',
            'input': {'command': 'ls'},
          },
        },
        {'type': 'reasoning', 'text': 'hmm'},
        {
          'type': 'tool',
          'id': 't2',
          'name': 'write',
          'time': {'created': 4},
          'state': {
            'status': 'error',
            'input': {'path': '/x'},
            'error': {'type': 'fail', 'message': 'denied'},
          },
        },
      ],
    },
    {
      'type': 'system',
      'id': 'm3',
      'time': {'created': 5},
      'text': 'boot',
    },
    for (var i = 0; i < 200; i++)
      {
        'type': 'synthetic',
        'id': 'f$i',
        'time': {'created': 100 + i},
        'text': 'filler $i',
      },
  ];

  // The service's pending `Permission.Request` list for `ses_1`.
  final pendingPerms = [
    {
      'id': 'per_1',
      'sessionID': 'ses_1',
      'action': 'shell',
      'resources': ['ls'],
    },
  ];

  final promptBodies = <Map<String, Object?>>[];
  final replyBodies = <Map<String, Object?>>[];
  final repliedRequestIDs = <String>[];
  final messageOffsets = <int>[];

  late HttpServer server;
  late Uri base;

  setUp(() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    base = Uri.parse('http://127.0.0.1:${server.port}/');
    server.listen((req) async {
      final resp = req.response;
      resp.headers.contentType = ContentType.json;
      final auth = req.headers.value(HttpHeaders.authorizationHeader);
      final expected =
          'Basic ${base64Encode(utf8.encode('opencode:$password'))}';
      if (auth != expected) {
        resp.statusCode = HttpStatus.unauthorized;
        await resp.close();
        return;
      }
      final path = req.uri.path;
      if (path == '/api/session' && req.method == 'POST') {
        final body = await utf8.decodeStream(req);
        final decoded = jsonDecode(body) as Map<String, Object?>;
        final location = decoded['location'] as Map<String, Object?>?;
        final directory = location?['directory'] as String?;
        // Echo the created session, bound to the project of the directory.
        final projectId = directory == '/proj/two'
            ? 'p2'
            : directory == '/proj/one'
            ? 'p1'
            : 'p1';
        // The real service wraps the created session in a `data` envelope
        // (like the list endpoint); echo that shape to pin the unwrap.
        resp.write(
          jsonEncode({
            'data': {
              'id': 'ses_new',
              'title': 'new',
              'projectID': projectId,
              'time': {'created': 400},
              'location': {'directory': directory ?? ''},
            },
          }),
        );
      } else if (path == '/api/session') {
        final cursor = req.uri.queryParameters['cursor'];
        final offset = cursor == null ? 0 : int.parse(cursor);
        final nextOffset = offset + pageSize;
        resp.write(
          jsonEncode({
            'data': allSessions.skip(offset).take(pageSize).toList(),
            'cursor': {
              'next': nextOffset < allSessions.length ? '$nextOffset' : null,
              'previous': null,
            },
          }),
        );
      } else if (path == '/api/project') {
        resp.write(jsonEncode(projects));
      } else if (path == '/api/session/active') {
        resp.write(jsonEncode({'data': active}));
      } else if (path == '/api/session/ses_1/message' && req.method == 'GET') {
        final cursor = req.uri.queryParameters['cursor'];
        final limit = int.parse(req.uri.queryParameters['limit'] ?? '50');
        // The real service serves the history newest-first by cursor, the
        // cursor skipping `offset` of the newest items (opaque here: an
        // integer, like the session list fake).
        final offset = cursor == null ? 0 : int.parse(cursor);
        messageOffsets.add(offset);
        final newestFirst = historyMessages.reversed.toList();
        final page = newestFirst.skip(offset).take(limit).toList();
        resp.write(
          jsonEncode({
            'data': page,
            'cursor': {
              'next': offset + limit < historyMessages.length
                  ? '${offset + limit}'
                  : null,
              'previous': null,
            },
          }),
        );
      } else if (path == '/api/session/ses_1/permission' &&
          req.method == 'GET') {
        resp.write(jsonEncode({'data': pendingPerms}));
      } else if (path == '/api/session/ses_1/prompt' && req.method == 'POST') {
        final body = await utf8.decodeStream(req);
        promptBodies.add(jsonDecode(body) as Map<String, Object?>);
        resp.write(jsonEncode({'data': {}}));
      } else if (path.startsWith('/api/session/ses_1/permission/') &&
          path.endsWith('/reply') &&
          req.method == 'POST') {
        final body = await utf8.decodeStream(req);
        replyBodies.add(jsonDecode(body) as Map<String, Object?>);
        repliedRequestIDs.add(
          path.substring(
            '/api/session/ses_1/permission/'.length,
            path.length - '/reply'.length,
          ),
        );
        resp.statusCode = HttpStatus.noContent;
      } else if (path == '/api/session/ses_1' && req.method == 'GET') {
        resp.write(jsonEncode({'data': detailInfo}));
      } else if (path == '/api/session/ses_2' && req.method == 'GET') {
        resp.write(jsonEncode({'data': detailInfo2}));
      } else if (path == '/api/model') {
        resp.write(jsonEncode({'data': modelRegistry}));
      } else if (path.startsWith('/api/session/') && req.method == 'DELETE') {
        resp.statusCode = HttpStatus.noContent;
      } else {
        resp.statusCode = HttpStatus.notFound;
      }
      await resp.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  group('OpencodeHttpService', () {
    test(
      'listSessions paginates through every page, service order kept',
      () async {
        final service = OpencodeHttpService(baseUrl: base, password: password);
        final list = await service.listSessions();
        expect(list.map((s) => s.id).toList(), ['ses_3', 'ses_2', 'ses_1']);
        expect(list.first.id, 'ses_3');
        expect(list.first.title, 'c');
        expect(list.first.projectId, 'p2');
        expect(list.first.created, 300);
        expect(list.first.location, '/c');
      },
    );

    test('projectNames derives names from canonical when absent', () async {
      final service = OpencodeHttpService(baseUrl: base, password: password);
      expect(await service.projectNames(), {'p1': 'one', 'p2': 'Two'});
    });

    test('projects returns id, display name, and canonical', () async {
      final service = OpencodeHttpService(baseUrl: base, password: password);
      final list = await service.projects();
      expect(list.map((p) => p.id).toList(), ['p1', 'p2']);
      expect(list.map((p) => p.name).toList(), ['one', 'Two']);
      expect(list.map((p) => p.canonical).toList(), ['/proj/one', '/proj/two']);
    });

    test(
      'createSession posts the project canonical as the session location',
      () async {
        final service = OpencodeHttpService(baseUrl: base, password: password);
        final session = await service.createSession('p2');
        expect(session.id, 'ses_new');
        expect(session.title, 'new');
        expect(session.projectId, 'p2');
        expect(session.created, 400);
        expect(session.location, '/proj/two');
      },
    );

    test('createSession of an unknown project is a 404', () async {
      final service = OpencodeHttpService(baseUrl: base, password: password);
      await expectLater(
        service.createSession('p_missing'),
        throwsA(
          isA<OpencodeServiceError>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });

    test('activeSessionIds returns the active set', () async {
      final service = OpencodeHttpService(baseUrl: base, password: password);
      expect(await service.activeSessionIds(), {'ses_2'});
    });

    test('deleteSession issues a DELETE and accepts 204', () async {
      final service = OpencodeHttpService(baseUrl: base, password: password);
      await service.deleteSession('ses_1'); // no throw on 204
    });

    test(
      'getDetail flattens the service Session.Info into the contract',
      () async {
        final service = OpencodeHttpService(baseUrl: base, password: password);
        final detail = await service.getDetail('ses_1');
        expect(detail.id, 'ses_1');
        expect(detail.title, 'one');
        expect(detail.location, '/one');
        expect(detail.cost, 1.5);
        expect(detail.outcome, 'succeeded');
        expect(
          detail.tokens,
          const TokenUsage(
            input: 100,
            output: 50,
            reasoning: 5,
            cacheRead: 10,
            cacheWrite: 2,
          ),
        );
      },
    );

    test(
      'getDetail resolves the context limit from the model registry',
      () async {
        final service = OpencodeHttpService(baseUrl: base, password: password);
        final detail = await service.getDetail('ses_1');
        expect(detail.contextLimit, 123456);
      },
    );

    test('getDetail carries no context limit for a model the registry does '
        'not know', () async {
      final service = OpencodeHttpService(baseUrl: base, password: password);
      final detail = await service.getDetail('ses_2');
      expect(detail.id, 'ses_2');
      expect(detail.contextLimit, isNull);
    });

    test('getDetail of an unknown session is a 404', () async {
      final service = OpencodeHttpService(baseUrl: base, password: password);
      await expectLater(
        service.getDetail('ses_missing'),
        throwsA(
          isA<OpencodeServiceError>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });

    test(
      'getMessages walks the paginated history and maps the turns',
      () async {
        final service = OpencodeHttpService(baseUrl: base, password: password);
        final messages = await service.getMessages('ses_1');
        // The 200 synthetic fillers are skipped, leaving the two turns,
        // back in chronological order despite the newest-first pages.
        expect(messages, hasLength(2));
        expect(
          messages[0],
          const SessionMessage(id: 'm1', role: 'user', text: 'do the thing'),
        );
        final assistant = messages[1];
        expect(assistant.id, 'm2');
        expect(assistant.role, 'assistant');
        expect(assistant.text, 'working');
        expect(assistant.reasoning, 'hmm');
        expect(assistant.tools, hasLength(2));
        // The tool input is a map, so compare fields (deep) not by ==.
        expect(assistant.tools[0].id, 't1');
        expect(assistant.tools[0].name, 'bash');
        expect(assistant.tools[0].status, 'running');
        expect(assistant.tools[0].input, {'command': 'ls'});
        expect(assistant.tools[0].error, isNull);
        expect(assistant.tools[1].id, 't2');
        expect(assistant.tools[1].name, 'write');
        expect(assistant.tools[1].status, 'error');
        expect(assistant.tools[1].error, 'denied');
        // The context gauge: the model call's total input (100 + 5000 + 10).
        expect(assistant.contextTokens, 5110);
        // The client walked the pages: a full first page, then the rest.
        expect(messageOffsets, [0, 200]);
      },
    );

    test('prompt posts the text with delivery steer', () async {
      final service = OpencodeHttpService(baseUrl: base, password: password);
      await service.prompt('ses_1', 'hello');
      expect(promptBodies, [
        {'text': 'hello', 'delivery': 'steer'},
      ]);
    });

    test('pendingPermissions maps the service requests', () async {
      final service = OpencodeHttpService(baseUrl: base, password: password);
      final perms = await service.pendingPermissions('ses_1');
      expect(perms, [
        const PermissionRequest(
          id: 'per_1',
          action: 'shell',
          resources: ['ls'],
        ),
      ]);
    });

    test('replyPermission posts the decision and accepts 204', () async {
      final service = OpencodeHttpService(baseUrl: base, password: password);
      await service.replyPermission('ses_1', 'per_1', PermissionReply.always);
      expect(replyBodies, [
        {'decision': 'always'},
      ]);
      expect(repliedRequestIDs, ['per_1']);
    });

    test('a bad password surfaces a 401 OpencodeServiceError', () async {
      final bad = OpencodeHttpService(baseUrl: base, password: 'wrong');
      await expectLater(
        bad.activeSessionIds(),
        throwsA(
          isA<OpencodeServiceError>().having(
            (e) => e.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
    });

    test('an unreachable service surfaces a 0-status error', () async {
      // A port nothing listens on.
      final dead = OpencodeHttpService(
        baseUrl: Uri.parse('http://127.0.0.1:1/'),
        password: password,
      );
      await expectLater(
        dead.activeSessionIds(),
        throwsA(
          isA<OpencodeServiceError>().having(
            (e) => e.statusCode,
            'statusCode',
            0,
          ),
        ),
      );
    });

    test('fromHost reads url + password from the descriptor', () async {
      final dir = await Directory.systemTemp.createTemp('opencode-service');
      final file = File('${dir.path}/service.json');
      await file.writeAsString(
        jsonEncode({
          'url': base.toString(),
          'password': password,
          'pid': 1,
          'id': 'x',
        }),
      );
      try {
        final fromHost = await OpencodeHttpService.fromHost(
          statePath: file.path,
        );
        expect((await fromHost.listSessions()).length, allSessions.length);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
