import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/sessions_client.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/model/project.dart';
import 'package:opencodebridge/model/session.dart';
import 'package:opencodebridge/model/session_detail.dart';

void main() {
  late HttpServer server;
  late Uri base;
  late List<String> deletedPaths;
  late List<String> createdBodies;
  late List<String> windowPaths;
  late List<String> promptBodies;
  late List<String> replyBodies;
  late SessionsClient client;

  var failList = false;
  var failDelete = false;
  var failProjects = false;
  var failDetail = false;

  setUp(() async {
    deletedPaths = [];
    createdBodies = [];
    windowPaths = [];
    promptBodies = [];
    replyBodies = [];
    failList = false;
    failDelete = false;
    failProjects = false;
    failDetail = false;
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((request) async {
      final response = request.response;
      response.headers.contentType = ContentType.json;
      if (request.method == 'GET' && request.uri.path == '/api/sessions') {
        if (failList) {
          response.statusCode = HttpStatus.badGateway;
          response.write(jsonEncode({'error': 'opencode_unreachable'}));
        } else {
          response.statusCode = HttpStatus.ok;
          response.write(
            jsonEncode([
              {
                'id': 'ses_1',
                'title': 'one',
                'project': {'id': 'p1', 'name': 'proj-one'},
                'created': 100,
                'location': '/one',
                'active': true,
                'classification': 'app-launched-live',
              },
              {
                'id': 'ses_2',
                'title': 'two',
                'project': {'id': 'p2', 'name': 'proj-two'},
                'created': 200,
                'location': '/two',
                'active': false,
                'classification': 'external',
              },
            ]),
          );
        }
      } else if (request.method == 'DELETE' &&
          request.uri.path.startsWith('/api/sessions/')) {
        final id = request.uri.path.substring('/api/sessions/'.length);
        if (failDelete || id == 'ses_missing') {
          response.statusCode = id == 'ses_missing'
              ? HttpStatus.notFound
              : HttpStatus.badGateway;
          response.write(jsonEncode({'error': 'nope'}));
        } else {
          deletedPaths.add(id);
          response.statusCode = HttpStatus.noContent;
        }
      } else if (request.method == 'GET' &&
          request.uri.path == '/api/projects') {
        if (failProjects) {
          response.statusCode = HttpStatus.badGateway;
          response.write(jsonEncode({'error': 'opencode_unreachable'}));
        } else {
          response.statusCode = HttpStatus.ok;
          response.write(
            jsonEncode([
              {'id': 'p1', 'name': 'proj-one', 'canonical': '/proj/one'},
              {'id': 'p2', 'name': 'proj-two', 'canonical': '/proj/two'},
            ]),
          );
        }
      } else if (request.method == 'POST' &&
          request.uri.path == '/api/sessions') {
        final raw = await utf8.decodeStream(request);
        String? project;
        try {
          final decoded = jsonDecode(raw);
          project = decoded is Map<String, Object?>
              ? decoded['project'] as String?
              : null;
        } catch (_) {
          project = null;
        }
        if (project == 'p1') {
          createdBodies.add(raw);
          response.statusCode = HttpStatus.created;
          response.write(
            jsonEncode({
              'id': 'ses_created',
              'title': 'created',
              'project': {'id': 'p1', 'name': 'proj-one'},
              'created': 400,
              'location': '/created',
              'active': false,
              'classification': 'app-launched-live',
            }),
          );
        } else if (project == 'p_missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else {
          response.statusCode = HttpStatus.badRequest;
          response.write(jsonEncode({'error': 'invalid_body'}));
        }
      } else if (request.method == 'POST' &&
          request.uri.path.endsWith('/window')) {
        final id = request.uri.path.substring(
          '/api/sessions/'.length,
          request.uri.path.length - '/window'.length,
        );
        if (id == 'ses_missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else {
          windowPaths.add(id);
          response.statusCode = HttpStatus.noContent;
        }
      } else if (request.method == 'GET' &&
          request.uri.path == '/api/sessions/ses_1') {
        if (failDetail) {
          response.statusCode = HttpStatus.badGateway;
          response.write(jsonEncode({'error': 'opencode_unreachable'}));
        } else {
          response.statusCode = HttpStatus.ok;
          response.write(
            jsonEncode({
              'id': 'ses_1',
              'title': 'one',
              'location': '/one',
              'cost': 0.01,
              'tokens': {
                'input': 100,
                'output': 200,
                'reasoning': 30,
                'cacheRead': 10,
                'cacheWrite': 5,
              },
              'outcome': null,
            }),
          );
        }
      } else if (request.method == 'GET' &&
          request.uri.path == '/api/sessions/ses_missing') {
        response.statusCode = HttpStatus.notFound;
        response.write(jsonEncode({'error': 'not_found'}));
      } else if (request.method == 'GET' &&
          request.uri.path.endsWith('/messages')) {
        final id = request.uri.path.substring(
          '/api/sessions/'.length,
          request.uri.path.length - '/messages'.length,
        );
        if (id == 'ses_missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else {
          response.statusCode = HttpStatus.ok;
          response.write(
            jsonEncode([
              {'role': 'user', 'text': 'do the thing', 'tools': <Object>[]},
              {
                'role': 'assistant',
                'text': null,
                'tools': [
                  {
                    'name': 'shell',
                    'status': 'running',
                    'input': {'command': 'ls'},
                    'error': null,
                  },
                  {
                    'name': 'read',
                    'status': 'error',
                    'input': {'path': '/x'},
                    'error': 'nope',
                  },
                ],
              },
              {'role': 'assistant', 'text': 'done', 'tools': <Object>[]},
            ]),
          );
        }
      } else if (request.method == 'POST' &&
          request.uri.path.endsWith('/messages')) {
        final raw = await utf8.decodeStream(request);
        final id = request.uri.path.substring(
          '/api/sessions/'.length,
          request.uri.path.length - '/messages'.length,
        );
        String? text;
        try {
          final decoded = jsonDecode(raw);
          text = decoded is Map<String, Object?>
              ? decoded['text'] as String?
              : null;
        } catch (_) {
          text = null;
        }
        if (id == 'ses_missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else if (text == null || text.trim().isEmpty) {
          response.statusCode = HttpStatus.badRequest;
          response.write(jsonEncode({'error': 'invalid_body'}));
        } else {
          promptBodies.add(raw);
          response.statusCode = HttpStatus.accepted;
        }
      } else if (request.method == 'GET' &&
          request.uri.path.endsWith('/permissions')) {
        final id = request.uri.path.substring(
          '/api/sessions/'.length,
          request.uri.path.length - '/permissions'.length,
        );
        if (id == 'ses_missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else {
          response.statusCode = HttpStatus.ok;
          response.write(
            jsonEncode([
              {
                'id': 'req_1',
                'action': 'shell',
                'resources': ['ls -la'],
              },
              {
                'id': 'req_2',
                'action': 'edit',
                'resources': ['lib/x.dart'],
              },
            ]),
          );
        }
      } else if (request.method == 'POST' &&
          request.uri.path.contains('/permissions/') &&
          request.uri.path.endsWith('/reply')) {
        final raw = await utf8.decodeStream(request);
        final requestID = request.uri.path
            .substring(
              request.uri.path.indexOf('/permissions/') +
                  '/permissions/'.length,
            )
            .split('/')
            .first;
        String? reply;
        try {
          final decoded = jsonDecode(raw);
          reply = decoded is Map<String, Object?>
              ? decoded['reply'] as String?
              : null;
        } catch (_) {
          reply = null;
        }
        if (requestID == 'req_missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else if (reply != 'once' && reply != 'always' && reply != 'reject') {
          response.statusCode = HttpStatus.badRequest;
          response.write(jsonEncode({'error': 'invalid_body'}));
        } else {
          replyBodies.add(raw);
          response.statusCode = HttpStatus.noContent;
        }
      } else {
        response.statusCode = HttpStatus.notFound;
        response.write(jsonEncode({'error': 'not_found'}));
      }
      response.close();
    });
    base = Uri.parse('http://127.0.0.1:${server.port}/');
    client = SessionsClient(base);
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('list parses the rows into Session objects', () async {
    final rows = await client.list();
    expect(rows, [
      const Session(
        id: 'ses_1',
        title: 'one',
        project: SessionProject(id: 'p1', name: 'proj-one'),
        created: 100,
        location: '/one',
        active: true,
        classification: SessionClassification.appLaunchedLive,
      ),
      const Session(
        id: 'ses_2',
        title: 'two',
        project: SessionProject(id: 'p2', name: 'proj-two'),
        created: 200,
        location: '/two',
        active: false,
        classification: SessionClassification.external,
      ),
    ]);
  });

  test('list maps a non-200 to SessionsClientError with the status', () async {
    failList = true;
    try {
      await client.list();
      fail('expected SessionsClientError');
    } on SessionsClientError catch (e) {
      expect(e.statusCode, HttpStatus.badGateway);
    }
  });

  test('delete hits DELETE /api/sessions/{id} and accepts 204', () async {
    await client.delete('ses_2');
    expect(deletedPaths, ['ses_2']);
  });

  test('delete maps the bridge 404 to SessionsClientError(404)', () async {
    try {
      await client.delete('ses_missing');
      fail('expected SessionsClientError');
    } on SessionsClientError catch (e) {
      expect(e.statusCode, HttpStatus.notFound);
    }
  });

  test('projects parses the rows into Project objects', () async {
    final rows = await client.projects();
    expect(rows, [
      const Project(id: 'p1', name: 'proj-one', canonical: '/proj/one'),
      const Project(id: 'p2', name: 'proj-two', canonical: '/proj/two'),
    ]);
  });

  test(
    'projects maps a non-200 to SessionsClientError with the status',
    () async {
      failProjects = true;
      try {
        await client.projects();
        fail('expected SessionsClientError');
      } on SessionsClientError catch (e) {
        expect(e.statusCode, HttpStatus.badGateway);
      }
    },
  );

  test(
    'create posts only the project id and parses the returned row',
    () async {
      final row = await client.create('p1');
      expect(createdBodies, [
        jsonEncode({'project': 'p1'}),
      ]);
      expect(
        row,
        const Session(
          id: 'ses_created',
          title: 'created',
          project: SessionProject(id: 'p1', name: 'proj-one'),
          created: 400,
          location: '/created',
          active: false,
          classification: SessionClassification.appLaunchedLive,
        ),
      );
    },
  );

  test('create maps the bridge 404 to SessionsClientError(404)', () async {
    try {
      await client.create('p_missing');
      fail('expected SessionsClientError');
    } on SessionsClientError catch (e) {
      expect(e.statusCode, HttpStatus.notFound);
    }
  });

  test(
    'openWindow posts to /api/sessions/{id}/window and accepts 204',
    () async {
      await client.openWindow('ses_2');
      expect(windowPaths, ['ses_2']);
    },
  );

  test('openWindow maps the bridge 404 to SessionsClientError(404)', () async {
    try {
      await client.openWindow('ses_missing');
      fail('expected SessionsClientError');
    } on SessionsClientError catch (e) {
      expect(e.statusCode, HttpStatus.notFound);
    }
  });

  test('an unreachable bridge is SessionsClientError(0)', () async {
    final unreachable = SessionsClient(Uri.parse('http://127.0.0.1:1/'));
    try {
      await unreachable.list();
      fail('expected SessionsClientError');
    } on SessionsClientError catch (e) {
      expect(e.statusCode, 0);
    }
  });

  test('getDetail parses the row into a SessionDetail', () async {
    final detail = await client.getDetail('ses_1');
    expect(
      detail,
      const SessionDetail(
        id: 'ses_1',
        title: 'one',
        location: '/one',
        cost: 0.01,
        tokens: TokenUsage(
          input: 100,
          output: 200,
          reasoning: 30,
          cacheRead: 10,
          cacheWrite: 5,
        ),
        outcome: null,
      ),
    );
  });

  test('getDetail maps the bridge 404 to SessionsClientError(404)', () async {
    try {
      await client.getDetail('ses_missing');
      fail('expected SessionsClientError');
    } on SessionsClientError catch (e) {
      expect(e.statusCode, HttpStatus.notFound);
    }
  });

  test(
    'getDetail maps a non-200 to SessionsClientError with the status',
    () async {
      failDetail = true;
      try {
        await client.getDetail('ses_1');
        fail('expected SessionsClientError');
      } on SessionsClientError catch (e) {
        expect(e.statusCode, HttpStatus.badGateway);
      }
    },
  );

  test('getMessages parses the history with the tools in flight', () async {
    final messages = await client.getMessages('ses_1');
    expect(messages.length, 3);
    expect(
      messages.first,
      const SessionMessage(role: 'user', text: 'do the thing'),
    );
    expect(messages[1].role, 'assistant');
    expect(messages[1].text, isNull);
    expect(messages[1].tools.length, 2);
    expect(messages[1].tools.first.name, 'shell');
    expect(messages[1].tools.first.status, 'running');
    expect(messages[1].tools.first.input, {'command': 'ls'});
    expect(messages[1].tools.first.error, isNull);
    expect(messages[1].tools.last.name, 'read');
    expect(messages[1].tools.last.status, 'error');
    expect(messages[1].tools.last.input, {'path': '/x'});
    expect(messages[1].tools.last.error, 'nope');
    expect(
      messages.last,
      const SessionMessage(role: 'assistant', text: 'done'),
    );
  });

  test('getMessages maps the bridge 404 to SessionsClientError(404)', () async {
    try {
      await client.getMessages('ses_missing');
      fail('expected SessionsClientError');
    } on SessionsClientError catch (e) {
      expect(e.statusCode, HttpStatus.notFound);
    }
  });

  test('prompt posts only the text and accepts 202', () async {
    await client.prompt('ses_1', 'keep going');
    expect(promptBodies, [
      jsonEncode({'text': 'keep going'}),
    ]);
  });

  test('prompt maps the bridge 404 to SessionsClientError(404)', () async {
    try {
      await client.prompt('ses_missing', 'keep going');
      fail('expected SessionsClientError');
    } on SessionsClientError catch (e) {
      expect(e.statusCode, HttpStatus.notFound);
    }
  });

  test('getPermissions parses the pending requests', () async {
    expect(await client.getPermissions('ses_1'), const [
      PermissionRequest(id: 'req_1', action: 'shell', resources: ['ls -la']),
      PermissionRequest(id: 'req_2', action: 'edit', resources: ['lib/x.dart']),
    ]);
  });

  test(
    'getPermissions maps the bridge 404 to SessionsClientError(404)',
    () async {
      try {
        await client.getPermissions('ses_missing');
        fail('expected SessionsClientError');
      } on SessionsClientError catch (e) {
        expect(e.statusCode, HttpStatus.notFound);
      }
    },
  );

  test('replyPermission posts the wire value and accepts 204', () async {
    await client.replyPermission('ses_1', 'req_1', PermissionReply.once);
    await client.replyPermission('ses_1', 'req_1', PermissionReply.always);
    await client.replyPermission('ses_1', 'req_1', PermissionReply.reject);
    expect(replyBodies, [
      jsonEncode({'reply': 'once'}),
      jsonEncode({'reply': 'always'}),
      jsonEncode({'reply': 'reject'}),
    ]);
  });

  test(
    'replyPermission maps an unknown request to SessionsClientError(404)',
    () async {
      try {
        await client.replyPermission(
          'ses_1',
          'req_missing',
          PermissionReply.once,
        );
        fail('expected SessionsClientError');
      } on SessionsClientError catch (e) {
        expect(e.statusCode, HttpStatus.notFound);
      }
    },
  );
}
