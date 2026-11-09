// The spawn surface's task service (issue #99, spec §8.2/§8.3): the
// wake-or-create on the project's orb, the dispatch, the completion with the
// structured result, the persisted tasks file, and the completion injection
// into the calling session.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/orb/orb_service.dart';
import 'package:opencodebridge/bridge/orb/orb_task_service.dart';
import 'package:opencodebridge/bridge/sessions/backend.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';
import 'package:opencodebridge/model/command.dart';
import 'package:opencodebridge/model/message.dart';
import 'package:opencodebridge/model/orb.dart';
import 'package:opencodebridge/model/permission.dart';
import 'package:opencodebridge/model/session.dart';
import 'package:opencodebridge/model/session_detail.dart';

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

OrbRecord _stoppedOrb({String id = 'a1b2c3', String name = 'worker'}) =>
    OrbRecord(
      id: id,
      name: name,
      project: 'prj_1',
      branch: 'orb/$id',
      state: 'stopped',
      created: '2026-01-01T00:00:00.000Z',
    );

Session _taskSession({String id = 'ses_task'}) => Session(
  id: id,
  title: 'task',
  project: const SessionProject(id: 'prj_orb', name: 'orb'),
  created: 200,
  location: '/workspace',
  active: true,
  orb: 'a1b2c3',
);

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

/// The scripted [OpencodeService] the [SessionsBackend] fake delegates the
/// per-session operations to (the same seam style as the endpoint tests).
class _FakeOpencode extends OpencodeService {
  ModelRef? currentModelResult;
  ModelRef? setModelCall;
  SessionDetail Function(String id) detailOf = (id) =>
      throw StateError('getDetail not scripted');
  List<SessionMessage> messagesResult = const [];

  /// Session ids whose `prompt` fails (a dead calling session).
  final Set<String> failingPrompts = {};

  /// The service's active list (issue #169's idle settle reads it through
  /// the backend's detailWithActive).
  Set<String> activeIds = {};

  /// The scriptable pending-permissions answer (issue #169: a parked
  /// permission holds the idle settle).
  List<PermissionRequest> pendingPermissionsResult = const [];

  /// Script `getDetail` to throw (issue #169's missing/transient paths).
  Object? detailError;

  /// Every `prompt` the fake received: (session id, text).
  final List<(String, String)> prompts = [];

  @override
  Future<List<OpencodeProject>> projects() async => [_project];

  @override
  Future<Set<String>> activeSessionIds() async => activeIds;

  @override
  Future<void> prompt(
    String id,
    String text, {
    List<Map<String, Object?>>? files,
    List<Map<String, Object?>>? skills,
  }) async {
    prompts.add((id, text));
    if (failingPrompts.contains(id)) {
      throw const OpencodeServiceError(404, 'no such session');
    }
  }

  @override
  Future<SessionDetail> getDetail(String id) async {
    final error = detailError;
    if (error != null) throw error;
    return detailOf(id);
  }

  @override
  Future<List<SessionMessage>> getMessages(String id) async => messagesResult;

  @override
  Future<List<PermissionRequest>> pendingPermissions(String id) async =>
      pendingPermissionsResult;

  @override
  Future<ModelRef?> currentModel(String id) async => currentModelResult;

