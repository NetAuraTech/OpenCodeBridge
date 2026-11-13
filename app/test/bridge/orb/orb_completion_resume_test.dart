// A task resumed after a restart, and its completion report (issue #210,
// the tracer bullet for the re-arm fix #211). The user's flow: dispatch
// `orb_spawn`, close the app mid-task, relaunch in server mode. The bridge
// must re-watch the persisted `running` task and, once its orb (auto-woken)
// ends its turn, persist the result and **inject the completion** into the
// calling session.
//
// Two defects (issue #210's causes):
//
// 1. **The completion watcher may be absent at bridge startup.**
//    `BridgeServer.start` builds the `OrbTaskService` only when the host
//    sessions backend resolves **at startup** — i.e. only when the host
//    opencode descriptor (`~/.local/state/opencode/service.json`) is already
//    readable. If the app relaunches before the host service is up, the task
//    service is `null`, the persisted `running` task is not watched, and
//    **nothing re-arms it** — meanwhile the orb auto-wakes and finishes with
//    no one to detect the completion.
// 2. **A resumed task settles `failed` while its orb is still booting.** The
//    re-loaded watcher's `_check` reads the orb session through the composite
//    service. While the orb is still in its auto-wake (not yet `running`),
//    there is no upstream → the read falls back to the **host**, which does
//    not know the orb session → `404` → after `settleMissingWindow` the task
//    settles **`failed`** ("the orb session no longer exists") while the work
//    is still in flight.
//
// **Repro #2 is the in-process tracer bullet (red now, green after #211).**
// A real `OrbTaskService` over a real `CompositeOpencodeService` (host +
// per-orb in-memory fakes — no docker, no HTTP, no subprocess): the orb goes
// `preparing` → `running`, the composite 404s the orb session while it is
// still booting, and the task settles on the turn's **real** outcome with the
// completion injected into the calling session. On the current state the
// mid-boot 404 settles the task `failed` first, so the `succeeded`/injection
// assertions fail. Once #211 stops settling `failed` on a booting-orb 404 the
// test goes green.
//
// **Repro #1 is a characterization of the no-watcher gate (green now).**
// `Platform.environment` is unmodifiable in-process, so the "isolate HOME,
// start with no descriptor, then write one" window cannot be reproduced
// faithfully in-process. Instead the bare `BridgeServer.start` path — on a
// host with **no** descriptor (skipped where the host publishes one, since a
// bare start then has a backend and the gate is satisfied) — is locked: the
// spawn/wait endpoints answer `503 opencode_unavailable` because the task
// service was never built. This pins the gate #211 changes (always build and
// re-arm): after #211 a host-less boot must re-arm the watcher as soon as the
// descriptor appears and the 503 window closes.
//
// No docker, no real opencode service, no subprocess: repro #2 is pure
// in-memory fakes; repro #1 only binds the loopback HTTP server.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/bridge_server.dart';
import 'package:opencodebridge/bridge/orb/orb_service.dart';
import 'package:opencodebridge/bridge/orb/orb_task_service.dart';
import 'package:opencodebridge/bridge/sessions/backend.dart';
import 'package:opencodebridge/bridge/sessions/composite_service.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';
import 'package:opencodebridge/bridge/sessions/paths.dart';
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

/// One scripted [OpencodeService]: a set of sessions (one of which it serves
/// a detail for), an active set, a per-session detail outcome, the history,
/// and every prompt it receives. Unknown sessions 404 (the host's answer to
/// an orb session the composite has not routed yet). Everything else is
/// `UnimplementedError` — the repro drives only the read/settle path.
class _FakeService extends OpencodeService {
  _FakeService(this.name) : sessions = const [];

  final String name;
  List<OpencodeSession> sessions;
  Set<String> activeIds = {};

  /// The detail's turn outcome for every session this service serves
  /// (`null` while the turn is still running).
  String? outcome;

  /// The history served for any detail read (the completion summary source).
  List<SessionMessage> messages = const [];

  /// Every prompt delivered: (session id, text).
  final List<(String, String)> prompts = [];

