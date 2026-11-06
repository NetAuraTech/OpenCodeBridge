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

  /// Every `prompt` the fake received: (session id, text).
  final List<(String, String)> prompts = [];

  @override
  Future<List<OpencodeProject>> projects() async => [_project];

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
  Future<SessionDetail> getDetail(String id) async => detailOf(id);

  @override
  Future<List<SessionMessage>> getMessages(String id) async => messagesResult;

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

  Session? createSessionResult;
  String? createSessionOrbId;

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
  }) async {
    createProject = project;
    createName = name;
    createCheckout = checkout;
    return createResult!;
  }

  @override
  Future<Session> createSessionOnOrb(String id) async {
    createSessionOrbId = id;
    return createSessionResult!;
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

  OrbTaskService newService() => OrbTaskService(
    orbs: orbs,
    sessions: backend,
    file: tasksFile,
    pollInterval: const Duration(milliseconds: 5),
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('orb-tasks');
    tasksFile = File('${temp.path}/tasks.json');
    orbs = _FakeOrbs();
    backend = _FakeBackend(_FakeOpencode());
    service = newService();
  });

  tearDown(() async {
    await temp.delete(recursive: true);
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
        expect(prompt.$2, contains('do the thing'));
        expect(prompt.$2, contains('orb/a1b2c3'));
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
}