  @override
  Future<void> setModel(String id, ModelRef model) async {
    setModelCall = model;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The scripted [SessionsBackend]: the home-list rows and everything the fake
/// opencode service scripts.
class _FakeBackend extends SessionsBackend {
  _FakeBackend(this.opencode) : super(service: opencode);

  final _FakeOpencode opencode;
  List<Session> rows = [_callerRow];

  @override
  Future<List<Session>> list() async => rows;
}

/// A second caller in the same project (issue #147's attribution rows).
final _callerBRow = Session(
  id: 'ses_b',
  title: 'caller B',
  project: const SessionProject(id: 'prj_1', name: 'shop'),
  created: 101,
  location: '/home/dev/shop',
  active: false,
);

/// The scripted [OrbService]: the orb list, the wake, the create, and the
/// per-orb session create record their calls and return scripted results.
class _FakeOrbs implements OrbService {
  List<OrbRecord> listResult = const [];
  bool? lastListIncludePr;

  OrbRecord? wakeResult;
  String? wokenId;

  OrbRecord? createResult;
  String? createProject;
  String? createName;
  String? createCheckout;
  String? createBase;

  /// The scripted `seedBranch` result; [seedBranchError] throws instead.
  String? seedBranchResult;
  Object? seedBranchError;
  (String, String, String)? seedBranchCall;

  Session? createSessionResult;
  String? createSessionOrbId;
  int createSessionCalls = 0;

  @override
  Future<List<OrbRecord>> list({bool includePr = false}) async {
    lastListIncludePr = includePr;
    return listResult;
  }

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
    createProject = project;
    createName = name;
    createCheckout = checkout;
    createBase = base;
    return createResult!;
  }

  @override
  Future<Session> createSessionOnOrb(String id) async {
    createSessionCalls++;
    createSessionOrbId = id;
    // Every dispatch is a fresh session on the orb's service: the scripted
    // text/fields with a distinct id (issue #147's two-task tests).
    final result = createSessionResult!;
    return Session(
      id: createSessionCalls == 1
          ? result.id
          : '${result.id}_$createSessionCalls',
      title: result.title,
      project: result.project,
      created: result.created,
      location: result.location,
      active: result.active,
      orb: result.orb,
    );
  }

  @override
  Future<String?> seedBranch({
    required String project,
    required String seed,
    required String checkout,
  }) async {
    seedBranchCall = (project, seed, checkout);
    final error = seedBranchError;
    if (error != null) throw error;
    return seedBranchResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory temp;
  late File tasksFile;
  late _FakeOrbs orbs;
  late _FakeBackend backend;
  late OrbTaskService service;
  late Duration waitGrace;
  late Duration settleIdleWindow;
  late Duration settleMissingWindow;

  /// Every service a test builds (the completion watcher polls on its own):
  /// torn down with the temp dir, so no writer outlives it.
  final services = <OrbTaskService>[];

  OrbTaskService newService() {
    final created = OrbTaskService(
      orbs: orbs,
      sessions: backend,
      file: tasksFile,
      pollInterval: const Duration(milliseconds: 5),
      waitGrace: waitGrace,
      settleIdleWindow: settleIdleWindow,
      settleMissingWindow: settleMissingWindow,
    );
    services.add(created);
    return created;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('orb-tasks');
    tasksFile = File('${temp.path}/tasks.json');
    orbs = _FakeOrbs();
    backend = _FakeBackend(_FakeOpencode());
    waitGrace = const Duration(seconds: 1);
    settleIdleWindow = const Duration(seconds: 30);
    settleMissingWindow = const Duration(seconds: 30);
    service = newService();
  });

  tearDown(() async {
    // The watchers first: an in-flight completion pass (done before close
    // bites) still persists into the temp dir, so it settles before the
    // dir goes. The delete then tolerates a straggler write outright.
    for (final created in services) {
      created.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    services.clear();
    try {
      await temp.delete(recursive: true);
    } on FileSystemException {
      // A watcher write landed mid-delete: the OS reaps the dir.
    }
  });

  /// Script the dispatch seams: a task session on orb `a1b2c3` whose turn
  /// never reports an outcome (a plain dispatch; the completion checks keep
  /// finding nothing).
  void scriptDispatch() {
    orbs.createSessionResult = _taskSession();
    backend.opencode.detailOf = (id) => _detail(id);
  }

  /// Script a task that completes with [outcome] when its detail is read.
  void scriptCompletedTask({String outcome = 'succeeded'}) {
    orbs.listResult = [
      _runningOrb(
        pr: const OrbPr(state: 'open', url: 'https://gh/pr/1'),
      ),
    ];
    scriptDispatch();
    backend.opencode.detailOf = (id) => _detail(id, outcome: outcome);
    backend.opencode.messagesResult = [
      const SessionMessage(id: 'm1', role: 'user', text: 'do the thing'),
      const SessionMessage(id: 'm2', role: 'assistant', text: 'All done.'),
    ];
  }

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condition not met before the deadline');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  group('wake-or-create', () {
    test('no orb in the project creates one named from the task', () async {
      orbs.listResult = const [];
      orbs.createResult = _runningOrb(name: 'fix-login');
      scriptDispatch();

      final task = await service.spawn(
        task: 'Fix login',
        wait: false,
        callerSession: 'ses_caller',
      );

      expect(orbs.createProject, 'prj_1');
      expect(orbs.createName, 'fix-login');
      expect(orbs.createCheckout, '/home/dev/shop');
      expect(task.orbName, 'fix-login');
      expect(task.status, 'running');
      expect(service.task(task.id), same(task));
    });

    test('a multi-word task derives a short kebab name', () async {
      orbs.listResult = const [];
      orbs.createResult = _runningOrb(name: 'fix-login');
      scriptDispatch();

      final derived = await service.spawn(
        task: 'fix the login!!',
        wait: false,
        callerDirectory: '/home/dev/shop',
      );
      // Three words max, lowercased, non-alphanumerics dashed.
      expect(orbs.createName, 'fix-the-login');
      expect(derived.orbName, 'fix-login');
    });

    test('one stopped orb is woken, not created', () async {
      orbs.listResult = [_stoppedOrb()];
      orbs.wakeResult = _runningOrb();
      scriptDispatch();

      final task = await service.spawn(
        task: 'do the thing',
        wait: false,
        callerSession: 'ses_caller',
      );

      expect(orbs.wokenId, 'a1b2c3');
      expect(orbs.createProject, isNull);
      expect(task.orb, 'a1b2c3');
      expect(task.branch, 'orb/a1b2c3');
    });

    test('one running orb is used as-is (idempotent wake)', () async {
      orbs.listResult = [_runningOrb()];
      scriptDispatch();

      final task = await service.spawn(
        task: 'do the thing',
        wait: false,
        callerSession: 'ses_caller',
      );

      expect(orbs.wokenId, isNull);
      expect(orbs.createProject, isNull);
      expect(task.orb, 'a1b2c3');
    });

    test('several orbs refuse and list the names', () async {
      orbs.listResult = [
        _runningOrb(id: 'x1', name: 'alpha'),
        _runningOrb(id: 'x2', name: 'beta'),
      ];

      await expectLater(
        service.spawn(task: 'do it', wait: false, callerSession: 'ses_caller'),
        throwsA(
          isA<OrbAmbiguousError>().having((e) => e.names, 'names', [
            'alpha',
            'beta',
          ]),
        ),
      );
    });

    test('a broken orb refuses the spawn', () async {
      orbs.listResult = [
        OrbRecord(
          id: 'x1',
          name: 'alpha',
          project: 'prj_1',
          branch: 'orb/x1',
          state: 'broken:workspace',
          created: '2026-01-01T00:00:00.000Z',
        ),
      ];

      await expectLater(
        service.spawn(task: 'do it', wait: false, callerSession: 'ses_caller'),
        throwsA(isA<OrbRefusalError>()),
      );
    });

    test('an unknown caller session and directory refuse the spawn', () async {
      await expectLater(
        service.spawn(task: 'do it', wait: false, callerSession: 'ses_gone'),
        throwsA(isA<OrbSpawnProjectError>()),
      );
      await expectLater(
        service.spawn(task: 'do it', wait: false),
        throwsA(isA<OrbSpawnProjectError>()),
      );
    });

    test(
      'the caller directory resolves the project without a session',
      () async {
        backend.rows = const []; // The caller is not a listed session.
        orbs.listResult = [_runningOrb()];
        scriptDispatch();

        final task = await service.spawn(
          task: 'do the thing',
          wait: false,
          callerDirectory: '/home/dev/shop',
        );
        expect(task.orb, 'a1b2c3');
      },
    );

    test(
      'a caller inside an orb resolves the project through the orb row',
      () async {
        // The nested spawn (spec §1.4): the caller is a session on the orb's
        // service, whose row carries the ORB-side project id — the host
        // project comes from the orb's record.
        backend.rows = [
          Session(
            id: 'ses_in_orb',
            title: 'in-orb caller',
            project: const SessionProject(id: 'prj_in_orb', name: 'workspace'),
            created: 150,
            location: '/workspace',
            active: true,
            orb: 'a1b2c3',
          ),
        ];
        orbs.listResult = [_runningOrb()];
        scriptDispatch();

        final task = await service.spawn(
          task: 'do the thing',
          wait: false,
          callerSession: 'ses_in_orb',
        );
        expect(task.orb, 'a1b2c3');
      },
    );
  });

