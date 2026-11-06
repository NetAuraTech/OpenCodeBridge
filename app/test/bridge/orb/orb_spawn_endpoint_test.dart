// The spawn surface's HTTP endpoints (issue #99, spec §8.2/§8.3): `POST
// /api/orb/spawn` and `POST /api/orb/wait` behind the global
// orb_spawn/orb_wait tools. The service seams are the same fakes as the
// task-service tests, driving the real OrbTaskService.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/bridge_server.dart';
import 'package:opencodebridge/bridge/health.dart';
import 'package:opencodebridge/bridge/orb/orb_service.dart';
import 'package:opencodebridge/bridge/orb/orb_task_service.dart';
import 'package:opencodebridge/bridge/sessions/backend.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/orb.dart';
import 'package:opencodebridge/model/session.dart';
import 'package:opencodebridge/model/session_detail.dart';

Future<(int, String)> _postRaw(Uri base, String path, String body) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(base.replace(path: path));
    request.headers.contentType = ContentType.json;
    if (body.isNotEmpty) request.write(body);
    final response = await request.close();
    final raw = await response.transform(const Utf8Decoder()).join();
    return (response.statusCode, raw);
  } finally {
    client.close(force: true);
  }
}

const _project = OpencodeProject(
  id: 'prj_1',
  name: 'shop',
  canonical: '/home/dev/shop',
);

final _callerRow = Session(
  id: 'ses_caller',
  title: 'caller',
  project: const SessionProject(id: 'prj_1', name: 'shop'),
  created: 100,
  location: '/home/dev/shop',
  active: false,
);

OrbRecord _runningOrb({
  String id = 'a1b2c3',
  String name = 'worker',
  OrbPr? pr,
}) => OrbRecord(
  id: id,
  name: name,
  project: 'prj_1',
  branch: 'orb/$id',
  state: 'running',
  created: '2026-01-01T00:00:00.000Z',
  url: 'http://127.0.0.1:9999',
  pr: pr,
);

class _FakeOpencode extends OpencodeService {
  SessionDetail Function(String id) detailOf = (id) =>
      throw StateError('getDetail not scripted');
  List<SessionMessage> messagesResult = const [];

  @override
  Future<List<OpencodeProject>> projects() async => [_project];

  @override
  Future<void> prompt(
    String id,
    String text, {
    List<Map<String, Object?>>? files,
    List<Map<String, Object?>>? skills,
  }) async {}

  @override
  Future<SessionDetail> getDetail(String id) async => detailOf(id);

  @override
  Future<List<SessionMessage>> getMessages(String id) async => messagesResult;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBackend extends SessionsBackend {
  _FakeBackend(this.opencode) : super(service: opencode);

  final _FakeOpencode opencode;

  @override
  Future<List<Session>> list() async => [_callerRow];
}

class _FakeOrbs implements OrbService {
  List<OrbRecord> listResult = [_runningOrb()];

  OrbRecord? wakeResult;
  String? wokenId;

  OrbRecord? createResult;
  String? createName;
  String? createBase;

  String? seedBranchResult;
  Object? seedBranchError;
  String? seedRequested;

  String? stoppedId;
  Object? stopError;
  String? deletedId;
  bool? deleteForce;
  String exportResult = '/home/dev/shop/orb-worker-a1b2c3.tar.gz';
  String? exportedId;

  Session? createSessionResult = Session(
    id: 'ses_task',
    title: 'task',
    project: const SessionProject(id: 'prj_orb', name: 'orb'),
    created: 200,
    location: '/workspace',
    active: true,
    orb: 'a1b2c3',
  );

  @override
  Future<List<OrbRecord>> list({bool includePr = false}) async => listResult;

  @override
  Future<OrbRecord> wake(String id) async {
    wokenId = id;
    return wakeResult!;
  }

  @override
  Future<OrbRecord> create({
    required String project,
    required String name,
    required String checkout,
    String? base,
  }) async {
    createName = name;
    createBase = base;
    return createResult!;
  }

