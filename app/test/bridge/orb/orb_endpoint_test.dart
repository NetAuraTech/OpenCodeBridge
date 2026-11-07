import 'dart:async';
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
import 'package:opencodebridge/model/session.dart';

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

/// A `DELETE` with an (optionally empty) JSON body — the protected
/// deletion's `{"force": true}`.
Future<(int, String)> _deleteRaw(Uri base, String path, String body) async {
  final client = HttpClient();
  try {
    final request = await client.deleteUrl(base.replace(path: path));
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

  /// The `includePr` flag the last `list` call carried (issue #96).
  bool? listIncludePr;

  @override
  Future<OrbRecord> create({
    required String project,
    required String name,
    required String checkout,
    String? base,
  }) async {
    createProject = project;
    createName = name;
    createCheckout = checkout;
    final error = createError;
    if (error != null) throw error;
    return createRecord!;
  }

  @override
  Future<List<OrbRecord>> list({bool includePr = false}) async {
    listIncludePr = includePr;
    final error = listError;
    if (error != null) throw error;
    return listResult;
  }

  String? deleteOrphanId;
  Object? deleteOrphanError;

  @override
  Future<void> deleteOrphan(String id) async {
    deleteOrphanId = id;
    final error = deleteOrphanError;
    if (error != null) throw error;
  }

  String? deleteId;
  bool? deleteForce;
  Object? deleteError;

  @override
  Future<void> delete(String id, {bool force = false}) async {
    deleteId = id;
    deleteForce = force;
    final error = deleteError;
    if (error != null) throw error;
  }

  String? updateId;
  OrbRecord? updateRecord;
  Object? updateError;

  @override
  Future<OrbRecord> update(String id) async {
    updateId = id;
    final error = updateError;
    if (error != null) throw error;
    return updateRecord!;
  }

  String? exportId;
  String? exportPath;
  Object? exportError;

  @override
  Future<String> export(String id) async {
    exportId = id;
    final error = exportError;
    if (error != null) throw error;
    return exportPath!;
  }

  String? stopId;
  Object? stopError;

  @override
  Future<void> stop(String id) async {
    stopId = id;
    final error = stopError;
    if (error != null) throw error;
  }

  String? wakeId;
  OrbRecord? wakeRecord;
  Object? wakeError;

  @override
  Future<OrbRecord> wake(String id) async {
    wakeId = id;
    final error = wakeError;
    if (error != null) throw error;
    return wakeRecord!;
  }

  String? sessionOrbId;
  Session? sessionRecord;
  Object? sessionError;

  @override
  Future<Session> createSessionOnOrb(String id) async {
    sessionOrbId = id;
    final error = sessionError;
    if (error != null) throw error;
    return sessionRecord!;
  }

  String? moveToOrbSession;
  String? moveToOrbName;
  Object? moveToOrbError;

  @override
  Future<void> moveSessionToOrb({
    required String session,
    required String orbName,
  }) async {
    moveToOrbSession = session;
    moveToOrbName = orbName;
    final error = moveToOrbError;
    if (error != null) throw error;
  }

  /// The lifecycle pass surface (issue #101): the fake records the arming
  /// and stays inert — no background pass runs against the endpoint fakes.
  int lifecycleArmed = 0;
  bool lifecycleStopped = false;

  @override
  void startLifecyclePass({Duration? interval}) => lifecycleArmed++;

  @override
  void stopLifecyclePass() => lifecycleStopped = true;

  @override
  bool get lifecyclePassRunning => lifecycleArmed > 0 && !lifecycleStopped;

  /// The startup recovery (issue #102): records that `recover` ran.
  int recoverCalls = 0;
  final recovered = Completer<void>();
  Object? recoverError;

  @override
  Future<void> recover() async {
    recoverCalls++;
    if (!recovered.isCompleted) recovered.complete();
    final error = recoverError;
    if (error != null) throw error;
  }

  String? freshStateId;
  OrbRecord? freshStateRecord;
  Object? freshStateError;

  @override
  Future<OrbRecord> startWithFreshState(String id) async {
    freshStateId = id;
    final error = freshStateError;
    if (error != null) throw error;
    return freshStateRecord!;
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
          pushFailing: true,
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
          'pushFailing': true,
        },
      ]);
    });

    test('?pr=1 asks the service for the PR state', () async {
      orbs.listResult = const [];

      final client = HttpClient();
      late int status;
      late String body;
      try {
        final request = await client.getUrl(
          base.replace(path: 'api/orbs', query: 'pr=1'),
        );
        final response = await request.close();
        status = response.statusCode;
        body = await response.transform(const Utf8Decoder()).join();
      } finally {
        client.close(force: true);
      }

      expect(status, 200);
      expect(body, '[]');
      expect(orbs.listIncludePr, isTrue);
    });

    test('without ?pr the service is not asked for the PR state', () async {
      orbs.listResult = const [];

      await _get(base, 'api/orbs');

      expect(orbs.listIncludePr, isFalse);
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

  group('DELETE /api/orbs/<id> (issue #98)', () {
    late BridgeServer server;
    late _FakeService service;
    late _FakeOrbs orbs;
    late Uri base;

    setUp(() async {
      service = _FakeService();
      service.projectsResult = const [
        OpencodeProject(id: 'p1', name: 'proj-one', canonical: '/proj/one'),
      ];
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

    test('204 on a successful deletion; the id is the path segment', () async {
      final (status, body) = await _deleteRaw(base, 'api/orbs/eeee', '');

      expect(status, 204);
      expect(body, '');
      expect(orbs.deleteId, 'eeee');
      expect(orbs.deleteForce, false); // no body is a non-forced deletion
    });

    test(
      'a guarded refusal is a 409 deletion_refused with the guard',
      () async {
        orbs.deleteError = const OrbDeletionRefusedError(
          'eeee',
          OrbDeletionGuard(
            evaluable: true,
            dirty: ['M src/app.dart'],
            unpushedCount: 2,
          ),
        );

        final (status, body) = await _deleteRaw(base, 'api/orbs/eeee', '');

        expect(status, 409);
        expect(jsonDecode(body), {
          'error': 'deletion_refused',
          'id': 'eeee',
          'reasons': ['dirty_tree', 'unpushed_commits'],
          'dirty': ['M src/app.dart'],
          'unpushedCount': 2,
        });
      },
    );

    test('a force body passes force through to the service', () async {
      final (status, body) = await _deleteRaw(
        base,
        'api/orbs/eeee',
        '{"force": true}',
      );

      expect(status, 204);
      expect(body, '');
      expect(orbs.deleteId, 'eeee');
      expect(orbs.deleteForce, true);
    });

    test('a non-boolean force is not a force', () async {
      final (status, body) = await _deleteRaw(
        base,
        'api/orbs/eeee',
        '{"force": "yes"}',
      );

      expect(status, 204);
      expect(orbs.deleteForce, false);
    });

    test('a missing orb is 404 not_found', () async {
      orbs.deleteError = const OrbNotFoundError('eeee');

      final (status, body) = await _deleteRaw(base, 'api/orbs/eeee', '');

      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
    });

    test('a missing orphan is 404 not_found', () async {
      orbs.deleteError = const OrbOrphanNotFoundError('eeee');

      final (status, body) = await _deleteRaw(base, 'api/orbs/eeee', '');

      expect(status, 404);
      expect(jsonDecode(body), {'error': 'not_found'});
    });

    test('a daemon failure is 502 docker_unreachable', () async {
      orbs.deleteError = const DockerUnavailableError('Cannot connect');

      final (status, body) = await _deleteRaw(base, 'api/orbs/eeee', '');

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
        final (status, body) = await _deleteRaw(
          bare.baseUri,
          'api/orbs/eeee',
          '',
        );
        expect(status, 503);
        expect(jsonDecode(body), {'error': 'docker_unavailable'});
      } finally {
        await bare.stop();
      }
    });

    test('the lifecycle pass is armed only when asked (issue #101)', () async {
      final inert = _FakeOrbs();
      server = await BridgeServer.start(port: 0, orbs: inert);
      expect(
        inert.lifecycleArmed,
        0,
        reason: 'a bridge without the flag never arms the pass',
      );
      await server.stop();

      final armed = _FakeOrbs();
      server = await BridgeServer.start(
        port: 0,
        orbs: armed,
        autoLifecyclePass: true,
        lifecyclePassInterval: const Duration(minutes: 1),
      );
      expect(armed.lifecycleArmed, 1);
      await server.stop();
      expect(armed.lifecycleStopped, isTrue);
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

  group('POST /api/orbs/<id>/<action> (issue #97)', () {
    late BridgeServer server;
    late _FakeService service;
    late _FakeOrbs orbs;
    late Uri base;

    const record = OrbRecord(
      id: 'aaaa',
      name: 'dev',
      project: 'p1',
      branch: 'orb/aaaa',
      state: 'running',
      created: '2026-11-04T00:00:00.000Z',
      url: 'http://127.0.0.1:39999',
    );

    const session = Session(
      id: 's-1',
      title: 'hello',
      project: SessionProject(id: 'p1', name: 'proj-one'),
      created: 1762252800000,
      location: '/workspace',
      active: false,
      orb: 'aaaa',
    );

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

    test('stop is a 204 with no body', () async {
      final (status, body) = await _postRaw(base, 'api/orbs/aaaa/stop', '');

      expect(status, 204);
      expect(body, isEmpty);
      expect(orbs.stopId, 'aaaa');
    });

    test('wake is a 200 with the running record', () async {
      orbs.wakeRecord = record;

      final (status, body) = await _postRaw(base, 'api/orbs/aaaa/wake', '');

      expect(status, 200);
      expect(jsonDecode(body), {
        'id': 'aaaa',
        'name': 'dev',
        'project': 'p1',
        'branch': 'orb/aaaa',
        'state': 'running',
        'created': '2026-11-04T00:00:00.000Z',
        'url': 'http://127.0.0.1:39999',
      });
      expect(orbs.wakeId, 'aaaa');
    });

    test('sessions is a 201 with the row (stamped with the orb)', () async {
      orbs.sessionRecord = session;

      final (status, body) = await _postRaw(base, 'api/orbs/aaaa/sessions', '');

      expect(status, 201);
      expect(jsonDecode(body), {
        'id': 's-1',
        'title': 'hello',
        'project': {'id': 'p1', 'name': 'proj-one'},
        'created': 1762252800000,
        'location': '/workspace',
        'active': false,
        'orb': 'aaaa',
      });
      expect(orbs.sessionOrbId, 'aaaa');
    });

    test('update is a 200 with the record', () async {
      orbs.updateRecord = record;

      final (status, body) = await _postRaw(base, 'api/orbs/aaaa/update', '');

      expect(status, 200);
      expect(jsonDecode(body), {
        'id': 'aaaa',
        'name': 'dev',
        'project': 'p1',
        'branch': 'orb/aaaa',
        'state': 'running',
        'created': '2026-11-04T00:00:00.000Z',
        'url': 'http://127.0.0.1:39999',
      });
      expect(orbs.updateId, 'aaaa');
    });

    test('export is a 200 with the export path', () async {
      const path = '/proj/one/dev-aaaa-20261104-000000UTC.tar.gz';
      orbs.exportPath = path;

      final (status, body) = await _postRaw(base, 'api/orbs/aaaa/export', '');

      expect(status, 200);
      expect(jsonDecode(body), {'path': path});
      expect(orbs.exportId, 'aaaa');
    });

    test('an unknown id is a 404 for each action', () async {
      orbs.stopError = const OrbNotFoundError('nope');
      orbs.wakeError = const OrbNotFoundError('nope');
      orbs.sessionError = const OrbNotFoundError('nope');
      orbs.updateError = const OrbNotFoundError('nope');
      orbs.exportError = const OrbNotFoundError('nope');

      for (final action in const [
        'stop',
        'wake',
        'sessions',
        'update',
        'export',
      ]) {
        final (status, body) = await _postRaw(
          base,
          'api/orbs/nope/$action',
          '',
        );
        expect(status, 404);
        expect(jsonDecode(body), {'error': 'not_found'});
      }
    });

    test('a named refusal is a 400 with its code and details', () async {
      for (final refusal in const [
        OrbRefusalError(OrbRefusalError.notWakeable, 'the orb is not stopped'),
        OrbRefusalError(
          OrbRefusalError.missingCheckout,
          'no checkout for the project',
        ),
        OrbRefusalError(OrbRefusalError.notRunning, 'the orb is stopped'),
      ]) {
        orbs.stopError = refusal;
        orbs.wakeError = refusal;
        orbs.sessionError = refusal;
        orbs.updateError = refusal;
        orbs.exportError = refusal;

        for (final action in const [
          'stop',
          'wake',
          'sessions',
          'update',
          'export',
        ]) {
          final (status, body) = await _postRaw(
            base,
            'api/orbs/aaaa/$action',
            '',
          );
          expect(status, 400);
          expect(jsonDecode(body), {
            'error': refusal.code,
            'details': refusal.message,
          });
        }
      }
    });

    test('a failed boot is a 502 orb_boot_failed with the log tail', () async {
      const boot = OrbBootError('aaaa', 'the orb did not come up in time', [
        'server listening',
        'fatal: no go',
      ]);
      orbs.wakeError = boot;
      orbs.stopError = boot;
      orbs.sessionError = boot;
      orbs.updateError = boot;

      for (final action in const ['stop', 'wake', 'sessions', 'update']) {
        final (status, body) = await _postRaw(
          base,
          'api/orbs/aaaa/$action',
          '',
        );
        expect(status, 502);
        expect(jsonDecode(body), {
          'error': 'orb_boot_failed',
          'details': 'the orb did not come up in time',
          'logTail': ['server listening', 'fatal: no go'],
        });
      }
    });

    test(
      'a missing session prerequisite is a 503 opencode_unavailable',
      () async {
        const unavailable = OrbSessionsUnavailableError('no host opencode CLI');
        orbs.stopError = unavailable;
        orbs.wakeError = unavailable;
        orbs.sessionError = unavailable;
        orbs.updateError = unavailable;

        for (final action in const ['stop', 'wake', 'sessions', 'update']) {
          final (status, body) = await _postRaw(
            base,
            'api/orbs/aaaa/$action',
            '',
          );
          expect(status, 503);
          expect(jsonDecode(body), {'error': 'opencode_unavailable'});
        }
      },
    );

    test('a failed session move is a 502 session_move_failed', () async {
      const move = OrbSessionMoveError('s-1', 'exit 1: cannot find session');
      orbs.stopError = move;
      orbs.sessionError = move;

      for (final action in const ['stop', 'sessions']) {
        final (status, body) = await _postRaw(
          base,
          'api/orbs/aaaa/$action',
          '',
        );
        expect(status, 502);
        expect(jsonDecode(body), {
          'error': 'session_move_failed',
          'session': 's-1',
          'details': 'exit 1: cannot find session',
        });
      }
    });

    test('a daemon failure is a 502 docker_unreachable', () async {
      const daemon = DockerUnavailableError('Cannot connect to the daemon');
      orbs.stopError = daemon;
      orbs.wakeError = daemon;
      orbs.sessionError = daemon;
      orbs.updateError = daemon;
      orbs.exportError = daemon;

      for (final action in const [
        'stop',
        'wake',
        'sessions',
        'update',
        'export',
      ]) {
        final (status, body) = await _postRaw(
          base,
          'api/orbs/aaaa/$action',
          '',
        );
        expect(status, 502);
        expect(jsonDecode(body), {'error': 'docker_unreachable'});
      }
    });

    test('a service error is the service mapping', () async {
      service.projectsError = null;
      final serviceFail = const OpencodeServiceError(500, 'boom');
      orbs.stopError = serviceFail;
      orbs.wakeError = serviceFail;
      orbs.sessionError = serviceFail;

      for (final action in const ['stop', 'wake', 'sessions']) {
        final (status, body) = await _postRaw(
          base,
          'api/orbs/aaaa/$action',
          '',
        );
        expect(status, 502);
        expect(jsonDecode(body), {'error': 'opencode_unreachable'});
      }
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
          'api/orbs/a/stop',
          '',
        );
        expect(status, 503);
        expect(jsonDecode(body), {'error': 'docker_unavailable'});
      } finally {
        await bare.stop();
      }
    });

    test('an unknown action word is a 404 (not an orb action)', () async {
      final (status, body) = await _postRaw(base, 'api/orbs/aaaa/nuke', '');

      expect(status, 404);
      expect(orbs.stopId, isNull);
      expect(orbs.wakeId, isNull);
    });
  });

  group('POST /api/sessions/<id>/move-to-orb (issue #97)', () {
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

    test('204; the session id and the orb name reach the service', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/s-1/move-to-orb',
        jsonEncode({'orb': 'dev'}),
      );

      expect(status, 204);
      expect(body, isEmpty);
      expect(orbs.moveToOrbSession, 's-1');
      expect(orbs.moveToOrbName, 'dev');
    });

    test('a missing orb field is a 400 invalid_body', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/s-1/move-to-orb',
        jsonEncode({}),
      );

      expect(status, 400);
      expect(jsonDecode(body), {'error': 'invalid_body'});
      expect(orbs.moveToOrbSession, isNull);
    });

    test('a non-JSON body is a 400 invalid_body', () async {
      final (status, body) = await _postRaw(
        base,
        'api/sessions/s-1/move-to-orb',
        'not json{',
      );

      expect(status, 400);
      expect(jsonDecode(body), {'error': 'invalid_body'});
      expect(orbs.moveToOrbSession, isNull);
    });

    test('a named refusal is a 400 with its code and details', () async {
      for (final refusal in const [
        OrbRefusalError(OrbRefusalError.missingCheckout, 'no checkout'),
        OrbRefusalError(OrbRefusalError.nonGithubRemote, 'not a GitHub remote'),
      ]) {
        orbs.moveToOrbError = refusal;

        final (status, body) = await _postRaw(
          base,
          'api/sessions/s-1/move-to-orb',
          jsonEncode({'orb': 'dev'}),
        );

        expect(status, 400);
        expect(jsonDecode(body), {
          'error': refusal.code,
          'details': refusal.message,
        });
      }
    });

    test('a taken name is a 409 name_taken', () async {
      orbs.moveToOrbError = const OrbNameTakenError('p1', 'dev');

      final (status, body) = await _postRaw(
        base,
        'api/sessions/s-1/move-to-orb',
        jsonEncode({'orb': 'dev'}),
      );

      expect(status, 409);
      expect(jsonDecode(body), {'error': 'name_taken', 'name': 'dev'});
    });

    test('a failed boot is a 502 orb_boot_failed with the log tail', () async {
      orbs.moveToOrbError = const OrbBootError(
        'bbbb',
        'the orb did not come up in time',
        ['fatal: no go'],
      );

      final (status, body) = await _postRaw(
        base,
        'api/sessions/s-1/move-to-orb',
        jsonEncode({'orb': 'fresh'}),
      );

      expect(status, 502);
      expect(jsonDecode(body), {
        'error': 'orb_boot_failed',
        'details': 'the orb did not come up in time',
        'logTail': ['fatal: no go'],
      });
    });

    test('a failed image build is a 502 docker_build_failed', () async {
      orbs.moveToOrbError = const OrbImageBuildError('orb:abc', 1);

      final (status, body) = await _postRaw(
        base,
        'api/sessions/s-1/move-to-orb',
        jsonEncode({'orb': 'fresh'}),
      );

      expect(status, 502);
      expect(jsonDecode(body), {'error': 'docker_build_failed'});
    });

    test(
      'a missing session prerequisite is a 503 opencode_unavailable',
      () async {
        orbs.moveToOrbError = const OrbSessionsUnavailableError('no host CLI');

        final (status, body) = await _postRaw(
          base,
          'api/sessions/s-1/move-to-orb',
          jsonEncode({'orb': 'dev'}),
        );

        expect(status, 503);
        expect(jsonDecode(body), {'error': 'opencode_unavailable'});
      },
    );

    test('a failed move is a 502 session_move_failed', () async {
      orbs.moveToOrbError = const OrbSessionMoveError(
        's-1',
        'exit 1: import conflict',
      );

      final (status, body) = await _postRaw(
        base,
        'api/sessions/s-1/move-to-orb',
        jsonEncode({'orb': 'dev'}),
      );

      expect(status, 502);
      expect(jsonDecode(body), {
        'error': 'session_move_failed',
        'session': 's-1',
        'details': 'exit 1: import conflict',
      });
    });

    test('a daemon failure is a 502 docker_unreachable', () async {
      orbs.moveToOrbError = const DockerUnavailableError('no daemon');

      final (status, body) = await _postRaw(
        base,
        'api/sessions/s-1/move-to-orb',
        jsonEncode({'orb': 'dev'}),
      );

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
        final (status, body) = await _postRaw(
          bare.baseUri,
          'api/sessions/s-1/move-to-orb',
          jsonEncode({'orb': 'dev'}),
        );
        expect(status, 503);
        expect(jsonDecode(body), {'error': 'docker_unavailable'});
      } finally {
        await bare.stop();
      }
    });

    test('503 opencode_unavailable without a sessions backend', () async {
      if (_hostHasServiceDescriptor()) return;
      final bare = await BridgeServer.start(port: 0, orbs: orbs);
      try {
        final (status, body) = await _postRaw(
          bare.baseUri,
          'api/sessions/s-1/move-to-orb',
          jsonEncode({'orb': 'dev'}),
        );
        expect(status, 503);
        expect(jsonDecode(body), {'error': 'opencode_unavailable'});
        expect(orbs.moveToOrbSession, isNull);
      } finally {
        await bare.stop();
      }
    });

    test(
      'an unknown session subpath other than move-to-orb is not caught',
      () async {
        final (status, body) = await _postRaw(
          base,
          'api/sessions/s-1/move-to-orbx',
          jsonEncode({'orb': 'dev'}),
        );

        expect(status, 404);
        expect(orbs.moveToOrbSession, isNull);
      },
    );
  });

  group('the broken-orb actions (issue #102)', () {
    late BridgeServer server;
    late _FakeService service;
    late _FakeOrbs orbs;
    late Uri base;

    const record = OrbRecord(
      id: 'aaaa',
      name: 'dev',
      project: 'p1',
      branch: 'orb/aaaa',
      state: 'running',
      created: '2026-11-04T00:00:00.000Z',
      url: 'http://127.0.0.1:39999',
    );

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

    test('fresh-state is a 200 with the running record', () async {
      orbs.freshStateRecord = record;

      final (status, body) = await _postRaw(
        base,
        'api/orbs/aaaa/fresh-state',
        '',
      );

      expect(status, 200);
      expect(jsonDecode(body)['state'], 'running');
      expect(orbs.freshStateId, 'aaaa');
    });

    test(
      'fresh-state maps the refusal and the failed boot like wake',
      () async {
        orbs.freshStateError = const OrbRefusalError(
          OrbRefusalError.notWakeable,
          'only a broken orb whose state dir is missing can start with fresh '
          'state',
        );
        final (refused, refusalBody) = await _postRaw(
          base,
          'api/orbs/aaaa/fresh-state',
          '',
        );
        expect(refused, 400);
        expect(jsonDecode(refusalBody)['error'], 'not_wakeable');

        orbs.freshStateError = const OrbBootError('aaaa', 'exited', ['boom']);
        final (failed, failedBody) = await _postRaw(
          base,
          'api/orbs/aaaa/fresh-state',
          '',
        );
        expect(failed, 502);
        expect(jsonDecode(failedBody)['error'], 'orb_boot_failed');
      },
    );

    test('fresh-state maps a 404 for an unknown id', () async {
      orbs.freshStateError = const OrbNotFoundError('aaaa');

      final (status, _) = await _postRaw(base, 'api/orbs/aaaa/fresh-state', '');

      expect(status, 404);
    });
  });

  group('the startup recovery (issue #102, spec §2.11)', () {
    test('the bridge runs the orb recovery once it is listening', () async {
      final orbs = _FakeOrbs();
      final server = await BridgeServer.start(port: 0, orbs: orbs);
      try {
        await orbs.recovered.future.timeout(const Duration(seconds: 5));
        expect(orbs.recoverCalls, 1);
      } finally {
        await server.stop();
      }
    });

    test('a failing recovery does not take the bridge down', () async {
      final orbs = _FakeOrbs();
      orbs.recoverError = const OrbBootError('aaaa', 'boot failed', ['boom']);
      final server = await BridgeServer.start(port: 0, orbs: orbs);
      try {
        await orbs.recovered.future.timeout(const Duration(seconds: 5));
        // The recovery threw (the OrbBootError rides the unawaited path's
        // own catch — an uncaught async error would fail the test): the
        // HTTP surface keeps serving.
        final (status, _) = await _get(server.baseUri, 'api/orbs');
        expect(status, 200);
      } finally {
        await server.stop();
      }
    });
  });
}