  // The targeting + seed + spawn-tree rows (issue #100, spec §8.2/§3.3).
  OrbRecord stoppedNamed(String name, {String id = 'd4e5f6'}) => OrbRecord(
    id: id,
    name: name,
    project: 'prj_1',
    branch: 'orb/$id',
    state: 'stopped',
    created: '2026-01-01T00:00:00.000Z',
  );

  group('orb targeting (issue #100)', () {
    test('an explicit name already taken targets that orb', () async {
      orbs.listResult = [
        _runningOrb(id: 'x1', name: 'alpha'),
        stoppedNamed('beta', id: 'x2'),
      ];
      orbs.wakeResult = _runningOrb(id: 'x2', name: 'beta');
      scriptDispatch();

      final task = await service.spawn(
        task: 'do it',
        orb: 'beta',
        wait: false,
        callerSession: 'ses_caller',
      );

      expect(orbs.wokenId, 'x2');
      expect(orbs.createName, isNull);
      expect(task.orb, 'x2');
      expect(task.orbName, 'beta');
    });

    test('an explicit unused name creates the additional orb', () async {
      orbs.listResult = [_runningOrb(id: 'x1', name: 'alpha')];
      orbs.createResult = _runningOrb(id: 'x2', name: 'variant');
      scriptDispatch();

      final task = await service.spawn(
        task: 'do it',
        orb: 'variant',
        wait: false,
        callerSession: 'ses_caller',
      );

      // No ambiguity check on an explicit name: the single orb in the
      // project is not woken; the fresh clone is created instead.
      expect(orbs.wokenId, isNull);
      expect(orbs.createName, 'variant');
      expect(orbs.createCheckout, '/home/dev/shop');
      expect(orbs.createBase, isNull);
      expect(task.orb, 'x2');
      expect(task.createdOrb, isTrue);
    });

    test('the created orb is attached to the caller spawn tree', () async {
      orbs.listResult = const [];
      orbs.createResult = _runningOrb(name: 'do-it');
      scriptDispatch();

      final task = await service.spawn(
        task: 'do it',
        wait: false,
        callerSession: 'ses_caller',
      );
      expect(task.createdOrb, isTrue);

      // The caller's tree now contains the orb it created.
      expect(
        await service.canControl(callerSession: 'ses_caller', orbId: task.orb),
        isTrue,
      );
      // Another agent's session never sees it.
      expect(
        await service.canControl(callerSession: 'ses_other', orbId: task.orb),
        isFalse,
      );
      // The human (no session) is unrestricted.
      expect(
        await service.canControl(callerSession: null, orbId: task.orb),
        isTrue,
      );
    });

    test('an edge whose caller is unknown controls nothing', () async {
      orbs.listResult = const [];
      orbs.createResult = _runningOrb(name: 'do-it');
      scriptDispatch();

      final task = await service.spawn(
        task: 'do it',
        wait: false,
        callerSession: 'ses_caller',
      );
      expect(task.createdOrb, isTrue);

      // The creating session disappears from the bridge's view (deleted):
      // no session resolves to the edge, so no agent controls the orb —
      // only the human does.
      backend.rows = const [];
      expect(
        await service.canControl(callerSession: 'ses_caller', orbId: task.orb),
        isTrue, // the edge's session id still matches the caller's id
      );
      expect(
        await service.canControl(callerSession: 'ses_other', orbId: task.orb),
        isFalse,
      );
    });
  });

  group('seed (issue #100, spec §3.3)', () {
    test(
      'a seeded clone starts from the seed branch and stacks the PR',
      () async {
        orbs.listResult = [_runningOrb(id: 'xB', name: 'parent')];
        orbs.seedBranchResult = 'orb/xB';
        // The real OrbService.create returns the record carrying its base.
        orbs.createResult = OrbRecord(
          id: 'xC',
          name: 'variant',
          project: 'prj_1',
          branch: 'orb/xC',
          state: 'running',
          created: '2026-01-01T00:00:00.000Z',
          url: 'http://127.0.0.1:9999',
          base: 'orb/xB',
        );
        scriptDispatch();

        final task = await service.spawn(
          task: 'variant work',
          orb: 'variant',
          seed: 'parent',
          wait: false,
          callerSession: 'ses_caller',
        );

        expect(orbs.seedBranchCall?.$2, 'parent');
        expect(orbs.createBase, 'orb/xB');
        expect(task.orb, 'xC');
        // The stacking contract (spec §3.2) is the record's base: the PR
        // stacks on the seed's branch, not the default. The orb's agent is
        // prompted with exactly the caller's text (issue #147) — the prompt
        // preamble is gone.
        final prompt = backend.opencode.prompts.last.$2;
        expect(prompt, 'variant work');
      },
    );

    test('a seed naming no orb of the project is refused', () async {
      orbs.listResult = [_runningOrb(id: 'xB', name: 'parent')];
      orbs.seedBranchResult = null; // OrbService: no such orb in the project.

      await expectLater(
        service.spawn(
          task: 'do it',
          orb: 'variant',
          seed: 'ghost',
          wait: false,
          callerSession: 'ses_caller',
        ),
        throwsA(isA<OrbRefusalError>()),
      );
      expect(orbs.createName, isNull);
    });

    test('a seed whose branch was never pushed is refused', () async {
      orbs.seedBranchError = const OrbRefusalError(
        OrbRefusalError.seedNotPushed,
        'not pushed',
      );

      await expectLater(
        service.spawn(
          task: 'do it',
          orb: 'variant',
          seed: 'parent',
          wait: false,
          callerSession: 'ses_caller',
        ),
        throwsA(
          isA<OrbRefusalError>().having(
            (e) => e.code,
            'code',
            OrbRefusalError.seedNotPushed,
          ),
        ),
      );
    });

    test('a seed with an existing target orb is refused', () async {
      orbs.listResult = [_runningOrb(id: 'xB', name: 'parent')];

      await expectLater(
        service.spawn(
          task: 'do it',
          orb: 'parent',
          seed: 'parent',
          wait: false,
          callerSession: 'ses_caller',
        ),
        throwsA(
          isA<OrbRefusalError>().having(
            (e) => e.code,
            'code',
            OrbRefusalError.seedConflict,
          ),
        ),
      );
    });

    test('a seed without a target name is refused', () async {
      orbs.listResult = [_runningOrb(id: 'xB', name: 'parent')];

      await expectLater(
        service.spawn(
          task: 'do it',
          seed: 'parent',
          wait: false,
          callerSession: 'ses_caller',
        ),
        throwsA(
          isA<OrbRefusalError>().having(
            (e) => e.code,
            'code',
            OrbRefusalError.seedConflict,
          ),
        ),
      );
    });
  });

