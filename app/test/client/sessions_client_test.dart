import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/sessions_client.dart';
import 'package:opencodebridge/model/session.dart';

void main() {
  late HttpServer server;
  late Uri base;
  late List<String> deletedPaths;
  late SessionsClient client;

  var failList = false;
  var failDelete = false;

  setUp(() async {
    deletedPaths = [];
    failList = false;
    failDelete = false;
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((request) {
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
