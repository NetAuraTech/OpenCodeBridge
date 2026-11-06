import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/orbs_client.dart';
import 'package:opencodebridge/model/orb.dart';

void main() {
  late HttpServer server;
  late Uri base;
  late OrbsClient client;
  late List<String?> prQueries;
  late List<(String, String)> creates;
  late List<String> deleted;
  late List<String> deleteBodies;
  late int rebuildCalls;
  late List<(String, String)> orbActions;

  setUp(() async {
    prQueries = [];
    creates = [];
    deleted = [];
    deleteBodies = [];
    rebuildCalls = 0;
    orbActions = [];
    server = await HttpServer.bind('127.0.0.1', 0);
    base = Uri.parse('http://127.0.0.1:${server.port}/');
    client = OrbsClient(base);
    server.listen((request) async {
      final response = request.response;
      final path = request.uri.path;
      final freshMatch = RegExp(r'^/api/orbs/([^/]+)/fresh-state$')
          .firstMatch(path);
      if (request.method == 'POST' && freshMatch != null) {
        final id = freshMatch.group(1)!;
        orbActions.add((id, 'fresh-state'));
        response.headers.contentType = ContentType.json;
        if (id == 'refused-state') {
          response.statusCode = HttpStatus.badRequest;
          response.write(
            jsonEncode({
              'error': 'not_wakeable',
              'details': 'only a broken orb whose state dir is missing',
            }),
          );
          await response.close();
          return;
        }
        response.statusCode = HttpStatus.ok;
        response.write(
          jsonEncode({
            'id': id,
            'name': 'dev',
            'project': 'p1',
            'branch': 'orb/$id',
            'state': 'running',
            'created': '2025-01-04T00:00:00Z',
            'url': 'http://127.0.0.1:49300',
          }),
        );
        await response.close();
        return;
      }
      if (request.method == 'GET' && path == '/api/orbs') {
        prQueries.add(request.uri.queryParameters['pr']);
        response.headers.contentType = ContentType.json;
        response.statusCode = HttpStatus.ok;
        response.write(
          jsonEncode([
            {
              'id': 'orb_1',
              'name': 'api',
              'project': 'p1',
              'branch': 'orb/orb_1',
              'state': 'running',
              'created': '2025-01-01T00:00:00Z',
              'url': 'http://127.0.0.1:49100',
              'pr': {'state': 'open', 'url': 'https://github.com/o/r/pull/7'},
            },
            {
              'id': 'orb_2',
              'name': 'db',
              'project': 'p1',
              'branch': 'orb/orb_2',
              'state': 'orphan',
              'created': '2025-01-02T00:00:00Z',
            },
          ]),
        );
        await response.close();
        return;
      }
      if (request.method == 'POST' && path == '/api/orbs') {
        final raw = await utf8.decodeStream(request);
        String? project;
        String? name;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, Object?>) {
            project = decoded['project'] as String?;
            name = decoded['name'] as String?;
          }
        } catch (_) {}
        creates.add((project ?? '', name ?? ''));
        response.headers.contentType = ContentType.json;
        if (name == 'taken') {
          response.statusCode = HttpStatus.conflict;
          response.write(jsonEncode({'error': 'name_taken'}));
        } else if (name == 'refused') {
          response.statusCode = HttpStatus.badRequest;
          response.write(
            jsonEncode({'error': 'no_remote', 'details': 'no git remote'}),
          );
        } else if (name == 'failsboot') {
          response.statusCode = HttpStatus.badGateway;
          response.write(
            jsonEncode({
              'error': 'orb_boot_failed',
              'details': 'the container exited',
              'logTail': ['[orb] stage: cloning', 'fatal: bad url'],
            }),
          );
        } else if (name == 'unavailable') {
          response.statusCode = HttpStatus.serviceUnavailable;
          response.write(jsonEncode({'error': 'docker_unavailable'}));
        } else {
          response.statusCode = HttpStatus.created;
          response.write(
            jsonEncode({
              'id': 'orb_9',
              'name': name ?? '',
              'project': project ?? '',
              'branch': 'orb/orb_9',
              'state': 'running',
              'created': '2025-01-03T00:00:00Z',
              'url': 'http://127.0.0.1:49200',
            }),
          );
        }
        await response.close();
        return;
      }
      if (request.method == 'POST' && path == '/api/orb/image/rebuild') {
        rebuildCalls++;
        response.headers.contentType = ContentType.json;
        response.statusCode = HttpStatus.ok;
        response.write(jsonEncode({'tag': 'orb:abc123'}));
        await response.close();
        return;
      }
      if (request.method == 'DELETE' && path.startsWith('/api/orbs/')) {
        final id = path.substring('/api/orbs/'.length);
        final raw = await utf8.decodeStream(request);
        deleteBodies.add(raw);
        response.headers.contentType = ContentType.json;
        if (id == 'missing') {
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode({'error': 'not_found'}));
        } else if (id == 'exists') {
          response.statusCode = HttpStatus.conflict;
          response.write(jsonEncode({'error': 'orb_exists'}));
        } else if (id == 'refused') {
          response.statusCode = HttpStatus.conflict;
          response.write(
            jsonEncode({
              'error': 'deletion_refused',
              'id': 'refused',
              'reasons': ['dirty_tree', 'unpushed_commits'],
              'dirty': ['M src/app.dart'],
              'unpushedCount': 2,
            }),
          );
        } else {
          deleted.add(id);
          response.statusCode = HttpStatus.noContent;
        }
        await response.close();
        return;
      }
      if (request.method == 'POST' && path == '/api/orbs/orb_1/update') {
        response.headers.contentType = ContentType.json;
        response.statusCode = HttpStatus.ok;
        response.write(
          jsonEncode({
            'id': 'orb_1',
            'name': 'api',
            'project': 'p1',
            'branch': 'orb/orb_1',
            'state': 'running',
            'created': '2025-01-01T00:00:00Z',
            'url': 'http://127.0.0.1:49300',
          }),
        );
        await response.close();
        return;
      }
      if (request.method == 'POST' && path == '/api/orbs/busy/update') {
        response.headers.contentType = ContentType.json;
        response.statusCode = HttpStatus.badRequest;
        response.write(
          jsonEncode({
            'error': 'update_busy',
            'details': 'the orb has an active session',
          }),
        );
        await response.close();
        return;
      }
      if (request.method == 'POST' && path == '/api/orbs/failsboot/update') {
        response.headers.contentType = ContentType.json;
        response.statusCode = HttpStatus.badGateway;
        response.write(
          jsonEncode({
            'error': 'orb_boot_failed',
            'details': 'the container exited',
            'logTail': ['[orb] stage: starting', 'fatal: no good'],
          }),
        );
        await response.close();
        return;
      }
      if (request.method == 'POST' && path == '/api/orbs/missing/update') {
        response.headers.contentType = ContentType.json;
        response.statusCode = HttpStatus.notFound;
        response.write(jsonEncode({'error': 'not_found'}));
        await response.close();
        return;
      }
      if (request.method == 'POST' && path == '/api/orbs/orb_1/export') {
        response.headers.contentType = ContentType.json;
        response.statusCode = HttpStatus.ok;
        response.write(
          jsonEncode({'path': '/proj/one/api-orb_1-20250101-000000UTC.tar.gz'}),
        );
        await response.close();
        return;
      }
      if (request.method == 'POST' && path == '/api/orbs/nocheckout/export') {
        response.headers.contentType = ContentType.json;
        response.statusCode = HttpStatus.badRequest;
        response.write(
          jsonEncode({
            'error': 'missing_checkout',
            'details': 'no checkout for the project',
          }),
        );
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

  group('OrbsClient list', () {
    test('decodes the rows, the PR included when served', () async {
      final rows = await client.list(includePr: true);
      expect(rows, [
        const OrbRecord(
          id: 'orb_1',
          name: 'api',
          project: 'p1',
          branch: 'orb/orb_1',
          state: 'running',
          created: '2025-01-01T00:00:00Z',
          url: 'http://127.0.0.1:49100',
          pr: OrbPr(state: 'open', url: 'https://github.com/o/r/pull/7'),
        ),
        const OrbRecord(
          id: 'orb_2',
          name: 'db',
          project: 'p1',
          branch: 'orb/orb_2',
          state: 'orphan',
          created: '2025-01-02T00:00:00Z',
        ),
      ]);
    });

    test('sends pr=1 only when the caller asks for the enrichment', () async {
      await client.list();
      await client.list(includePr: true);
      expect(prQueries, [null, '1']);
    });

    test('throws OrbsClientError with the bridge status', () async {
      final failing = await HttpServer.bind('127.0.0.1', 0);
      try {
        failing.listen((request) async {
          request.response.statusCode = HttpStatus.serviceUnavailable;
          request.response.write(jsonEncode({'error': 'docker_unavailable'}));
          await request.response.close();
        });
        await expectLater(
          OrbsClient(Uri.parse('http://127.0.0.1:${failing.port}/')).list(),
          throwsA(
            isA<OrbsClientError>().having(
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
  });

  group('OrbsClient create', () {
    test('posts the project and name and decodes the 201 record', () async {
      final record = await client.create('p1', 'api');
      expect(
        record,
        const OrbRecord(
          id: 'orb_9',
          name: 'api',
          project: 'p1',
          branch: 'orb/orb_9',
          state: 'running',
          created: '2025-01-03T00:00:00Z',
          url: 'http://127.0.0.1:49200',
        ),
      );
      expect(creates, [('p1', 'api')]);
    });

    test('decodes the name_taken conflict', () async {
      await expectLater(
        client.create('p1', 'taken'),
        throwsA(
          isA<OrbCreateError>()
              .having((e) => e.statusCode, 'statusCode', HttpStatus.conflict)
              .having((e) => e.code, 'code', OrbCreateError.nameTaken),
        ),
      );
    });

    test('decodes the up-front refusal with its details', () async {
      await expectLater(
        client.create('p1', 'refused'),
        throwsA(
          isA<OrbCreateError>()
              .having((e) => e.statusCode, 'statusCode', HttpStatus.badRequest)
              .having((e) => e.code, 'code', 'no_remote')
              .having((e) => e.details, 'details', 'no git remote'),
        ),
      );
    });

    test('decodes the failed boot with its log tail', () async {
      await expectLater(
        client.create('p1', 'failsboot'),
        throwsA(
          isA<OrbCreateError>()
              .having((e) => e.statusCode, 'statusCode', HttpStatus.badGateway)
              .having((e) => e.code, 'code', OrbCreateError.bootFailed)
              .having((e) => e.details, 'details', 'the container exited')
              .having((e) => e.logTail, 'logTail', [
                '[orb] stage: cloning',
                'fatal: bad url',
              ]),
        ),
      );
    });

    test(
      'decodes a 503 refusal as a create error with the wire code',
      () async {
        await expectLater(
          client.create('p1', 'unavailable'),
          throwsA(
            isA<OrbCreateError>()
                .having(
                  (e) => e.statusCode,
                  'statusCode',
                  HttpStatus.serviceUnavailable,
                )
                .having((e) => e.code, 'code', 'docker_unavailable'),
          ),
        );
      },
    );
  });

  group('OrbsClient rebuild', () {
    test('returns the built tag', () async {
      expect(await client.rebuildImage(), 'orb:abc123');
      expect(rebuildCalls, 1);
    });
  });

  group('OrbsClient deleteOrphan', () {
    test('deletes the id', () async {
      await client.deleteOrphan('orb_2');
      expect(deleted, ['orb_2']);
    });

    test('surfaces the 404 and 409 as OrbsClientError', () async {
      await expectLater(
        client.deleteOrphan('missing'),
        throwsA(
          isA<OrbsClientError>().having(
            (e) => e.statusCode,
            'statusCode',
            HttpStatus.notFound,
          ),
        ),
      );
      await expectLater(
        client.deleteOrphan('exists'),
        throwsA(
          isA<OrbsClientError>().having(
            (e) => e.statusCode,
            'statusCode',
            HttpStatus.conflict,
          ),
        ),
      );
    });
  });

  group('OrbsClient delete (protected deletion, issue #98)', () {
    test('a 204 is the removal; no body is sent when not forced', () async {
      await client.delete('orb_1');
      expect(deleted, ['orb_1']);
      expect(deleteBodies, ['']);
    });

    test('the force delete sends the force body', () async {
      await client.delete('orb_1', force: true);
      expect(deleted, ['orb_1']);
      expect(deleteBodies, ['{"force":true}']);
    });

    test(
      'a 409 deletion_refused is an OrbsClientError with the wire code',
      () async {
        await expectLater(
          client.delete('refused'),
          throwsA(
            isA<OrbsClientError>()
                .having((e) => e.statusCode, 'statusCode', HttpStatus.conflict)
                .having((e) => e.message, 'message', 'deletion_refused'),
          ),
        );
        expect(deleted, isEmpty);
      },
    );

    test('a 404 is an OrbsClientError', () async {
      await expectLater(
        client.delete('missing'),
        throwsA(
          isA<OrbsClientError>().having(
            (e) => e.statusCode,
            'statusCode',
            HttpStatus.notFound,
          ),
        ),
      );
      expect(deleted, isEmpty);
    });
  });

  group('OrbsClient update (issue #98)', () {
    test('a 200 decodes the record', () async {
      final record = await client.update('orb_1');
      expect(
        record,
        const OrbRecord(
          id: 'orb_1',
          name: 'api',
          project: 'p1',
          branch: 'orb/orb_1',
          state: 'running',
          created: '2025-01-01T00:00:00Z',
          url: 'http://127.0.0.1:49300',
        ),
      );
    });

    test(
      'a 400 refusal is an OrbCreateError with its code and details',
      () async {
        await expectLater(
          client.update('busy'),
          throwsA(
            isA<OrbCreateError>()
                .having(
                  (e) => e.statusCode,
                  'statusCode',
                  HttpStatus.badRequest,
                )
                .having((e) => e.code, 'code', 'update_busy')
                .having(
                  (e) => e.details,
                  'details',
                  'the orb has an active session',
                ),
          ),
        );
      },
    );

    test('a failed re-boot is an OrbCreateError with the log tail', () async {
      await expectLater(
        client.update('failsboot'),
        throwsA(
          isA<OrbCreateError>()
              .having((e) => e.statusCode, 'statusCode', HttpStatus.badGateway)
              .having((e) => e.code, 'code', OrbCreateError.bootFailed)
              .having((e) => e.logTail, 'logTail', [
                '[orb] stage: starting',
                'fatal: no good',
              ]),
        ),
      );
    });

    test('a 404 is an OrbCreateError with the wire code', () async {
      await expectLater(
        client.update('missing'),
        throwsA(
          isA<OrbCreateError>()
              .having((e) => e.statusCode, 'statusCode', HttpStatus.notFound)
              .having((e) => e.code, 'code', 'not_found'),
        ),
      );
    });
  });

  group('OrbsClient export (issue #98)', () {
    test('a 200 returns the export path', () async {
      expect(
        await client.export('orb_1'),
        '/proj/one/api-orb_1-20250101-000000UTC.tar.gz',
      );
    });

    test(
      'a 400 refusal is an OrbCreateError with its code and details',
      () async {
        await expectLater(
          client.export('nocheckout'),
          throwsA(
            isA<OrbCreateError>()
                .having(
                  (e) => e.statusCode,
                  'statusCode',
                  HttpStatus.badRequest,
                )
                .having((e) => e.code, 'code', 'missing_checkout')
                .having(
                  (e) => e.details,
                  'details',
                  'no checkout for the project',
                ),
          ),
        );
      },
    );
  });

  group('OrbsClient startWithFreshState (issue #102)', () {
    test('posts the action and decodes the record', () async {
      final record = await client.startWithFreshState('orb_5');
      expect(orbActions, [('orb_5', 'fresh-state')]);
      expect(record.state, 'running');
      expect(record.url, 'http://127.0.0.1:49300');
    });

    test(
      'a 400 refusal is an OrbCreateError with its code and details',
      () async {
        await expectLater(
          client.startWithFreshState('refused-state'),
          throwsA(
            isA<OrbCreateError>()
                .having(
                  (e) => e.statusCode,
                  'statusCode',
                  HttpStatus.badRequest,
                )
                .having((e) => e.code, 'code', 'not_wakeable'),
          ),
        );
      },
    );
  });
}