  group('spawn-tree permissions (issue #100, spec §8.4)', () {
    /// A in-orb session on orb [orbId] as the backend sees it.
    Session inOrbSession(String id, String orbId) => Session(
      id: id,
      title: 'task',
      project: const SessionProject(id: 'prj_orb', name: 'orb'),
      created: 300,
      location: '/workspace',
      active: true,
      orb: orbId,
    );

    test(
      'the tree is transitive: A spawns B, B spawns C, C is A tree',
      () async {
        // A (ses_caller) spawns B.
        orbs.listResult = const [];
        orbs.createResult = _runningOrb(id: 'orbB', name: 'b');
        scriptDispatch();
        await service.spawn(
          task: 'b work',
          wait: false,
          callerSession: 'ses_caller',
        );

        // B's agent (ses_b, a session on orbB) spawns C.
        backend.rows = [_callerRow, inOrbSession('ses_b', 'orbB')];
        orbs.listResult = [_runningOrb(id: 'orbB', name: 'b')];
        orbs.createResult = _runningOrb(id: 'orbC', name: 'c');
        await service.spawn(
          task: 'c work',
          orb: 'c',
          wait: false,
          callerSession: 'ses_b',
        );

        // C is in B's tree and (transitively) in A's.
        expect(
          await service.canControl(callerSession: 'ses_b', orbId: 'orbC'),
          isTrue,
        );
        expect(
          await service.canControl(callerSession: 'ses_caller', orbId: 'orbC'),
          isTrue,
        );
        // B's agent cannot stop B — its own orb is outside its tree.
        expect(
          await service.canControl(callerSession: 'ses_b', orbId: 'orbB'),
          isFalse,
        );
        // A can stop B (it created it).
        expect(
          await service.canControl(callerSession: 'ses_caller', orbId: 'orbB'),
          isTrue,
        );
      },
    );

    test(
      'the tree survives moves: a moved session keeps control by id',
      () async {
        orbs.listResult = const [];
        orbs.createResult = _runningOrb(name: 'do-it');
        scriptDispatch();
        final task = await service.spawn(
          task: 'do it',
          wait: false,
          callerSession: 'ses_caller',
        );

        // The session is moved to the host (and its row disappears from the
        // in-orb listing entirely / lives host-side with the SAME id): the
        // edge stays by session id.
        backend.rows = [
          Session(
            id: 'ses_caller',
            title: 'moved caller',
            project: const SessionProject(id: 'prj_1', name: 'shop'),
            created: 100,
            location: '/home/dev/shop',
            active: true,
          ),
        ];
        expect(
          await service.canControl(
            callerSession: 'ses_caller',
            orbId: task.orb,
          ),
          isTrue,
        );
      },
    );

    test('a human-created orb is outside every agent tree', () async {
      // The orb exists without any creating task record.
      orbs.listResult = [_runningOrb()];
      expect(
        await service.canControl(callerSession: 'ses_caller', orbId: 'a1b2c3'),
        isFalse,
      );
      // The human is unrestricted.
      expect(
        await service.canControl(callerSession: null, orbId: 'a1b2c3'),
        isTrue,
      );
    });

    test(
      'wait rights are tree-scoped, the dispatch owner always passes',
      () async {
        orbs.listResult = const [];
        orbs.createResult = _runningOrb();
        scriptDispatch();
        final task = await service.spawn(
          task: 'do it',
          wait: false,
          callerSession: 'ses_caller',
        );

        // The dispatch owner always waits its own task.
        final settled = service.wait(task.id, callerSession: 'ses_caller');
        // (The task never completes here; just the check passing to the poll.)
        expect(
          await service.canControl(
            callerSession: 'ses_caller',
            orbId: task.orb,
          ),
          isTrue,
        );
        settled.ignore();

        await expectLater(
          service.wait(task.id, callerSession: 'ses_intruder'),
          throwsA(isA<OrbPermissionError>()),
        );
      },
    );
  });

  group('the shell refusal (issue #149)', () {
    test('a shell-less orb refuses the spawn with its boot reason, settles '
        'refused, and dispatches nothing', () async {
      // The orb's boot failed at the shell probe: it exists, but its agent
      // cannot run a command — dispatching would only buy a well-written
      // "I can't".
      orbs.listResult = [
        OrbRecord(
          id: 'a1b2c3',
          name: 'worker',
          project: 'prj_1',
          branch: 'orb/a1b2c3',
          state: 'broken:shell',
          bootReason:
              'FATAL: no usable shell — the agent could not run a command',
          created: '2026-01-01T00:00:00.000Z',
        ),
      ];

      await expectLater(
        service.spawn(
          task: 'do the thing',
          orb: 'worker',
          wait: false,
          callerSession: 'ses_caller',
        ),
        throwsA(
          isA<OrbRefusalError>()
              .having((e) => e.code, 'code', OrbRefusalError.noShell)
              .having((e) => e.message, 'message', contains('no usable shell')),
        ),
      );
      // Nothing was created or dispatched onto the orb, and no task record
      // claims it is running somewhere.
      expect(orbs.createSessionCalls, 0);
      expect(backend.opencode.prompts, isEmpty);
      expect(service.tasks.where((t) => t.status == 'running'), isEmpty);
    });

    test('a create that boots shell-less settles refused with the reason and '
        'dispatches nothing', () async {
      orbs.listResult = const [];
      orbs.createResult = OrbRecord(
        id: 'a1b2c3',
        name: 'fix-login',
        project: 'prj_1',
        branch: 'orb/a1b2c3',
        state: 'broken:shell',
        bootReason: 'FATAL: no usable shell',
        created: '2026-01-01T00:00:00.000Z',
      );

      final task = await service.spawn(
        task: 'Fix login',
        wait: false,
        callerSession: 'ses_caller',
      );
      expect(task.status, 'refused');
      expect(task.isDone, isTrue);
      expect(task.summary, contains('no usable shell'));
      expect(task.session, isEmpty, reason: 'no session to attach to');
      expect(orbs.createSessionCalls, 0);
      expect(backend.opencode.prompts, isEmpty);
      // It is the persisted record a later `orb_wait` reads back.
      expect(service.task(task.id)!.status, 'refused');
      expect(service.task(task.id)!.summary, contains('no usable shell'));
    });

    test(
      'the single-orb wake-or-create refuses a shell-less orb the same way',
      () async {
        orbs.listResult = [
          OrbRecord(
            id: 'a1b2c3',
            name: 'worker',
            project: 'prj_1',
            branch: 'orb/a1b2c3',
            state: 'broken:shell',
            bootReason: 'no usable shell',
            created: '2026-01-01T00:00:00.000Z',
          ),
        ];

        await expectLater(
          service.spawn(
            task: 'do the thing',
            wait: false,
            callerSession: 'ses_caller',
          ),
          throwsA(
            isA<OrbRefusalError>().having(
              (e) => e.code,
              'code',
              OrbRefusalError.noShell,
            ),
          ),
        );
        expect(orbs.createSessionCalls, 0);
        expect(backend.opencode.prompts, isEmpty);
      },
    );
  });

