// The completion report verifies the push (issue #352): after the orb agent's
// turn ends, the bridge reads the pushed state **itself** — `git ls-remote`
// against the remote for the task's branch — before settling the task, and
// the report's artifact (branch, sha) is that remote-verified value, not the
// agent's claim. A push that failed silently (the #346-observed case: the
// agent reported "pushed", the branch was not on the remote) must never
// settle `succeeded` — the task settles a distinct `push_unverified`, the
// `ls-remote` evidence in the summary, and the failure text names the
// positive path (re-dispatch the same task to re-verify and re-push).
//
// The agent carries no sha of its own to the harness (the turn outcome is
// `succeeded`/`failed`, never a sha), so the sha-mismatch signal is the
// orb-side push-failed marker (`OrbRecord.pushFailing`, fed by the
// entrypoint's post-commit hook): a branch that is on the remote while the
// hook says the push failed is settled `push_unverified` too (acceptance #3).
//
// The repro drives the real `OrbTaskService` settle path (the single
// `_check` → `_settle` route) over a scripted `SessionsBackend` and a scripted
// [OrbService] seam whose `remoteBranchTip` answers the remote probe exactly
// like the real one: the 40-hex sha when the branch is on the remote, `null`
// when it is not. No docker, no HTTP, no subprocess.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/orb/orb_service.dart';
import 'package:opencodebridge/bridge/orb/orb_task_service.dart';
import 'package:opencodebridge/bridge/sessions/backend.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';
import 'package:opencodebridge/bridge/sessions/order_store.dart';
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

const _remoteTip = 'd41d8cd98f00b204e9800998ecf8427e00000001';