  @override
  Future<List<OpencodeSession>> listSessions() async => sessions;

  @override
  Future<Set<String>> activeSessionIds() async => activeIds;

  @override
  Future<SessionDetail> getDetail(String id) async {
    for (final session in sessions) {
      if (session.id == id) {
        return SessionDetail(
          id: id,
          title: session.title,
          location: session.location,
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
      }
    }
    throw const OpencodeServiceError(404, 'no such session');
  }

  @override
  Future<List<SessionMessage>> getMessages(String id) async => messages;

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
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$name: ${invocation.memberName}');
}

/// The scripted [OrbService]: the orb list (drives the composite's upstream
/// set), the per-orb session create, and the derived password. No container
/// actually runs (repro #2 never wakes; repro #1's bare start has its own
/// real orb service but its `recover` is a no-op here only on repro #2).
class _FakeOrbs implements OrbService {
  List<OrbRecord> listResult = const [];
  Session? createSessionResult;
  int createSessionCalls = 0;

  @override
  Future<List<OrbRecord>> list({bool includePr = false}) async => listResult;

  @override
  Future<Session> createSessionOnOrb(String id) async {
    createSessionCalls++;
    return createSessionResult!;
  }

  @override
  Future<String?> lastPassword(String id) async => 'orb-secret';

  @override
  Future<void> recover() async {}

  @override
  void startLifecyclePass({Duration? interval}) {}