  group('dispatch', () {
    setUp(() {
      orbs.listResult = [_runningOrb()];
    });

    test(
      'dispatch is one fresh session per task with the task prompt',
      () async {
        scriptDispatch();

        final task = await service.spawn(
          task: 'do the thing',
          wait: false,
          callerSession: 'ses_caller',
        );

        expect(orbs.createSessionOrbId, 'a1b2c3');
        expect(task.session, 'ses_task');
        final prompt = backend.opencode.prompts.single;
        expect(prompt.$1, 'ses_task');
        // Exactly the caller's text (issue #147): no prompt preamble glued in.
        expect(prompt.$2, 'do the thing');
      },
    );

    test(
      'a shell-less orb is never handed the task text (issue #149)',
      () async {
        orbs.listResult = [
          OrbRecord(
            id: 'a1b2c3',
            name: 'worker',
            project: 'prj_1',
            branch: 'orb/a1b2c3',
            state: 'broken:shell',
            bootReason: 'no usable shell',
            created: '2026-01-01T00:00:00.000Z',
          ),
        ];
        scriptDispatch();

        // The spawn refuses before the dispatch (issue #149): the task text is
        // never handed to an agent that cannot run a command in it.
        await expectLater(
          service.spawn(
            task: 'do the thing',
            wait: false,
            callerSession: 'ses_caller',
          ),
          throwsA(isA<OrbRefusalError>()),
        );
        expect(backend.opencode.prompts, isEmpty);
      },
    );

    test('the model defaults to the calling session model', () async {
      scriptDispatch();
      backend.opencode.currentModelResult = const ModelRef(
        id: 'glm-4.7',
        providerId: 'zhipu',
      );

      await service.spawn(
        task: 'do it',
        wait: false,
        callerSession: 'ses_caller',
      );
      expect(
        backend.opencode.setModelCall,
        const ModelRef(id: 'glm-4.7', providerId: 'zhipu'),
      );
    });

    test('an explicit model overrides the caller model', () async {
      scriptDispatch();
      backend.opencode.currentModelResult = const ModelRef(
        id: 'glm-4.7',
        providerId: 'zhipu',
      );

      await service.spawn(
        task: 'do it',
        wait: false,
        callerSession: 'ses_caller',
        model: const ModelRef(id: 'gpt-5.2', providerId: 'openai'),
      );
      expect(
        backend.opencode.setModelCall,
        const ModelRef(id: 'gpt-5.2', providerId: 'openai'),
      );
    });

    test('a failed dispatch prompt settles the task failed', () async {
      scriptDispatch();
      // The task session's prompt fails (the orb service refuses).
      backend.opencode.failingPrompts.add('ses_task');

      await expectLater(
        service.spawn(
          task: 'do the thing',
          wait: false,
          callerSession: 'ses_caller',
        ),
        throwsA(isA<OpencodeServiceError>()),
      );
      final persisted = jsonDecode(tasksFile.readAsStringSync());
      expect(persisted[0]['status'], 'failed');
      expect(persisted[0]['completed'], isNotNull);
    });
  });