  @override
  Future<String?> seedBranch({
    required String project,
    required String seed,
    required String checkout,
  }) async {
    seedRequested = seed;
    final error = seedBranchError;
    if (error != null) throw error;
    return seedBranchResult;
  }

  @override
  Future<void> stop(String id) async {
    final error = stopError;
    if (error != null) throw error;
    stoppedId = id;
  }

  @override
  Future<void> delete(String id, {bool force = false}) async {
    deletedId = id;
    deleteForce = force;
  }

  @override
  Future<String> export(String id) async {
    exportedId = id;
    return exportResult;
  }

  @override
  Future<Session> createSessionOnOrb(String id) async => createSessionResult!;

  /// The composite event service's descriptor derivation reaches this at
  /// startup (bridge defaults); no orb actually runs in these tests.
  @override
  Future<String?> lastPassword(String id) async => null;

  /// The startup recovery (issue #102) and the lifecycle pass (#115) run at
  /// bridge startup/stop; no orb actually runs in these tests.
  @override
  Future<void> recover() async {}

  @override
  void startLifecyclePass({Duration? interval}) {}

  @override
  void stopLifecyclePass() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SessionDetail _detail(String id, {String? outcome}) => SessionDetail(
  id: id,
  title: 'task',
  location: '/workspace',
  cost: 0,
  tokens: const TokenUsage(
    input: 0,
    output: 0,
    reasoning: 0,
    cacheRead: 0,
    cacheWrite: 0,
  ),
  outcome: outcome,
);

void main() {
  late Directory temp;
  late File tasksFile;
  late _FakeOrbs orbs;
  late _FakeBackend backend;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('orb-spawn-endpoint');
    tasksFile = File('${temp.path}/tasks.json');
    orbs = _FakeOrbs();
    backend = _FakeBackend(_FakeOpencode());
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  Future<BridgeServer> serverWith({OrbTaskService? tasks}) =>
      BridgeServer.start(
        port: 0,
        health: () => const HealthReport(
          bridge: ComponentStatus.ok,
          opencode: ComponentStatus.ok,
          docker: ComponentStatus.ok,
        ),
        sessions: backend,
        orbs: orbs,
        tasks: tasks,
      );

  group('POST /api/orb/spawn', () {
    test('without a task service answers 503 opencode_unavailable', () async {
      final server = await serverWith(tasks: null);
      try {
        final (status, body) = await _postRaw(
          server.baseUri,
          '/api/orb/spawn',
          '{"task": "do it", "session": "ses_caller"}',
        );
        expect(status, 503);
        expect(jsonDecode(body), {'error': 'opencode_unavailable'});
      } finally {
        await server.stop();
      }
    });

    test('wait: false answers 201 with the dispatched task', () async {
      final tasks = OrbTaskService(
        orbs: orbs,
        sessions: backend,
        file: tasksFile,
      );
      backend.opencode.detailOf = (id) => _detail(id);
      final server = await serverWith(tasks: tasks);
      try {
        final (status, body) = await _postRaw(
          server.baseUri,
          '/api/orb/spawn',
          jsonEncode({
            'task': 'do the thing',
            'wait': false,
            'session': 'ses_caller',
            'directory': '/home/dev/shop',
          }),
        );
        expect(status, 201);
        final row = jsonDecode(body);
        expect(row['status'], 'running');
        expect(row['orb'], 'a1b2c3');
        expect(row['orbName'], 'worker');
        expect(row['branch'], 'orb/a1b2c3');
        expect(row['session'], 'ses_task');
        expect(row['caller'], 'ses_caller');
      } finally {
        await server.stop();
      }
    });

    test('wait: true (the default) answers the structured result', () async {
      final tasks = OrbTaskService(
        orbs: orbs,
        sessions: backend,
        file: tasksFile,
        pollInterval: const Duration(milliseconds: 5),
      );
      orbs.listResult = [
        _runningOrb(
          pr: const OrbPr(state: 'open', url: 'https://gh/pr/9'),
        ),
      ];
      backend.opencode.detailOf = (id) => _detail(id, outcome: 'succeeded');
      backend.opencode.messagesResult = const [
        SessionMessage(id: 'm', role: 'assistant', text: 'Shipped it.'),
      ];
      final server = await serverWith(tasks: tasks);
      try {
        final (status, body) = await _postRaw(
          server.baseUri,
          '/api/orb/spawn',
          jsonEncode({'task': 'do the thing', 'session': 'ses_caller'}),
        );
        expect(status, 200);
        final row = jsonDecode(body);
        expect(row['status'], 'succeeded');
        expect(row['summary'], 'Shipped it.');
        expect(row['results'], ['branch: orb/a1b2c3', 'PR: https://gh/pr/9']);
        expect(row['pr'], 'https://gh/pr/9');
        expect(row['completed'], isNotNull);
      } finally {
        await server.stop();
      }
    });

    test('a missing or blank task is a 400 invalid_body', () async {
      final tasks = OrbTaskService(
        orbs: orbs,
        sessions: backend,
        file: tasksFile,
      );
      final server = await serverWith(tasks: tasks);
      try {
        expect(
          (await _postRaw(server.baseUri, '/api/orb/spawn', '{}')).$1,
          400,
        );
        expect(
          (await _postRaw(
            server.baseUri,
            '/api/orb/spawn',
            '{"task": "  "}',
          )).$1,
          400,
        );
      } finally {
        await server.stop();
      }
    });

    test('an unresolvable caller is a 400 project_unknown', () async {
      final tasks = OrbTaskService(
        orbs: orbs,
        sessions: backend,
        file: tasksFile,
      );
      final server = await serverWith(tasks: tasks);
      try {
        final (status, body) = await _postRaw(
          server.baseUri,
          '/api/orb/spawn',
          '{"task": "do it", "wait": false, "session": "ses_gone"}',
        );
        expect(status, 400);
        expect(jsonDecode(body), {'error': 'project_unknown'});
      } finally {
        await server.stop();
      }
    });

    test('several orbs are a 409 orb_ambiguous listing the names', () async {
      final tasks = OrbTaskService(
        orbs: orbs,
        sessions: backend,
        file: tasksFile,
      );
      orbs.listResult = [
        _runningOrb(id: 'x1', name: 'alpha'),
        _runningOrb(id: 'x2', name: 'beta'),
      ];
      final server = await serverWith(tasks: tasks);
      try {
        final (status, body) = await _postRaw(
          server.baseUri,
          '/api/orb/spawn',
          '{"task": "do it", "wait": false, "session": "ses_caller"}',
        );
        expect(status, 409);
        expect(jsonDecode(body), {
          'error': 'orb_ambiguous',
          'orbs': ['alpha', 'beta'],
        });
      } finally {
        await server.stop();
      }
    });
  });

  group('POST /api/orb/wait', () {
    test('without a task service answers 503', () async {
      final server = await serverWith(tasks: null);
      try {
        final (status, body) = await _postRaw(
          server.baseUri,
          '/api/orb/wait',
          '{"id": "task_x"}',
        );
        expect(status, 503);
        expect(jsonDecode(body), {'error': 'opencode_unavailable'});
      } finally {
        await server.stop();
      }
    });

    test('an unknown task id is a 404', () async {
      final tasks = OrbTaskService(
        orbs: orbs,
        sessions: backend,
        file: tasksFile,
      );
      final server = await serverWith(tasks: tasks);
      try {
        final (status, _) = await _postRaw(
          server.baseUri,
          '/api/orb/wait',
          '{"id": "task_nope"}',
        );
        expect(status, 404);
      } finally {
        await server.stop();
      }
    });

    test('a missing id is a 400 invalid_body', () async {
      final tasks = OrbTaskService(
        orbs: orbs,
        sessions: backend,
        file: tasksFile,
      );
      final server = await serverWith(tasks: tasks);
      try {
        expect((await _postRaw(server.baseUri, '/api/orb/wait', '{}')).$1, 400);
      } finally {
        await server.stop();
      }
    });

    test(
      'waits the dispatched task and answers the structured result',
      () async {
        final tasks = OrbTaskService(
          orbs: orbs,
          sessions: backend,
          file: tasksFile,
          pollInterval: const Duration(milliseconds: 5),
        );
        backend.opencode.detailOf = (id) => _detail(id);
        final server = await serverWith(tasks: tasks);
        try {
          final (_, spawnBody) = await _postRaw(
            server.baseUri,
            '/api/orb/spawn',
            '{"task": "do the thing", "wait": false, "session": "ses_caller"}',
          );
          final id = jsonDecode(spawnBody)['id'] as String;

          // The orb session's turn ends; the wait completes.
          backend.opencode.detailOf = (id2) =>
              _detail(id2, outcome: 'succeeded');
          backend.opencode.messagesResult = const [
            SessionMessage(id: 'm', role: 'assistant', text: 'All done.'),
          ];

          final (status, body) = await _postRaw(
            server.baseUri,
            '/api/orb/wait',
            jsonEncode({'id': id}),
          );
          expect(status, 200);
          final row = jsonDecode(body);
          expect(row['id'], id);
          expect(row['status'], 'succeeded');
          expect(row['summary'], 'All done.');
          expect(row['branch'], 'orb/a1b2c3');
        } finally {
          await server.stop();
        }
      },
    );

    test('a task of another agent is a 403 (tree-scoped wait right)', () async {
      final tasks = OrbTaskService(
        orbs: orbs,
        sessions: backend,
        file: tasksFile,
      );
      backend.opencode.detailOf = (id) => _detail(id);
      final server = await serverWith(tasks: tasks);
      try {
        // ses_caller dispatches the task (no orb existed → its tree).
        final (_, spawnBody) = await _postRaw(
          server.baseUri,
          '/api/orb/spawn',
          '{"task": "do the thing", "wait": false, "session": "ses_caller"}',
        );
        final id = jsonDecode(spawnBody)['id'] as String;
        // Another agent (no relation to the tree) waits it: refused.
        final (status, body) = await _postRaw(
          server.baseUri,
          '/api/orb/wait',
          jsonEncode({'id': id, 'session': 'ses_other'}),
        );
        expect(status, 403);
        expect(jsonDecode(body)['error'], 'permission_denied');
      } finally {
        await server.stop();
      }
    });

    test(
      'the task owner always waits their own task (spawned orb tree)',
      () async {
        final tasks = OrbTaskService(
          orbs: orbs,
          sessions: backend,
          file: tasksFile,
          pollInterval: const Duration(milliseconds: 5),
        );
        orbs.listResult = const [];
        orbs.createResult = _runningOrb();
        backend.opencode.detailOf = (id) => _detail(id, outcome: 'succeeded');
        final server = await serverWith(tasks: tasks);
        try {
          final (_, spawnBody) = await _postRaw(
            server.baseUri,
            '/api/orb/spawn',
            '{"task": "do it", "wait": false, "session": "ses_caller"}',
          );
          final id = jsonDecode(spawnBody)['id'] as String;
          final (status, body) = await _postRaw(
            server.baseUri,
            '/api/orb/wait',
            jsonEncode({'id': id, 'session': 'ses_caller'}),
          );
          expect(status, 200);
          expect(jsonDecode(body)['status'], 'succeeded');
        } finally {
          await server.stop();
        }
      },
    );
  });

  group('POST /api/orb/stop|delete|export (issue #100)', () {
    OrbTaskService tasksService() =>
        OrbTaskService(orbs: orbs, sessions: backend, file: tasksFile);

    test('an unknown orb reference is a 404', () async {
      final server = await serverWith(tasks: tasksService());
      try {
        final (status, _) = await _postRaw(
          server.baseUri,
          '/api/orb/stop',
          '{"orb": "nope", "session": "ses_caller"}',
        );
        expect(status, 404);
      } finally {
        await server.stop();
      }
    });

    test('the human (no session) stops an orb by name', () async {
      final server = await serverWith(tasks: tasksService());
      try {
        final (status, _) = await _postRaw(
          server.baseUri,
          '/api/orb/stop',
          '{"orb": "worker"}',
        );
        expect(status, 204);
        expect(orbs.stoppedId, 'a1b2c3');
      } finally {
        await server.stop();
      }
    });

    test('an agent stops an orb it created (its tree)', () async {
      final tasks = tasksService();
      // The caller creates the orb first (the spawn attaches the tree edge).
      orbs.listResult = const [];
      orbs.createResult = _runningOrb();
      backend.opencode.detailOf = (id) => _detail(id);
      final server = await serverWith(tasks: tasks);
      try {
        await _postRaw(
          server.baseUri,
          '/api/orb/spawn',
          '{"task": "do it", "wait": false, "session": "ses_caller"}',
        );
        orbs.listResult = [_runningOrb()];
        orbs.stoppedId = null;
        final (status, _) = await _postRaw(
          server.baseUri,
          '/api/orb/stop',
          '{"orb": "worker", "session": "ses_caller"}',
        );
        expect(status, 204);
        expect(orbs.stoppedId, 'a1b2c3');
      } finally {
        await server.stop();
      }
    });

    test(
      'an agent stops nothing it did not create (403 permission_denied)',
      () async {
        // The orb exists from the start (human-created): no creating record.
        final server = await serverWith(tasks: tasksService());
        try {
          final (status, body) = await _postRaw(
            server.baseUri,
            '/api/orb/stop',
            '{"orb": "worker", "session": "ses_caller"}',
          );
          expect(status, 403);
          expect(jsonDecode(body)['error'], 'permission_denied');
          expect(orbs.stoppedId, isNull);
        } finally {
          await server.stop();
        }
      },
    );

    test(
      'the agent delete passes force through to the guarded deletion',
      () async {
        final tasks = tasksService();
        orbs.listResult = const [];
        orbs.createResult = _runningOrb();
        backend.opencode.detailOf = (id) => _detail(id);
        final server = await serverWith(tasks: tasks);
        try {
          await _postRaw(
            server.baseUri,
            '/api/orb/spawn',
            '{"task": "do it", "wait": false, "session": "ses_caller"}',
          );
          orbs.listResult = [_runningOrb()];
          final (status, _) = await _postRaw(
            server.baseUri,
            '/api/orb/delete',
            '{"orb": "worker", "force": true, "session": "ses_caller"}',
          );
          expect(status, 204);
          expect(orbs.deletedId, 'a1b2c3');
          expect(orbs.deleteForce, isTrue);
        } finally {
          await server.stop();
        }
      },
    );

    test('the agent export answers the archive path', () async {
      final tasks = tasksService();
      orbs.listResult = const [];
      orbs.createResult = _runningOrb();
      backend.opencode.detailOf = (id) => _detail(id);
      final server = await serverWith(tasks: tasks);
      try {
        await _postRaw(
          server.baseUri,
          '/api/orb/spawn',
          '{"task": "do it", "wait": false, "session": "ses_caller"}',
        );
        orbs.listResult = [_runningOrb()];
        final (status, body) = await _postRaw(
          server.baseUri,
          '/api/orb/export',
          '{"orb": "worker", "session": "ses_caller"}',
        );
        expect(status, 200);
        expect(jsonDecode(body)['path'], orbs.exportResult);
        expect(orbs.exportedId, 'a1b2c3');
      } finally {
        await server.stop();
      }
    });
  });
}
