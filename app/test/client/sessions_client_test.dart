import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/sessions_client.dart';
import 'package:opencodebridge/model/command.dart';
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
  // The `/` command menu (issue #46) recordings.
  late List<String> commandBodies;
  late List<String> setModelBodies;
  late List<String> setAgentBodies;
  late List<String> renameBodies;
  late List<String> moveBodies;
  late List<String> btwBodies;
  late List<String> connectBodies;
  late List<String> worktreesQueries;
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
    commandBodies = [];
    setModelBodies = [];
    setAgentBodies = [];
    renameBodies = [];
    moveBodies = [];
    btwBodies = [];
    connectBodies = [];
    worktreesQueries = [];
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
        // The `/` command menu (issue #46) routes, checked before the 404.
      } else if (request.method == 'GET' &&
          request.uri.path.endsWith('/commands')) {
        final id = request.uri.path.substring(
          '/api/sessions/'.length,
          request.uri.path.length - '/commands'.length,
        );
        if (id == 'ses_missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else {
          response.statusCode = HttpStatus.ok;
          response.write(
            jsonEncode([
              {'name': 'deploy', 'description': 'ship it'},
            ]),
          );
        }
      } else if (request.method == 'POST' &&
          request.uri.path.contains('/commands/')) {
        final raw = await utf8.decodeStream(request);
        final id = request.uri.path.substring(
          '/api/sessions/'.length,
          request.uri.path.indexOf('/commands/'),
        );
        if (id == 'ses_missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else {
          commandBodies.add(raw);
          response.statusCode = HttpStatus.accepted;
        }
      } else if (request.method == 'GET' &&
          request.uri.path.endsWith('/models')) {
        final id = request.uri.path.substring(
          '/api/sessions/'.length,
          request.uri.path.length - '/models'.length,
        );
        if (id == 'ses_missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else {
          response.statusCode = HttpStatus.ok;
          response.write(
            jsonEncode([
              {
                'id': 'm1',
                'providerID': 'prov',
                'name': 'Model One',
                'variants': ['high'],
              },
            ]),
          );
        }
      } else if (request.method == 'GET' &&
          request.uri.path.endsWith('/model')) {
        final id = request.uri.path.substring(
          '/api/sessions/'.length,
          request.uri.path.length - '/model'.length,
        );
        if (id == 'ses_missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else {
          response.statusCode = HttpStatus.ok;
          response.write(
            jsonEncode({
              'model': {'id': 'm1', 'providerID': 'prov'},
            }),
          );
        }
      } else if (request.method == 'POST' &&
          request.uri.path.endsWith('/models')) {
        final raw = await utf8.decodeStream(request);
        final id = request.uri.path.substring(
          '/api/sessions/'.length,
          request.uri.path.length - '/models'.length,
        );
        if (id == 'ses_missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else {
          setModelBodies.add(raw);
          response.statusCode = HttpStatus.noContent;
        }
      } else if (request.method == 'GET' &&
          request.uri.path.endsWith('/agents')) {
        final id = request.uri.path.substring(
          '/api/sessions/'.length,
          request.uri.path.length - '/agents'.length,
        );
        if (id == 'ses_missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else {
          response.statusCode = HttpStatus.ok;
          response.write(
            jsonEncode([
              {'id': 'a1', 'name': 'Agent One', 'description': 'does things'},
            ]),
          );
        }
      } else if (request.method == 'POST' &&
          request.uri.path.endsWith('/agents')) {
        final raw = await utf8.decodeStream(request);
        final id = request.uri.path.substring(
          '/api/sessions/'.length,
          request.uri.path.length - '/agents'.length,
        );
        if (id == 'ses_missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else {
          setAgentBodies.add(raw);
          response.statusCode = HttpStatus.noContent;
        }
      } else if (request.method == 'GET' &&
          request.uri.path.endsWith('/skills')) {
        final id = request.uri.path.substring(
          '/api/sessions/'.length,
          request.uri.path.length - '/skills'.length,
        );
        if (id == 'ses_missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else {
          response.statusCode = HttpStatus.ok;
          response.write(
            jsonEncode([
              {'id': 'sk1', 'name': 'Skill One', 'description': 'a skill'},
            ]),
          );
        }
      } else if (request.method == 'POST' &&
          request.uri.path.contains('/skills/')) {
        final id = request.uri.path.substring(
          '/api/sessions/'.length,
          request.uri.path.indexOf('/skills/'),
        );
        if (id == 'ses_missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else {
          response.statusCode = HttpStatus.noContent;
        }
      } else if (request.method == 'POST' &&
          (request.uri.path.endsWith('/compact') ||
              request.uri.path.endsWith('/undo') ||
              request.uri.path.endsWith('/redo'))) {
        final id = request.uri.path
            .substring('/api/sessions/'.length)
            .split('/')
            .first;
        if (id == 'ses_missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else {
          response.statusCode = HttpStatus.noContent;
        }
      } else if (request.method == 'POST' &&
          request.uri.path.endsWith('/fork')) {
        response.statusCode = HttpStatus.ok;
        response.write(jsonEncode({'id': 'ses_forked'}));
      } else if (request.method == 'POST' &&
          request.uri.path.endsWith('/rename')) {
        final raw = await utf8.decodeStream(request);
        final id = request.uri.path.substring(
          '/api/sessions/'.length,
          request.uri.path.length - '/rename'.length,
        );
        if (id == 'ses_missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else {
          renameBodies.add(raw);
          response.statusCode = HttpStatus.noContent;
        }
      } else if (request.method == 'POST' &&
          request.uri.path.endsWith('/move')) {
        final raw = await utf8.decodeStream(request);
        final id = request.uri.path.substring(
          '/api/sessions/'.length,
          request.uri.path.length - '/move'.length,
        );
        if (id == 'ses_missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else {
          moveBodies.add(raw);
          response.statusCode = HttpStatus.noContent;
        }
      } else if (request.method == 'POST' &&
          request.uri.path.endsWith('/btw')) {
        final raw = await utf8.decodeStream(request);
        final id = request.uri.path.substring(
          '/api/sessions/'.length,
          request.uri.path.length - '/btw'.length,
        );
        if (id == 'ses_missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else {
          btwBodies.add(raw);
          response.statusCode = HttpStatus.ok;
          response.write(jsonEncode({'text': 'the side answer'}));
        }
      } else if (request.method == 'GET' &&
          request.uri.path.endsWith('/export')) {
        response.statusCode = HttpStatus.ok;
        response.write(jsonEncode('{"info":"export"}'));
      } else if (request.method == 'GET' &&
          request.uri.path.endsWith('/diff')) {
        response.statusCode = HttpStatus.ok;
        response.write(jsonEncode('{"diff":true}'));
      } else if (request.method == 'GET' &&
          request.uri.path.endsWith('/stats')) {
        response.statusCode = HttpStatus.ok;
        response.write(jsonEncode('{"stats":true}'));
      } else if (request.method == 'POST' &&
          request.uri.path.endsWith('/terminal')) {
        response.statusCode = HttpStatus.ok;
        response.write(jsonEncode('{"terminal":true}'));
      } else if (request.method == 'GET' && request.uri.path == '/api/usage') {
        response.statusCode = HttpStatus.ok;
        response.write(jsonEncode('{"usage":true}'));
      } else if (request.method == 'GET' && request.uri.path == '/api/mcp') {
        response.statusCode = HttpStatus.ok;
        response.write(jsonEncode('{"mcps":true}'));
      } else if (request.method == 'GET' &&
          request.uri.path == '/api/plugins') {
        response.statusCode = HttpStatus.ok;
        response.write(jsonEncode('{"plugins":true}'));
      } else if (request.method == 'GET' &&
          request.uri.path == '/api/integrations') {
        response.statusCode = HttpStatus.ok;
        response.write(
          jsonEncode(
            jsonEncode([
              {
                'id': 'gitlab',
                'name': 'GitLab',
                'methods': [
                  {'type': 'oauth', 'id': 'oauth1', 'label': 'OAuth'},
                ],
              },
            ]),
          ),
        );
      } else if (request.method == 'POST' &&
          request.uri.path.contains('/integrations/') &&
          request.uri.path.endsWith('/connect')) {
        final raw = await utf8.decodeStream(request);
        connectBodies.add(raw);
        response.statusCode = HttpStatus.ok;
        response.write(jsonEncode('{"url":"https://auth/callback"}'));
      } else if (request.method == 'GET' && request.uri.path == '/api/status') {
        response.statusCode = HttpStatus.ok;
        response.write(jsonEncode('{"status":true}'));
      } else if (request.method == 'POST' && request.uri.path == '/api/pair') {
        response.statusCode = HttpStatus.ok;
        response.write(jsonEncode('{"pair":true}'));
      } else if (request.method == 'POST' &&
          request.uri.path == '/api/reload') {
        response.statusCode = HttpStatus.noContent;
      } else if (request.method == 'GET' &&
          request.uri.path == '/api/worktrees') {
        worktreesQueries.add(request.uri.queryParameters['sessionID'] ?? '');
        response.statusCode = HttpStatus.ok;
        response.write(jsonEncode('{"worktrees":true}'));
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

  group('`/` command menu (issue #46)', () {
    test('listCommands parses the project commands', () async {
      expect(await client.listCommands('ses_1'), const [
        OpencodeCommand(name: 'deploy', description: 'ship it'),
      ]);
    });

    test('runCommand posts only the text and accepts 202', () async {
      await client.runCommand('ses_1', 'deploy', 'prod');
      expect(commandBodies, [
        jsonEncode({'text': 'prod'}),
      ]);
    });

    test(
      'runCommand maps the bridge 404 to SessionsClientError(404)',
      () async {
        try {
          await client.runCommand('ses_missing', 'deploy', 'prod');
          fail('expected SessionsClientError');
        } on SessionsClientError catch (e) {
          expect(e.statusCode, HttpStatus.notFound);
        }
      },
    );

    test('listModels parses the model registry', () async {
      expect(await client.listModels('ses_1'), const [
        ModelOption(
          id: 'm1',
          providerId: 'prov',
          name: 'Model One',
          variants: ['high'],
        ),
      ]);
    });

    test('currentModel parses the session model ref', () async {
      expect(
        await client.currentModel('ses_1'),
        const ModelRef(id: 'm1', providerId: 'prov'),
      );
    });

    test(
      'setModel posts the model ref (providerID, variant) and accepts 204',
      () async {
        await client.setModel(
          'ses_1',
          const ModelRef(id: 'm2', providerId: 'prov2', variant: 'high'),
        );
        expect(setModelBodies, [
          jsonEncode({
            'model': {'id': 'm2', 'providerID': 'prov2', 'variant': 'high'},
          }),
        ]);
      },
    );

    test('setModel maps the bridge 404 to SessionsClientError(404)', () async {
      try {
        await client.setModel(
          'ses_missing',
          const ModelRef(id: 'm1', providerId: 'prov'),
        );
        fail('expected SessionsClientError');
      } on SessionsClientError catch (e) {
        expect(e.statusCode, HttpStatus.notFound);
      }
    });

    test('listAgents parses the agent registry', () async {
      expect(await client.listAgents('ses_1'), const [
        AgentOption(id: 'a1', name: 'Agent One', description: 'does things'),
      ]);
    });

    test('setAgent posts the agent id and accepts 204', () async {
      await client.setAgent('ses_1', 'a2');
      expect(setAgentBodies, [
        jsonEncode({'agent': 'a2'}),
      ]);
    });

    test('listSkills parses the skill registry', () async {
      expect(await client.listSkills('ses_1'), const [
        SkillOption(id: 'sk1', name: 'Skill One', description: 'a skill'),
      ]);
    });

    test('activateSkill accepts 204', () async {
      await client.activateSkill('ses_1', 'sk2');
    });

    test('compact/undo/redo accept 204', () async {
      await client.compact('ses_1');
      await client.undo('ses_1');
      await client.redo('ses_1');
    });

    test('compact maps the bridge 404 to SessionsClientError(404)', () async {
      try {
        await client.compact('ses_missing');
        fail('expected SessionsClientError');
      } on SessionsClientError catch (e) {
        expect(e.statusCode, HttpStatus.notFound);
      }
    });

    test('fork returns the forked session id', () async {
      expect(await client.fork('ses_1'), 'ses_forked');
    });

    test('rename posts only the title and accepts 204', () async {
      await client.rename('ses_1', 'renamed');
      expect(renameBodies, [
        jsonEncode({'title': 'renamed'}),
      ]);
    });

    test('rename maps the bridge 404 to SessionsClientError(404)', () async {
      try {
        await client.rename('ses_missing', 'renamed');
        fail('expected SessionsClientError');
      } on SessionsClientError catch (e) {
        expect(e.statusCode, HttpStatus.notFound);
      }
    });

    test('move posts only the directory and accepts 204', () async {
      await client.move('ses_1', '/elsewhere');
      expect(moveBodies, [
        jsonEncode({'directory': '/elsewhere'}),
      ]);
    });

    test('the info payloads are returned as their JSON strings', () async {
      expect(await client.exportSession('ses_1'), '{"info":"export"}');
      expect(await client.diff('ses_1'), '{"diff":true}');
      expect(await client.stats('ses_1'), '{"stats":true}');
      expect(await client.newTerminal('ses_1'), '{"terminal":true}');
    });

    test('btw posts the prompt and returns the side answer', () async {
      expect(await client.btw('ses_1', 'why?'), 'the side answer');
      expect(btwBodies, [
        jsonEncode({'prompt': 'why?'}),
      ]);
    });

    test('the global payloads are returned as their JSON strings', () async {
      expect(await client.usage(), '{"usage":true}');
      expect(await client.mcps(), '{"mcps":true}');
      expect(await client.plugins(), '{"plugins":true}');
      expect(await client.status(), '{"status":true}');
      expect(await client.pair(), '{"pair":true}');
    });

    test('integrations returns the payload string', () async {
      final payload = await client.integrations();
      expect(jsonDecode(payload), [
        {
          'id': 'gitlab',
          'name': 'GitLab',
          'methods': [
            {'type': 'oauth', 'id': 'oauth1', 'label': 'OAuth'},
          ],
        },
      ]);
    });

    test(
      'connectIntegration posts the methodID and returns the flow payload',
      () async {
        final payload = await client.connectIntegration('gitlab', 'oauth1');
        expect(payload, '{"url":"https://auth/callback"}');
        expect(connectBodies, [
          jsonEncode({'methodID': 'oauth1'}),
        ]);
      },
    );

    test('reload accepts 204', () async {
      await client.reload();
    });

    test(
      'worktrees sends the session id query and returns the payload',
      () async {
        expect(await client.worktrees('ses_1'), '{"worktrees":true}');
        expect(worktreesQueries, ['ses_1']);
      },
    );
  });
}