  group('completion', () {
    test('wait: true blocks and returns the structured result', () async {
      scriptCompletedTask();

      final task = await service.spawn(
        task: 'do the thing',
        callerSession: 'ses_caller',
      );

      expect(task.status, 'succeeded');
      expect(task.summary, 'All done.');
      expect(task.branch, 'orb/a1b2c3');
      expect(task.pr, 'https://gh/pr/1');
      expect(task.results, ['branch: orb/a1b2c3', 'PR: https://gh/pr/1']);
      expect(task.isDone, isTrue);
    });

    test('wait: true with no PR yields the branch only', () async {
      scriptCompletedTask();
      orbs.listResult = [_runningOrb()]; // No PR on the branch.

      final task = await service.spawn(
        task: 'do the thing',
        callerSession: 'ses_caller',
      );
      expect(task.pr, isNull);
      expect(task.results, ['branch: orb/a1b2c3']);
    });

    test('the failed outcome is the task status', () async {
      scriptCompletedTask(outcome: 'failed');

      final task = await service.spawn(
        task: 'do the thing',
        callerSession: 'ses_caller',
      );
      expect(task.status, 'failed');
    });

    test(
      'wait: false returns immediately; orb_wait yields the same result',
      () async {
        scriptCompletedTask();

        final dispatched = await service.spawn(
          task: 'do the thing',
          wait: false,
          callerSession: 'ses_caller',
        );
        expect(dispatched.isDone, isFalse);

        final settled = await service.wait(dispatched.id);
        expect(settled.status, 'succeeded');
        expect(settled.summary, 'All done.');
        expect(settled.pr, 'https://gh/pr/1');
      },
    );

    test('waiting an unknown task id is not found', () async {
      await expectLater(
        service.wait('task_nope'),
        throwsA(isA<OrbTaskNotFoundError>()),
      );
    });

    test(
      'on completion the bridge injects the message into the caller',
      () async {
        scriptCompletedTask();

        await service.spawn(task: 'do the thing', callerSession: 'ses_caller');
        await until(
          () => backend.opencode.prompts.any((p) => p.$1 == 'ses_caller'),
        );

        final injection = backend.opencode.prompts
            .firstWhere((p) => p.$1 == 'ses_caller')
            .$2;
        expect(injection, contains('Orb worker done'));
        expect(injection, contains('orb/a1b2c3'));
        expect(injection, contains('succeeded'));
        expect(injection, contains('All done.'));
        expect(injection, contains('https://gh/pr/1'));
      },
    );

    test(
      'a dead calling session drops the notification, the result persists',
      () async {
        scriptCompletedTask();
        // The injection target is a session the service no longer has once the
        // completion lands: its prompt fails (spec §8.3 — the notification is
        // dropped). The spawn-time resolution still knows it (the home list is
        // the caller's view at spawn time).
        backend.opencode.failingPrompts.add('ses_caller');

        final task = await service.spawn(
          task: 'do the thing',
          wait: false,
          callerSession: 'ses_caller',
        );
        await until(() => task.isDone);

        // The completion prompt to the dead session was attempted and the
        // failure did not stop the completion; the result stayed persisted.
        expect(
          backend.opencode.prompts.any((p) => p.$1 == 'ses_caller'),
          isTrue,
        );
        expect(task.status, 'succeeded');
        final decoded = jsonDecode(tasksFile.readAsStringSync());
        expect(decoded[0]['status'], 'succeeded');
      },
    );

    test('the injected message survives without a summary or PR', () async {
      scriptCompletedTask();
      backend.opencode.messagesResult = const [];
      orbs.listResult = [_runningOrb()];

      await service.spawn(task: 'do the thing', callerSession: 'ses_caller');
      await until(
        () => backend.opencode.prompts.any((p) => p.$1 == 'ses_caller'),
      );
      final injection = backend.opencode.prompts
          .firstWhere((p) => p.$1 == 'ses_caller')
          .$2;
      expect(injection, contains('Orb worker done'));
      expect(injection, isNot(contains('PR:')));
    });
  });

  group('persistence', () {
    test('a spawn persists the task; a new service reloads it', () async {
      orbs.listResult = [_runningOrb()];
      scriptDispatch();
      final task = await service.spawn(
        task: 'do the thing',
        wait: false,
        callerSession: 'ses_caller',
      );

      final decoded = jsonDecode(tasksFile.readAsStringSync());
      expect(decoded, hasLength(1));
      expect(decoded[0]['id'], task.id);
      expect(decoded[0]['caller'], 'ses_caller');

      final reloaded = newService();
      final row = reloaded.task(task.id);
      expect(row, isNotNull);
      expect(row!.orb, 'a1b2c3');
      expect(row.task, 'do the thing');
      expect(row.status, 'running');
    });

    test(
      'a restarted service completes a persisted running task and injects',
      () async {
        orbs.listResult = [_runningOrb()];
        scriptDispatch();
        final task = await service.spawn(
          task: 'do the thing',
          wait: false,
          callerSession: 'ses_caller',
        );

        // The bridge restarts: a fresh service over the same file; the orb
        // session has finished in the meantime.
        scriptCompletedTask();
        final restarted = newService();
        await until(() => restarted.task(task.id)!.isDone);

        expect(restarted.task(task.id)!.status, 'succeeded');
        await until(
          () => backend.opencode.prompts.any((p) => p.$1 == 'ses_caller'),
        );
      },
    );
  });

  group('idempotent dispatch (issue #143)', () {
    setUp(() {
      orbs.listResult = [_runningOrb()];
    });

    test('the same task text yields one task, one session', () async {
      scriptDispatch();

      final first = await service.spawn(
        task: 'Fix the login form',
        wait: false,
        callerSession: 'ses_caller',
      );
      final second = await service.spawn(
        task: 'Fix the login form',
        wait: false,
        callerSession: 'ses_caller',
      );

      expect(second, same(first));
      expect(orbs.createSessionCalls, 1);
      expect(service.tasks, hasLength(1));
      expect(backend.opencode.prompts, hasLength(1));
    });

    test('concurrent spawns of the same task dedup too', () async {
      scriptDispatch();

      final answers = await Future.wait([
        service.spawn(
          task: 'Fix the login form',
          wait: false,
          callerSession: 'ses_caller',
        ),
        service.spawn(
          task: 'Fix the login form',
          wait: false,
          callerSession: 'ses_caller',
        ),
      ]);

      expect(answers[0], same(answers[1]));
      expect(orbs.createSessionCalls, 1);
      expect(service.tasks, hasLength(1));
      expect(backend.opencode.prompts, hasLength(1));
    });

    test('only the raw text (trimmed) dedups, not a normalized one', () async {
      // Issue #147: case, whitespace runs and punctuation are part of the
      // instruction — a retyped variant is a different task.
      scriptDispatch();

      final first = await service.spawn(
        task: 'Fix the login form!',
        wait: false,
        callerSession: 'ses_caller',
      );
      final trimmed = await service.spawn(
        task: '  Fix the login form!  ',
        wait: false,
        callerSession: 'ses_caller',
      );
      final second = await service.spawn(
        task: '  fix   THE login form  ',
        wait: false,
        callerSession: 'ses_caller',
      );
      final third = await service.spawn(
        task: 'Fix the\nlogin\tform.',
        wait: false,
        callerSession: 'ses_caller',
      );

      expect(trimmed, same(first));
      expect(second.id, isNot(first.id));
      expect(third.id, isNot(first.id));
      expect(orbs.createSessionCalls, 3);
    });

    test('a different task text dispatches a second session', () async {
      scriptDispatch();

      final first = await service.spawn(
        task: 'Fix the login form',
        wait: false,
        callerSession: 'ses_caller',
      );
      final second = await service.spawn(
        task: 'Fix the signup form',
        wait: false,
        callerSession: 'ses_caller',
      );

      expect(second.id, isNot(first.id));
      expect(orbs.createSessionCalls, 2);
      expect(service.tasks, hasLength(2));
      expect(backend.opencode.prompts, hasLength(2));
    });

    test('a completed task with the same text dispatches anew', () async {
      scriptDispatch();

      final first = await service.spawn(
        task: 'Fix the login form',
        wait: false,
        callerSession: 'ses_caller',
      );
      // The orb session turn ends: the first task is no longer running.
      backend.opencode.detailOf = (id) => _detail(id, outcome: 'succeeded');
      await until(() => first.isDone);

      final second = await service.spawn(
        task: 'Fix the login form',
        wait: false,
        callerSession: 'ses_caller',
      );

      expect(second.id, isNot(first.id));
      expect(orbs.createSessionCalls, 2);
      expect(service.tasks, hasLength(2));
    });
  });