final _callerRow = Session(
  id: 'ses_caller',
  title: 'caller',
  project: const SessionProject(id: 'prj_1', name: 'shop'),
  created: 100,
  location: '/home/dev/shop',
  active: false,
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

/// The scripted [OpencodeService]: the completion check's detail + messages +
/// the injection prompt. Everything else is `UnimplementedError` — the repro
/// drives only the settle path.
class _FakeOpencode extends OpencodeService {
  SessionDetail Function(String id) detailOf = (id) =>
      throw StateError('getDetail not scripted');
  List<SessionMessage> messagesResult = const [];
  Set<String> activeIds = {};

  /// Every prompt delivered: (session id, text).
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
  }

  @override
  Future<SessionDetail> getDetail(String id) async => detailOf(id);

  @override
  Future<List<SessionMessage>> getMessages(String id) async => messagesResult;

  @override
  Future<List<PermissionRequest>> pendingPermissions(String id) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The scripted [SessionsBackend]: the home-list rows (the caller) and the
/// fake opencode service.
class _FakeBackend extends SessionsBackend {
  _FakeBackend(this.opencode)
    : super(service: opencode, orderStore: _InMemoryOrderStore());

  final _FakeOpencode opencode;

  @override
  Future<List<Session>> list() async => [_callerRow];
}

/// The scripted [OrbService]: the orb list (drives the settle's PR read) and
/// the remote probe — the new seam the settle verifies the push through. No
/// container actually runs.
class _FakeOrbs implements OrbService {
  List<OrbRecord> listResult = const [];

  /// The sha [remoteBranchTip] answers (the remote's tip of the task's
  /// branch), or `null` — the branch is not on the remote.
  String? branchTip;

  /// The orb-side push-failed marker (`OrbRecord.pushFailing`, fed by the
  /// entrypoint's post-commit hook): the mismatch signal for a branch the
  /// remote carries but the hook's push reported failed for.
  bool pushFailing = false;

  /// Every `ls-remote` probe the settle made: (checkout, branch).
  final List<(String, String)> lsRemoteCalls = [];

  @override
  Future<List<OrbRecord>> list({bool includePr = false}) async {
    // The push-failed marker rides on the record (spec §2.7's badge), the
    // way the real composition adds it.
    return [
      for (final row in listResult)
        if (pushFailing && !row.pushFailing)
          OrbRecord(
            id: row.id,
            name: row.name,
            project: row.project,
            branch: row.branch,
            state: row.state,
            created: row.created,
            url: row.url,
            pr: row.pr,
            base: row.base,
            pushFailing: true,
            ghAuthFailed: row.ghAuthFailed,
            bootReason: row.bootReason,
          )
        else
          row,
    ];
  }

  @override
  Future<String?> remoteBranchTip(String checkout, String branch) async {
    lsRemoteCalls.add((checkout, branch));
    return branchTip;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An in-memory [SessionOrderStore] (the store is required at construction;
/// this one never touches a file so a test's store does not leak onto the
/// host).
class _InMemoryOrderStore implements SessionOrderStore {
  final Map<String, num> _positions = {};

  @override
  File get file => throw StateError('in-memory store has no file');

  @override
  Map<String, num> load() => Map<String, num>.from(_positions);

  @override
  Future<void> set(String id, num position) async {
    _positions[id] = position;
  }

  @override
  Future<void> clear(String id) async {
    _positions.remove(id);
  }
}

void main() {
  late Directory temp;
  late File tasksFile;
  late _FakeOrbs orbs;
  late _FakeBackend backend;
  late OrbTaskService service;

  final services = <OrbTaskService>[];

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condition not met before the deadline');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// The persisted `running` task the service re-watches (spec §8.3: the
  /// tasks file survives a restart).
  void seedTask() {
    tasksFile.writeAsStringSync(
      jsonEncode([
        {
          'id': 'task_verify',
          'orb': 'a1b2c3',
          'project': 'prj_1',
          'orbName': 'worker',
          'branch': 'orb/a1b2c3',
          'session': 'ses_task',
          'caller': 'ses_caller',
          'task': 'do the thing',
          'created': 1000,
          'status': 'running',
          'summary': '',
        },
      ]),
    );
  }

  /// Script the settle: the task's session reports [outcome] when read, with
  /// [summaryText] as its final assistant message.
  void scriptSettle({
    String outcome = 'succeeded',
    String summaryText = 'Shipped it.',
  }) {
    orbs.listResult = [
      OrbRecord(
        id: 'a1b2c3',
        name: 'worker',
        project: 'prj_1',
        branch: 'orb/a1b2c3',
        state: 'running',
        created: '2026-01-01T00:00:00.000Z',
        url: 'http://127.0.0.1:9999',
      ),
    ];
    backend.opencode.detailOf = (id) => _detail(id, outcome: outcome);
    backend.opencode.messagesResult = [
      SessionMessage(id: 'm', role: 'assistant', text: summaryText),
    ];
  }

  OrbTaskService buildService() {
    final created = OrbTaskService(
      orbs: orbs,
      sessions: backend,
      file: tasksFile,
      pollInterval: const Duration(milliseconds: 10),
      settleIdleWindow: const Duration(milliseconds: 300),
      settleMissingWindow: const Duration(milliseconds: 300),
    );
    services.add(created);
    return created;
  }

  /// The completion text injected into the calling session.
  String injectionFor() {
    for (final (id, text) in backend.opencode.prompts) {
      if (id == 'ses_caller') return text;
    }
    throw StateError('no injection into ses_caller yet');
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('orb-push-verify');
    tasksFile = File('${temp.path}/tasks.json');
    orbs = _FakeOrbs();
    backend = _FakeBackend(_FakeOpencode());
  });

  tearDown(() async {
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

  group('the settle verifies the push (issue #352)', () {
    test(
      'a branch on the remote settles succeeded, the sha rides on the artifact',
      () async {
        seedTask();
        service = buildService();
        scriptSettle();
        // The remote answers: the branch is at the tip.
        orbs.branchTip = _remoteTip;

        await until(() => service.task('task_verify')!.isDone);
        final settled = service.task('task_verify')!;

        // The harness read the remote itself, from the project checkout, for
        // the task's branch.
        expect(
          orbs.lsRemoteCalls,
          [('/home/dev/shop', 'orb/a1b2c3')],
          reason:
              'the settle must ls-remote the task branch from the project '
              'checkout (issue #352, acceptance #1)',
        );
        // The artifact is the remote-verified value: branch **and** sha.
        expect(settled.status, 'succeeded');
        expect(settled.sha, _remoteTip);
        expect(
          settled.results,
          ['branch: orb/a1b2c3 @ $_remoteTip'],
          reason:
              'the report carries the remote-verified sha (issue #352, '
              'acceptance #2)',
        );
      },
    );

    test('a branch that never reached the remote settles push_unverified with '
        'the ls-remote evidence — never succeeded', () async {
      seedTask();
      service = buildService();
      scriptSettle();
      orbs.listResult = [
        OrbRecord(
          id: 'a1b2c3',
          name: 'worker',
          project: 'prj_1',
          branch: 'orb/a1b2c3',
          state: 'running',
          created: '2026-01-01T00:00:00.000Z',
          url: 'http://127.0.0.1:9999',
          pr: const OrbPr(state: 'open', url: 'https://gh/pr/1'),
        ),
      ];
      // The remote answers: the branch is absent.
      orbs.branchTip = null;

      await until(() => service.task('task_verify')!.isDone);
      final settled = service.task('task_verify')!;

      expect(
        settled.status,
        'push_unverified',
        reason:
            'a branch absent from the remote must never settle `succeeded` '
            '(issue #352, acceptance #2)',
      );
      // The ls-remote evidence, and the positive path named.
      expect(settled.summary, contains('orb/a1b2c3 is not on the remote'));
      expect(settled.summary, contains('re-dispatch the same task'));
      expect(settled.sha, isNull, reason: 'there is no remote sha to carry');
      // The injection carries the failure too.
      final injection = injectionFor();
      expect(injection, contains('push_unverified'));
      expect(injection, contains('re-dispatch the same task'));
    });

    test('a push-failed marker on an orb whose branch is on the remote is a '
        'mismatch: push_unverified, not a silent success', () async {
      seedTask();
      service = buildService();
      scriptSettle();
      orbs.listResult = [
        OrbRecord(
          id: 'a1b2c3',
          name: 'worker',
          project: 'prj_1',
          branch: 'orb/a1b2c3',
          state: 'running',
          created: '2026-01-01T00:00:00.000Z',
          url: 'http://127.0.0.1:9999',
          pr: const OrbPr(state: 'open', url: 'https://gh/pr/1'),
        ),
      ];
      // The remote carries the branch, but the hook's push said it failed:
      // the tip is not the work the agent finished with.
      orbs.branchTip = _remoteTip;
      orbs.pushFailing = true;

      await until(() => service.task('task_verify')!.isDone);
      final settled = service.task('task_verify')!;

      expect(
        settled.status,
        'push_unverified',
        reason:
            'a sha mismatch (the hook says the push failed) is a failure, '
            'not a silent success (issue #352, acceptance #3)',
      );
      expect(settled.summary, contains('push-failed marker'));
      expect(settled.summary, contains('re-dispatch the same task'));
      final injection = injectionFor();
      expect(injection, contains('push_unverified'));
    });

    test(
      'a failed agent turn is not re-gated: it stays failed, never succeeds',
      () async {
        seedTask();
        service = buildService();
        scriptSettle(outcome: 'failed', summaryText: 'I could not do it.');
        // Even with the branch on the remote, a failed turn is a failure for
        // its own reason — the push gate only rescues the
        // `succeeded`-but-unverified case, never upgrading or downgrading a
        // failed turn.
        orbs.branchTip = _remoteTip;

        await until(() => service.task('task_verify')!.isDone);
        final settled = service.task('task_verify')!;

        expect(
          settled.status,
          'failed',
          reason:
              'a failed turn keeps its own cause; the push gate does not '
              're-gate it (issue #352 gates `succeeded` only)',
        );
        expect(settled.summary, 'I could not do it.');
        // No sha rides on a turn that did not verify a push.
        expect(settled.sha, isNull);
      },
    );
  });
}