  @override
  void stopLifecyclePass() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('orbs: ${invocation.memberName}');
}

/// True on a host that publishes a shared opencode service descriptor, where
/// the bridge default builds a real sessions backend (so a bare start is not
/// the backend-less 503 case). Mirrors the guard in `cancellation_e2e_test`.
bool _hostHasServiceDescriptor() {
  if (File('${homeDirectory()}/.local/state/opencode/service.json')
      .existsSync()) {
    markTestSkipped(
      'the host publishes a shared opencode service descriptor, so the '
      'bridge default builds a real sessions backend (the no-watcher 503 '
      'path is unreachable there)',
    );
    return true;
  }
  return false;
}

void main() {
  late Directory temp;
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

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('orb-resume');
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

  group(
    'repro #2: the resumed task settles on its real outcome (issue #210)',
    () {
      test(
        'a task whose orb was still booting settles succeeded (not a boot-time '
        '404) and injects the completion',
        () async {
          const orbId = 'a1b2c3';
          const orbUrl = 'http://127.0.0.1:49001';
          final host = _FakeService('host');
          final orb = _FakeService('orb');
          OrbRecord orbState = OrbRecord(
            id: orbId,
            name: 'worker',
            project: 'prj_1',
            branch: 'orb/$orbId',
            state: 'preparing', // Mid-boot: the composite has no upstream yet.
            created: '2026-01-01T00:00:00Z',
          );

          final composite = CompositeOpencodeService(
            host: host,
            orbList: () async => [orbState],
            orbPassword: (_) async => 'orb-secret',
            upstreamFactory: (url, password) {
              // The composite builds the per-orb client from the running
              // record's (url | derived password); the scripted [orb] is it.
              if (url.toString() == orbUrl && password == 'orb-secret') {
                return orb;
              }
              throw StateError('no scripted upstream for $url|$password');
            },
          );
          final backend = SessionsBackend(service: composite);
          final orbs = _FakeOrbs();
          // The task service consults the orb list for the task's orb state
          // (a missing-session 404 is conclusive only for a running orb):
          // keep its view in step with the composite's.
          orbs.listResult = [orbState];
          orbs.createSessionResult = Session(
            id: 'ses_task',
            title: 'task',
            project: const SessionProject(id: 'prj_orb', name: 'orb'),
            created: 200,
            location: '/workspace',
            active: false,
            orb: 'a1b2c3',
          );

          // The persisted `running` task the previous bridge left (spec §8.3:
          // the tasks file survives the restart).
          final tasksFile = File('${temp.path}/tasks.json');
          tasksFile.writeAsStringSync(
            jsonEncode([
              {
                'id': 'task_resume',
                'orb': orbId,
                'project': 'prj_1',
                'orbName': 'worker',
                'branch': 'orb/$orbId',
                'session': 'ses_task',
                'caller': 'ses_caller',
                'task': 'do the thing',
                'created': 1000,
                'status': 'running',
                'summary': '',
                'results': ['branch: orb/$orbId'],
              },
            ]),
          );

          // Relaunch in server mode: the task service re-watches the persisted
          // task. The orb is still booting, so the watcher's reads of
          // `ses_task` route to the host, which 404s them.
          final service = OrbTaskService(
            orbs: orbs,
            sessions: backend,
            file: tasksFile,
            pollInterval: const Duration(milliseconds: 10),
            settleMissingWindow: const Duration(milliseconds: 300),
            settleIdleWindow: const Duration(milliseconds: 300),
          );
          services.add(service);

          // Give the mid-boot 404 window (300ms) plus several polls to fire: on
          // the current state the watcher settles the task `failed` here.
          await Future<void>.delayed(const Duration(milliseconds: 700));

          // The orb is **still booting** (not `running`) and its session reads
          // 404 through the host fallback. Acceptance: the task must stay
          // `running` — the 404 is "not routable yet," not "session gone," so
          // the missing window must not settle it `failed` mid-flight.
          expect(
            service.task('task_resume')!.isDone,
            isFalse,
            reason:
                'a boot-time 404 settled the task before the orb finished '
                '(issue #211, defect #2)',
          );
          expect(service.task('task_resume')!.status, 'running');

          // The orb boots and the turn ends: its **real** outcome, now.
          orbState = OrbRecord(
            id: orbId,
            name: 'worker',
            project: 'prj_1',
            branch: 'orb/$orbId',
            state: 'running',
            created: '2026-01-01T00:00:00Z',
            url: orbUrl,
          );
          orbs.listResult = [orbState];
          orb.sessions = const [
            OpencodeSession(
              id: 'ses_task',
              title: 'task',
              projectId: 'prj_orb',
              created: 200,
              location: '/workspace',
              orb: 'a1b2c3',
            ),
          ];
          orb.outcome = 'succeeded';
          orb.messages = const [
            SessionMessage(id: 'm', role: 'assistant', text: 'Shipped it.'),
          ];
          host.sessions = const [
            OpencodeSession(
              id: 'ses_caller',
              title: 'caller',
              projectId: 'prj_1',
              created: 100,
              location: '/home/dev/shop',
            ),
          ];

          await until(() => service.task('task_resume')!.isDone);

          // The task settles on the orb's **real** outcome … (issue #210: a
          // boot-time 404 must not settle it `failed` while the work ran).
          final settled = service.task('task_resume')!;
          expect(
            settled.status,
            'succeeded',
            reason:
                'a boot-time 404 settled the task `failed` before the orb '
                'finished (issue #210, defect #2)',
          );
          expect(settled.summary, 'Shipped it.');

          // … and the calling session receives the completion (spec §8.3).
          await until(() => host.prompts.any((p) => p.$1 == 'ses_caller'));
          final injection = host.prompts
              .firstWhere((p) => p.$1 == 'ses_caller')
              .$2;
          expect(injection, contains('Orb worker done'));
          expect(injection, contains('orb/$orbId'));
          expect(injection, contains('succeeded'));
          expect(injection, contains('Shipped it.'));
        },
      );
    },
  );

  group('repro #1: the no-watcher gate (issue #210)', () {
    test(
      'a bare bridge start with no host descriptor builds no task service',
      () async {
        if (_hostHasServiceDescriptor()) return;
        // No host opencode descriptor at startup: the sessions backend does
        // not resolve, so the task service is not built and the spawn/wait
        // surface has no watcher for the persisted running task.
        final server = await BridgeServer.start(port: 0);
        addTearDown(server.stop);

        final (status, body) = await _postRaw(
          server.baseUri,
          '/api/orb/wait',
          '{"id": "task_resume"}',
        );
        expect(status, 503);
        expect(jsonDecode(body), {'error': 'opencode_unavailable'});
      },
    );
  });
}