  group('dispatch identity by raw text (issue #147)', () {
    setUp(() {
      orbs.listResult = [_runningOrb()];
      backend.rows = [_callerRow, _callerBRow];
    });

    test('the orb prompt is exactly the caller task text', () async {
      scriptDispatch();

      const task = 'Fix the login form';
      final dispatched = await service.spawn(
        task: task,
        wait: false,
        callerSession: 'ses_caller',
      );

      // The orb's agent sees the caller's text, nothing glued in front or
      // behind it (the return contract is the bridge's protocol, not part of
      // the prompt).
      expect(backend.opencode.prompts.single.$2, task);
      expect(dispatched.task, task);
    });

    test('a substring of the running text is a new task', () async {
      scriptDispatch();

      final first = await service.spawn(
        task: 'Fix the login form validation',
        wait: false,
        callerSession: 'ses_caller',
      );
      final second = await service.spawn(
        task: 'Fix the login form',
        wait: false,
        callerSession: 'ses_caller',
      );

      expect(second.id, isNot(first.id));
    });

    test('a superset containing the running text is a new task', () async {
      scriptDispatch();

      final first = await service.spawn(
        task: 'Fix the login form',
        wait: false,
        callerSession: 'ses_caller',
      );
      final second = await service.spawn(
        task: 'Fix the login form and then the signup form',
        wait: false,
        callerSession: 'ses_caller',
      );

      expect(second.id, isNot(first.id));
      expect(second.session, isNot(first.session));
    });

    test('the running text with punctuation removed is a new task', () async {
      scriptDispatch();

      final first = await service.spawn(
        task: 'Fix the login form!',
        wait: false,
        callerSession: 'ses_caller',
      );
      final second = await service.spawn(
        task: 'Fix the login form',
        wait: false,
        callerSession: 'ses_caller',
      );
      final third = await service.spawn(
        task: 'Fix the login form!!',
        wait: false,
        callerSession: 'ses_caller',
      );

      expect(second.id, isNot(first.id));
      expect(third.id, isNot(first.id));
    });

    test(
      'two different tasks close together keep their own caller sessions',
      () async {
        scriptDispatch();

        final first = await service.spawn(
          task: 'Fix the login form',
          wait: false,
          callerSession: 'ses_caller',
        );
        final second = await service.spawn(
          task: 'Fix the login form validation',
          wait: false,
          callerSession: 'ses_b',
        );

        expect(second.id, isNot(first.id));
        expect(first.callerSession, 'ses_caller');
        expect(second.callerSession, 'ses_b');
        final firstPrompt = backend.opencode.prompts
            .firstWhere((p) => p.$1 == first.session)
            .$2;
        final secondPrompt = backend.opencode.prompts
            .firstWhere((p) => p.$1 == second.session)
            .$2;
        expect(firstPrompt, 'Fix the login form');
        expect(secondPrompt, 'Fix the login form validation');
      },
    );

    test(
      'a transport-retried dispatch still returns the running task',
      () async {
        // #143's case: the caller's fetch timed out and the call repeats with
        // the same raw text and the same calling session — a retry, not a new
        // task. The retried match keys the raw text, so a merely
        // whitespace-different text is its own task.
        scriptDispatch();

        final first = await service.spawn(
          task: 'Fix the login form',
          wait: false,
          callerSession: 'ses_caller',
        );
        final retried = await service.spawn(
          task: 'Fix the login form',
          wait: false,
          callerSession: 'ses_caller',
        );
        final whitespace = await service.spawn(
          task: 'Fix  the  login form',
          wait: false,
          callerSession: 'ses_caller',
        );
        final otherCaller = await service.spawn(
          task: 'Fix the login form',
          wait: false,
          callerSession: 'ses_b',
        );

        expect(retried, same(first));
        // The identity is the raw text's hash — persisted, never a normalized copy.
        expect(first.textHash, isNotNull);
        expect(retried.textHash, first.textHash);
        expect(whitespace.id, isNot(first.id));
        expect(whitespace.textHash, isNot(first.textHash));
        expect(otherCaller.id, isNot(first.id));
        expect(orbs.createSessionCalls, 3);
      },
    );

    test('a caller dispatch id narrows the retry identity', () async {
      scriptDispatch();

      final first = await service.spawn(
        task: 'Fix the login form',
        wait: false,
        callerSession: 'ses_caller',
        dispatchId: 'd_1',
      );
      final retried = await service.spawn(
        task: 'Fix the login form',
        wait: false,
        callerSession: 'ses_caller',
        dispatchId: 'd_1',
      );
      final again = await service.spawn(
        task: 'Fix the login form',
        wait: false,
        callerSession: 'ses_caller',
        dispatchId: 'd_2',
      );

      expect(first.dispatchId, 'd_1');
      expect(retried, same(first));
      expect(again.id, isNot(first.id));
      expect(orbs.createSessionCalls, 2);
    });
  });

  group('bounded blocking wait (issue #143)', () {
    test('a retried wait attribute still answers the running task', () async {
      orbs.listResult = [_runningOrb()];
      scriptDispatch(); // The turn never ends.
      waitGrace = const Duration(milliseconds: 30);

      final tasks = newService();
      final first = await tasks.spawn(
        task: 'long work',
        callerSession: 'ses_caller',
      );
      final retried = await tasks.spawn(
        task: 'long work',
        callerSession: 'ses_caller',
      );

      expect(first.status, 'running');
      expect(retried, same(first));
      expect(orbs.createSessionCalls, 1);
    });
    test(
      'wait: true answers the running task after the grace window',
      () async {
        orbs.listResult = [_runningOrb()];
        scriptDispatch(); // The turn never ends.
        waitGrace = const Duration(milliseconds: 30);

        final stopwatch = Stopwatch()..start();
        final answer = await newService().spawn(
          task: 'long work',
          callerSession: 'ses_caller',
        );
        stopwatch.stop();

        expect(answer.status, 'running');
        expect(answer.isDone, isFalse);
        expect(answer.orbName, 'worker');
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      },
    );
  });

