import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/bridge_server.dart';
import 'package:opencodebridge/bridge/docker/docker_backend.dart';
import 'package:opencodebridge/bridge/orb/orb_image_builder.dart';
import 'package:opencodebridge/bridge/orb/orb_service.dart';
import 'package:opencodebridge/bridge/sessions/backend.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';
import 'package:opencodebridge/bridge/sessions/paths.dart';
import 'package:opencodebridge/model/orb.dart';

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

/// On a host with the docker CLI on PATH the bridge default builds a real
/// orbs service, so the 503 path is not observable there: the test marks
/// itself skipped and returns true.
bool _hostHasDockerCli() {
  if (findHostDocker() != null) {
    markTestSkipped(
      'the host has a docker CLI on PATH, so the bridge default builds a '
      'real orbs service',
    );
    return true;
  }
  return false;
}

/// On a host that publishes a shared opencode service descriptor the bridge
/// default builds a real sessions backend, so the 503 path is not observable
/// there: the test marks itself skipped and returns true.
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

/// The [OpencodeService] seam: `projects()` returns a scripted project list,
/// or throws a scripted service error. The rest is never called.
class _FakeService extends OpencodeService {
  List<OpencodeProject> projectsResult = const [];
  OpencodeServiceError? projectsError;

  @override
  Future<List<OpencodeProject>> projects() async {
    final error = projectsError;
    if (error != null) throw error;
    return projectsResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The [OrbService] seam: `create`/`list` record their arguments and return
/// a scripted result, or throw a scripted error. The rest is never called.
class _FakeOrbs implements OrbService {
  String? createProject;
  String? createName;
  String? createCheckout;
  OrbRecord? createRecord;
  Object? createError;

  List<OrbRecord> listResult = const [];
  Object? listError;

  @override
  Future<OrbRecord> create({
    required String project,
    required String name,
    required String checkout,
  }) async {
    createProject = project;
    createName = name;
    createCheckout = checkout;
    final error = createError;
    if (error != null) throw error;
    return createRecord!;
  }

  @override
  Future<List<OrbRecord>> list() async {
    final error = listError;
    if (error != null) throw error;
    return listResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('POST /api/orbs (issue #93)', () {
    late BridgeServer server;
    late _FakeService service;
    late _FakeOrbs orbs;
    late Uri base;

    const project = OpencodeProject(
      id: 'p1',
      name: 'proj-one',
      canonical: '/proj/one',
    );

    setUp(() async {
      service = _FakeService();
      service.projectsResult = const [project];
      orbs = _FakeOrbs();
      server = await BridgeServer.start(
        port: 0,
        sessions: SessionsBackend(service: service),
        orbs: orbs,
      );
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
    });

    test(
      '201 with the record; the checkout resolves to the canonical',
      () async {
        orbs.createRecord = const OrbRecord(
          id: 'aaaa',
          name: 'dev',
          project: 'p1',
          branch: 'orb/aaaa',
          state: 'running',
          created: '2026-11-04T00:00:00.000Z',
          url: 'http://127.0.0.1:39999',
        );

        final (status, body) = await _postRaw(
          base,
          'api/orbs',
          jsonEncode({'project': 'p1', 'name': 'dev'}),
        );

        expect(status, 201);
        expect(jsonDecode(body), {
          'id': 'aaaa',
          'name': 'dev',
          'project': 'p1',
          'branch': 'orb/aaaa',
          'state': 'running',
          'created': '2026-11-04T00:00:00.000Z',
          'url': 'http://127.0.0.1:39999',
        });
        expect(orbs.createProject, 'p1');
        expect(orbs.createName, 'dev');
        expect(orbs.createCheckout, '/proj/one');
      },
    );

    test('a missing field is 400 invalid_body', () async {
      final (status, body) = await _postRaw(
        base,
        'api/orbs',
        jsonEncode({'project': 'p1'}),
      );

      expect(status, 400);
      expect(jsonDecode(body), {'error': 'invalid_body'});
      expect(orbs.createProject, isNull); // The create never ran.
    });

    test('a non-JSON body is 400 invalid_body', () async {
      final (status, body) = await _postRaw(base, 'api/orbs', 'not json{');

      expect(status, 400);
      expect(jsonDecode(body), {'error': 'invalid_body'});
      expect(orbs.createProject, isNull);
    });

    test('a name taken in the project is 409 name_taken', () async {
      orbs.createError = const OrbNameTakenError('p1', 'dev');

      final (status, body) = await _postRaw(
        base,
        'api/orbs',
        jsonEncode({'project': 'p1', 'name': 'dev'}),
      );

      expect(status, 409);
      expect(jsonDecode(body), {'error': 'name_taken', 'name': 'dev'});
    });

    test('each up-front refusal is a 400 with its code and details', () async {
      for (final refusal in const [
        OrbRefusalError(OrbRefusalError.noRemote, 'no origin remote'),
        OrbRefusalError(OrbRefusalError.nonGithubRemote, 'not a GitHub remote'),
        OrbRefusalError(
          OrbRefusalError.missingGitIdentity,
          'no host git identity',
        ),
      ]) {
        orbs.createError = refusal;
        final (status, body) = await _postRaw(
          base,
          'api/orbs',
          jsonEncode({'project': 'p1', 'name': 'dev'}),
        );
        expect(status, 400);
        expect(jsonDecode(body), {
          'error': refusal.code,
          'details': refusal.message,
        });
      }
    });

    test('an unknown project id is 404 not_found', () async {
      final (status, body) = await _postRaw(
        base,
        'api/orbs',
        jsonEncode({'project': 'nope', 'name': 'dev'}),
      );

      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
      expect(orbs.createProject, isNull);
    });

    test('a service 404 is a 404; any other service error is 502', () async {
      service.projectsError = const OpencodeServiceError(404, 'nope');
      var (status404, body404) = await _postRaw(
        base,
        'api/orbs',
        jsonEncode({'project': 'p1', 'name': 'dev'}),
      );
      expect(status404, 404);
      expect(jsonDecode(body404), {'error': 'not_found'});

      service.projectsError = const OpencodeServiceError(500, 'boom');
      var (status502, body502) = await _postRaw(
        base,
        'api/orbs',
        jsonEncode({'project': 'p1', 'name': 'dev'}),
      );
      expect(status502, 502);
      expect(jsonDecode(body502), {'error': 'opencode_unreachable'});
    });

    test('a failed boot is 502 orb_boot_failed with the log tail', () async {
      orbs.createError = const OrbBootError(
        'aaaa',
        'the orb did not come up within 10:00.000000',
        ['cloning', 'fatal: repository not found'],
      );

      final (status, body) = await _postRaw(
        base,
        'api/orbs',
        jsonEncode({'project': 'p1', 'name': 'dev'}),
      );

      expect(status, 502);
      expect(jsonDecode(body), {
        'error': 'orb_boot_failed',
        'details': 'the orb did not come up within 10:00.000000',
        'logTail': ['cloning', 'fatal: repository not found'],
      });
    });

    test('a daemon failure is 502 docker_unreachable', () async {
      orbs.createError = const DockerUnavailableError(
        'Cannot connect to the Docker daemon',
      );

      final (status, body) = await _postRaw(
        base,
        'api/orbs',
        jsonEncode({'project': 'p1', 'name': 'dev'}),
      );

      expect(status, 502);
      expect(jsonDecode(body), {'error': 'docker_unreachable'});
    });

    test('a failed image build is 502 docker_build_failed', () async {
      orbs.createError = const OrbImageBuildError('orb:abc', 1);

      final (status, body) = await _postRaw(
        base,
        'api/orbs',
        jsonEncode({'project': 'p1', 'name': 'dev'}),
      );

      expect(status, 502);
      expect(jsonDecode(body), {'error': 'docker_build_failed'});
    });

    test('503 docker_unavailable when the host has no docker CLI', () async {
      if (_hostHasDockerCli()) return;
      final bare = await BridgeServer.start(
        port: 0,
        sessions: SessionsBackend(service: service),
      );
      try {
        final (status, body) = await _postRaw(
          bare.baseUri,
          'api/orbs',
          jsonEncode({'project': 'p1', 'name': 'dev'}),
        );
        expect(status, 503);
        expect(jsonDecode(body), {'error': 'docker_unavailable'});
      } finally {
        await bare.stop();
      }
    });
  });

  group('GET /api/orbs (issue #93)', () {
    late BridgeServer server;
    late _FakeService service;
    late _FakeOrbs orbs;
    late Uri base;

    setUp(() async {
      service = _FakeService();
      orbs = _FakeOrbs();
      server = await BridgeServer.start(
        port: 0,
        sessions: SessionsBackend(service: service),
        orbs: orbs,
      );
      base = server.baseUri;
    });

    tearDown(() async {
      await server.stop();
    });

    test('200 with the rows as record JSON', () async {
      orbs.listResult = const [
        OrbRecord(
          id: 'aaaa',
          name: 'dev',
          project: 'p1',
          branch: 'orb/aaaa',
          state: 'running',
          created: '2026-11-04T00:00:00.000Z',
          url: 'http://127.0.0.1:39999',
        ),
        OrbRecord(
          id: 'bbbb',
          name: 'beta',
          project: 'p1',
          branch: 'orb/bbbb',
          state: 'stopped',
          created: '2026-11-04T00:00:00.000Z',
        ),
      ];

      final (status, body) = await _get(base, 'api/orbs');

      expect(status, 200);
      expect(jsonDecode(body), [
        {
          'id': 'aaaa',
          'name': 'dev',
          'project': 'p1',
          'branch': 'orb/aaaa',
          'state': 'running',
          'created': '2026-11-04T00:00:00.000Z',
          'url': 'http://127.0.0.1:39999',
        },
        {
          'id': 'bbbb',
          'name': 'beta',
          'project': 'p1',
          'branch': 'orb/bbbb',
          'state': 'stopped',
          'created': '2026-11-04T00:00:00.000Z',
        },
      ]);
    });

    test('a daemon failure is 502 docker_unreachable', () async {
      orbs.listError = const DockerUnavailableError('Cannot connect');

      final (status, body) = await _get(base, 'api/orbs');

      expect(status, 502);
      expect(jsonDecode(body), {'error': 'docker_unreachable'});
    });

    test('503 docker_unavailable when the host has no docker CLI', () async {
      if (_hostHasDockerCli()) return;
      final bare = await BridgeServer.start(
        port: 0,
        sessions: SessionsBackend(service: service),
      );
      try {
        final (status, body) = await _get(bare.baseUri, 'api/orbs');
        expect(status, 503);
        expect(jsonDecode(body), {'error': 'docker_unavailable'});
      } finally {
        await bare.stop();
      }
    });
  });

  group('opencode_unavailable (issue #93)', () {
    test('503 without a sessions backend', () async {
      if (_hostHasServiceDescriptor()) return;
      final bare = await BridgeServer.start(port: 0, orbs: _FakeOrbs());
      try {
        final (status, body) = await _postRaw(
          bare.baseUri,
          'api/orbs',
          jsonEncode({'project': 'p1', 'name': 'dev'}),
        );
        expect(status, 503);
        expect(jsonDecode(body), {'error': 'opencode_unavailable'});
      } finally {
        await bare.stop();
      }
    });
  });
}
