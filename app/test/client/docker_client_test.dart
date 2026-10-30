import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/docker_client.dart';
import 'package:opencodebridge/model/compose_project.dart';
import 'package:opencodebridge/model/container.dart';

void main() {
  late HttpServer server;
  late Uri base;
  late DockerClient client;
  late List<String?> followQueries;
  late List<(String, String)> actions;
  late List<String> logNames;
  late List<(String, String, String?)> composeActions;

  setUp(() async {
    followQueries = [];
    actions = [];
    logNames = [];
    composeActions = [];
    server = await HttpServer.bind('127.0.0.1', 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    client = DockerClient(base);
    server.listen((request) async {
      final response = request.response;
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/api/docker/containers') {
        response.headers.contentType = ContentType.json;
        response.statusCode = HttpStatus.ok;
        response.write(
          jsonEncode([
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
          ]),
        );
        await response.close();
        return;
      }
      if (request.method == 'POST' &&
          path.startsWith('/api/docker/containers/') &&
          path.endsWith('/action')) {
        final name = path.substring(
          '/api/docker/containers/'.length,
          path.length - '/action'.length,
        );
        final raw = await utf8.decodeStream(request);
        String? action;
        try {
          final decoded = jsonDecode(raw);
          action = decoded is Map<String, Object?>
              ? decoded['action'] as String?
              : null;
        } catch (_) {}
        response.headers.contentType = ContentType.json;
        if (name == 'missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else if (action == null ||
            !{'start', 'stop', 'restart'}.contains(action)) {
          response.statusCode = HttpStatus.badRequest;
          response.write(jsonEncode({'error': 'invalid_body'}));
        } else {
          actions.add((name, action));
          response.statusCode = HttpStatus.ok;
          response.write(jsonEncode({'name': name}));
        }
        await response.close();
        return;
      }
      if (request.method == 'GET' &&
          path.startsWith('/api/docker/containers/') &&
          path.endsWith('/logs')) {
        final name = path.substring(
          '/api/docker/containers/'.length,
          path.length - '/logs'.length,
        );
        final follow = request.uri.queryParameters['follow'];
        logNames.add(name);
        followQueries.add(follow);
        if (name == 'missing') {
          response.headers.contentType = ContentType.json;
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
          await response.close();
          return;
        }
        response.headers.contentType = ContentType.parse(
          'text/event-stream; charset=utf-8',
        );
        response.statusCode = HttpStatus.ok;
        response.write('data: alpha\n\n');
        response.write('data: beta\n\n');
        await response.close();
        return;
      }
      if (request.method == 'GET' && path == '/api/docker/compose') {
        response.headers.contentType = ContentType.json;
        response.statusCode = HttpStatus.ok;
        response.write(
          jsonEncode([
            {
              'id': Uri.encodeComponent('/repos/proj'),
              'project': 'proj',
              'path': '/repos/proj',
              'composeFile': '/repos/proj/docker-compose.yml',
              'services': [
                {
                  'name': 'web',
                  'state': 'running',
                  'image': 'nginx:latest',
                  'container': 'proj-web-1',
                },
                {'name': 'db', 'state': null, 'image': null, 'container': null},
              ],
            },
          ]),
        );
        await response.close();
        return;
      }
      if (request.method == 'POST' &&
          path.startsWith('/api/docker/compose/') &&
          path.endsWith('/action')) {
        final id = path.substring(
          '/api/docker/compose/'.length,
          path.length - '/action'.length,
        );
        final raw = await utf8.decodeStream(request);
        String? action;
        String? service;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, Object?>) {
            action = decoded['action'] as String?;
            service = decoded['service'] as String?;
          }
        } catch (_) {}
        response.headers.contentType = ContentType.json;
        if (action == null || !{'up', 'stop'}.contains(action)) {
          response.statusCode = HttpStatus.badRequest;
          response.write(jsonEncode({'error': 'invalid_body'}));
        } else {
          composeActions.add((Uri.decodeComponent(id), action, service));
          response.statusCode = HttpStatus.ok;
          response.write(jsonEncode({'path': Uri.decodeComponent(id)}));
        }
        await response.close();
        return;
      }
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({'error': 'not_found'}));
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  group('DockerClient', () {
    test('list decodes the container rows', () async {
      final rows = await client.list();
      expect(rows, [
        const DockerContainer(
          name: 'web',
          image: 'nginx:latest',
          state: DockerState.running,
          uptime: '2 hours ago',
        ),
        const DockerContainer(
          name: 'db',
          image: 'postgres:16',
          state: DockerState.exited,
          uptime: null,
        ),
      ]);
    });

    test('list throws DockerClientError with the bridge status', () async {
      final failing = await HttpServer.bind('127.0.0.1', 0);
      try {
        failing.listen((request) async {
          request.response.statusCode = HttpStatus.serviceUnavailable;
          request.response.write(jsonEncode({'error': 'docker_unavailable'}));
          await request.response.close();
        });
        await expectLater(
          DockerClient(Uri.parse('http://127.0.0.1:${failing.port}')).list(),
          throwsA(
            isA<DockerClientError>().having(
              (e) => e.statusCode,
              'statusCode',
              HttpStatus.serviceUnavailable,
            ),
          ),
        );
      } finally {
        await failing.close(force: true);
      }
    });

    test('action posts the wire action for the container name', () async {
      await client.action('web', DockerAction.start);
      await client.action('web', DockerAction.stop);
      await client.action('web', DockerAction.restart);
      expect(actions, [('web', 'start'), ('web', 'stop'), ('web', 'restart')]);
    });

    test('action throws DockerClientError with the bridge status', () async {
      await expectLater(
        client.action('missing', DockerAction.start),
        throwsA(
          isA<DockerClientError>().having(
            (e) => e.statusCode,
            'statusCode',
            HttpStatus.notFound,
          ),
        ),
      );
    });

    test(
      'logs streams the data payloads and sends follow=1 by default',
      () async {
        final lines = <String>[];
        await for (final line in client.logs('web')) {
          lines.add(line);
        }
        expect(lines, ['alpha', 'beta']);
        expect(logNames, ['web']);
        expect(followQueries, ['1']);
      },
    );

    test('logs with follow: false omits the follow parameter', () async {
      final lines = <String>[];
      await for (final line in client.logs('web', follow: false)) {
        lines.add(line);
      }
      expect(lines, ['alpha', 'beta']);
      expect(followQueries, [null]);
    });

    test('logs errors surface as DockerClientError', () async {
      await expectLater(
        client.logs('missing').first,
        throwsA(
          isA<DockerClientError>().having(
            (e) => e.statusCode,
            'statusCode',
            HttpStatus.notFound,
          ),
        ),
      );
    });
  });

  group('DockerClient compose', () {
    test('compose decodes the project rows', () async {
      final projects = await client.compose();
      expect(projects, [
        ComposeProject(
          id: Uri.encodeComponent('/repos/proj'),
          project: 'proj',
          path: '/repos/proj',
          composeFile: '/repos/proj/docker-compose.yml',
          services: [
            const ComposeService(
              name: 'web',
              state: DockerState.running,
              image: 'nginx:latest',
              container: 'proj-web-1',
            ),
            const ComposeService(name: 'db', state: null),
          ],
        ),
      ]);
    });

    test('composeAction posts the wire action for the whole project', () async {
      await client.composeAction(
        Uri.encodeComponent('/repos/proj'),
        ComposeAction.up,
      );
      expect(composeActions, [('/repos/proj', 'up', null)]);
    });

    test('composeAction posts the service when one is given', () async {
      await client.composeAction(
        Uri.encodeComponent('/repos/proj'),
        ComposeAction.stop,
        service: 'db',
      );
      expect(composeActions, [('/repos/proj', 'stop', 'db')]);
    });

    test('compose throws DockerClientError with the bridge status', () async {
      final failing = await HttpServer.bind('127.0.0.1', 0);
      try {
        failing.listen((request) async {
          request.response.statusCode = HttpStatus.serviceUnavailable;
          request.response.write(jsonEncode({'error': 'docker_unavailable'}));
          await request.response.close();
        });
        await expectLater(
          DockerClient(Uri.parse('http://127.0.0.1:${failing.port}')).compose(),
          throwsA(
            isA<DockerClientError>().having(
              (e) => e.statusCode,
              'statusCode',
              HttpStatus.serviceUnavailable,
            ),
          ),
        );
      } finally {
        await failing.close(force: true);
      }
    });

    test(
      'composeAction throws DockerClientError with the bridge status',
      () async {
        final failing = await HttpServer.bind('127.0.0.1', 0);
        try {
          failing.listen((request) async {
            request.response.statusCode = HttpStatus.notFound;
            request.response.write(jsonEncode({'error': 'not_found'}));
            await request.response.close();
          });
          await expectLater(
            DockerClient(Uri.parse('http://127.0.0.1:${failing.port}'))
                .composeAction(
                  Uri.encodeComponent('/repos/proj'),
                  ComposeAction.up,
                ),
            throwsA(
              isA<DockerClientError>().having(
                (e) => e.statusCode,
                'statusCode',
                HttpStatus.notFound,
              ),
            ),
          );
        } finally {
          await failing.close(force: true);
        }
      },
    );
  });
}