  group('the bounded orb_wait (issue #169)', () {
    test('an explicit wait answers the running task at the grace window', () async {
      orbs.listResult = [_runningOrb()];
      scriptDispatch(); // The turn never ends.
      waitGrace = const Duration(milliseconds: 30);

      final tasks = newService();
      final dispatched = await tasks.spawn(
        task: 'long work',
        wait: false,
        callerSession: 'ses_caller',
      );

      // The held wait ends bounded with the record as it stands — the call
      // that used to hang past the agent tool's own timeout.
      final stopwatch = Stopwatch()..start();
      final answer = await tasks.wait(dispatched.id);
      stopwatch.stop();

      expect(answer, same(dispatched));
      expect(answer.status, 'running');
      expect(answer.isDone, isFalse);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a wait that sees the completion still answers the settled result',
        () async {
      scriptCompletedTask();
      waitGrace = const Duration(seconds: 5);

      final tasks = newService();
      final dispatched = await tasks.spawn(
        task: 'do the thing',
        wait: false,
        callerSession: 'ses_caller',
      );
      final settled = await tasks.wait(dispatched.id);

      expect(settled.status, 'succeeded');
      expect(settled.summary, 'All done.');
    });
  });

  group('the settle windows (issue #169)', () {
    test(
      'an idle outcome-less session settles the task succeeded after the '
      'window',
      () async {
        orbs.listResult = [_runningOrb()];
        scriptDispatch(); // 200 without an outcome, not active, forever.
        settleIdleWindow = const Duration(milliseconds: 30);

        final tasks = newService();
        final task = await tasks.spawn(
          task: 'orphaned work',
          wait: false,
          callerSession: 'ses_caller',
        );
        await until(() => task.isDone);

        expect(task.status, 'succeeded');
        expect(task.summary, contains('no outcome was reported'));
        // The completion injection carries the settle, as any completion.
        await until(
          () => backend.opencode.prompts.any((p) => p.$1 == 'ses_caller'),
        );
      },
    );

    test('an active session is never settled by the idle window', () async {
      orbs.listResult = [_runningOrb()];
      scriptDispatch();
      settleIdleWindow = const Duration(milliseconds: 30);

      final tasks = newService();
      final task = await tasks.spawn(
        task: 'working',
        wait: false,
        callerSession: 'ses_caller',
      );
      // The agent is mid-turn the whole time: idle-without-outcome is simply
      // a between-steps read, not a settled turn.
      backend.opencode.activeIds = {task.session};
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(task.isDone, isFalse);

      // The turn ending (active, then an outcome) settles it the normal way.
      backend.opencode.activeIds = {};
      backend.opencode.detailOf = (id) => _detail(id, outcome: 'succeeded');
      await until(() => task.isDone);
      expect(task.status, 'succeeded');
    });

    test('a parked permission holds the idle settle', () async {
      orbs.listResult = [_runningOrb()];
      scriptDispatch();
      settleIdleWindow = const Duration(milliseconds: 30);
      backend.opencode.pendingPermissionsResult = const [
        PermissionRequest(id: 'per_1', action: 'shell', resources: ['rm -rf']),
      ];

      final tasks = newService();
      final task = await tasks.spawn(
        task: 'awaiting approval',
        wait: false,
        callerSession: 'ses_caller',
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(task.isDone, isFalse, reason: 'a parked question is not a done turn');

      // The human answers: the window restarts and the settle goes through.
      backend.opencode.pendingPermissionsResult = const [];
      backend.opencode.detailOf = (id) => _detail(id, outcome: 'succeeded');
      await until(() => task.isDone);
      expect(task.status, 'succeeded');
    });

    test('a missing session settles the task failed after the window',
        () async {
      orbs.listResult = [_runningOrb()];
      scriptDispatch();
      settleMissingWindow = const Duration(milliseconds: 30);

      final tasks = newService();
      final task = await tasks.spawn(
        task: 'gone work',
        wait: false,
        callerSession: 'ses_caller',
      );
      // The session is deleted (the orb died and the session went with it).
      backend.opencode.detailError = const OpencodeServiceError(
        404,
        'no such session',
      );
      await until(() => task.isDone);

      expect(task.status, 'failed');
      expect(task.summary, contains('no longer exists'));
    });

    test('a transient service error never settles the task', () async {
      orbs.listResult = [_runningOrb()];
      scriptDispatch();
      settleIdleWindow = const Duration(milliseconds: 30);
      settleMissingWindow = const Duration(milliseconds: 30);

      final tasks = newService();
      final task = await tasks.spawn(
        task: 'blip work',
        wait: false,
        callerSession: 'ses_caller',
      );
      // A transport failure (status 0) is not a missing session: no settle,
      // however long it lasts.
      backend.opencode.detailError = const OpencodeServiceError(
        0,
        'SocketException',
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(task.isDone, isFalse);

      // The service recovers: the task settles on its real outcome.
      backend.opencode.detailError = null;
      backend.opencode.detailOf = (id) => _detail(id, outcome: 'succeeded');
      await until(() => task.isDone);
      expect(task.status, 'succeeded');
    });

    test('a settled zombie is persisted and stops the watcher spinning',
        () async {
      orbs.listResult = [_runningOrb()];
      scriptDispatch();
      settleIdleWindow = const Duration(milliseconds: 30);

      final tasks = newService();
      final task = await tasks.spawn(
        task: 'zombie work',
        wait: false,
        callerSession: 'ses_caller',
      );
      await until(() => task.isDone);

      final decoded = jsonDecode(tasksFile.readAsStringSync());
      expect(decoded[0]['status'], 'succeeded');
      expect(decoded[0]['completed'], isNotNull);
    });
  });
}
