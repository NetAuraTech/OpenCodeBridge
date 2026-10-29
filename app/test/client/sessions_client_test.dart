import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/sessions_client.dart';
import 'package:opencodebridge/model/project.dart';
import 'package:opencodebridge/model/session.dart';

void main() {
  late HttpServer server;
  late Uri base;
  late List<String> deletedPaths;
  late List<String> createdBodies;
  late List<String> windowPaths;
  late SessionsClient client;

  var failList = false;
  var failDelete = false;
  var failProjects = false;

  setUp(() async {
    deletedPaths = [];
    createdBodies = [];
    windowPaths = [];
    failList = false;
    failDelete = false;
    failProjects = false;
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
}
