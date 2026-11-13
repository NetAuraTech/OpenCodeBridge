// The automated lifecycle pass (issue #101, spec §2.10): the single actor
// of orb automation — 60-min idle auto-stop through the shared stop path,
// the 24-h stopped-TTL auto-delete with the guard re-evaluated on every
// pass (never forced), the merged-PR bypass of the TTL, the "cleanup
// pending" surfacing of guard-blocked candidates, and the mid-run gh
// re-stage on `push-failed` (issue #167, spec §4).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/docker/docker_backend.dart';
import 'package:opencodebridge/bridge/orb/orb_build_context.dart';
import 'package:opencodebridge/bridge/orb/orb_image_builder.dart';
import 'package:opencodebridge/bridge/orb/orb_service.dart';
import 'package:opencodebridge/bridge/sessions/opencode_cli.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';
import 'package:opencodebridge/model/permission.dart';

/// A deep-equal index lookup ([List.indexOf] compares list elements by
/// identity, which never matches a fresh literal).
int argsIndex(List<List<String>> args, List<String> target) => args.indexWhere(
  (a) =>
      a.length == target.length &&
      [for (var i = 0; i < a.length; i++) a[i] == target[i]].every((x) => x),
);

/// A scripted docker CLI child (the wake's boot follow stream).
class _FakeProcess {
  final StreamController<String> stdout = StreamController<String>();
  final StreamController<String> stderr = StreamController<String>();
  final Completer<int> _exit = Completer<int>();

  DockerProcess toProcess() => DockerProcess(
    stdout: stdout.stream,
    stderr: stderr.stream,
    exitCode: _exit.future,
    kill: kill,
  );

  Future<void> kill() async {
    exit(0);
  }

  void exit(int code) {
    stdout.close();
    stderr.close();
    if (!_exit.isCompleted) _exit.complete(code);
  }
}

/// One labeled orb container, as the fake docker daemon holds it.
class _Row {
  _Row({
    required this.id,
    this.state = 'running',
    this.port,
    this.volumes = true,
    this.orphan = false,
    this.finishedAt,
    this.restartPort,
  });

  final String id;
  String state;
  int? port;
  final bool volumes;

  /// Whether the row has no container (an orphan): the `ps` and the
  /// container inspects skip it, the volume commands keep it.
  final bool orphan;

  /// The container's `State.FinishedAt` (the pass's stopped clock); `null`
  /// answers docker's never-exited zero value.
  String? finishedAt;

  /// The ephemeral port a `docker start` re-maps to (the wake's boot wait);
  /// `null` keeps the current port.
  final int? restartPort;

  /// The container log: always carries the boot's password line, so the
  /// list's preparing derivation leaves a running row running.
  String log = '';

  String get container => 'orb-$id';

  Map<String, String> get labels => {
    'ocb.orb': 'true',
    'ocb.id': id,
    'ocb.name': 'orb-$id',
    'ocb.project': 'proj-1',
    'ocb.branch': 'orb/$id',
    'ocb.created': '2026-01-01T00:00:00.000Z',
  };
}

/// The DockerRunner/DockerSpawner seam over a mutable set of [_Row]s: the
/// stop mutates the row's state, the deletion removes it, the throwaway
/// containers (the stopped-orb guard's git) and the `docker exec` (the
/// running-orb guard's git) are answered by the test's callbacks.
class _FakeDocker {
  final List<_Row> rows = [];
  final List<List<String>> runArgs = [];
  final List<_FakeProcess> spawned = [];

  /// The `docker exec` responder (the running-orb guard's git); `null`
  /// throws (an unexpected call).
  DockerCliResult Function(List<String> argv)? execRespond;

  /// The `docker run --rm` responder (the stopped-orb guard's git); `null`
  /// throws.
  DockerCliResult Function(List<String> argv)? runRespond;

  /// The names passed to `volume rm`, in order.
  final List<String> volumeRmNames = [];

  /// The container's `Config.Image` (`{{.Config.Image}}`).
  String containerImage = 'orb:abc123';

  static const DockerCliResult ok = DockerCliResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );

  _Row? _row(String container) {
    for (final row in rows) {
      if (row.container == container) return row;
    }
    return null;
  }

  Future<DockerCliResult> _run(
    List<String> argv, {
    String? workingDirectory,
  }) async {
    runArgs.add(List.of(argv));
    return _dispatch(List.of(argv));
  }

  DockerCliResult _dispatch(List<String> argv) {
    switch (argv[0]) {
      case 'image':
        return const DockerCliResult(exitCode: 0, stdout: '{}', stderr: '');
      case 'ps':
        return DockerCliResult(
          exitCode: 0,
          stdout: rows
              .where((r) => !r.orphan)
              .map((r) => r.container)
              .join('\n'),
          stderr: '',
        );
      case 'stop':
        final row = _row(argv[1]);
        if (row == null) {
          return const DockerCliResult(
            exitCode: 125,
            stdout: '',
            stderr: 'no such container',
          );
        }
        row.state = 'exited';
        row.port = null;
        return ok;
      case 'start':
        final row = _row(argv[1]);
        if (row == null) {
          return const DockerCliResult(
            exitCode: 125,
            stdout: '',
            stderr: 'no such container',
          );
        }
        row.state = 'running';
        row.port = row.restartPort ?? row.port ?? 49321;
        // The in-container service mints a fresh password on every start,
        // landing in the log after the start returns (the stale-line trap).
        final bootNumber = OrbService.countServerPasswords(row.log) + 1;
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 1), () {
            row.log += 'server password pw-$bootNumber\n';
          }),
        );
        return ok;
      case 'rm':
        final row = _row(argv.last);
        if (row == null) {
          return const DockerCliResult(
            exitCode: 125,
            stdout: '',
            stderr: 'no such container',
          );
        }
        rows.remove(row);
        return ok;
      case 'exec':
        final respond = execRespond;
        if (respond == null) {
          throw StateError('unexpected docker argv: $argv');
        }
        return respond(argv);
      case 'run':
        if (argv.length > 1 && argv[1] == '--rm') {
          final respond = runRespond;
          if (respond == null) {
            throw StateError('unexpected docker argv: $argv');
          }
          return respond(argv);
        }
        throw StateError('unexpected docker argv: $argv');
      case 'cp':
      case 'create':
        return ok;
      case 'logs':
        final row = _row(argv.last);
        if (row == null) {
          return const DockerCliResult(
            exitCode: 1,
            stdout: '',
            stderr: 'no such container',
          );
        }
        return DockerCliResult(exitCode: 0, stdout: row.log, stderr: '');
      case 'inspect':
        final formatIndex = argv.indexOf('--format');
        final format = formatIndex == -1 ? argv.last : argv[formatIndex + 1];
        final names = [
          for (var i = 1; i < argv.length; i++)
            if (argv[i] != '--format' && i != formatIndex + 1) argv[i],
        ];
        switch (format) {
          case '{{json .Config.Labels}}':
            return DockerCliResult(
              exitCode: 0,
              stdout: names
                  .map(
                    (n) =>
                        jsonEncode(_row(n)?.labels ?? const <String, String>{}),
                  )
                  .join('\n'),
              stderr: '',
            );
          case '{{.State.Status}}':
            return DockerCliResult(
              exitCode: 0,
              stdout: names.map((n) => _row(n)?.state ?? 'missing').join('\n'),
              stderr: '',
            );
          case '{{json .NetworkSettings.Ports}}':
            final ports = names
                .map((n) {
                  final row = _row(n);
                  if (row == null ||
                      row.state != 'running' ||
                      row.port == null) {
                    return 'null';
                  }
                  return jsonEncode({
                    '4096/tcp': [
                      {'HostIp': '127.0.0.1', 'HostPort': '${row.port}'},
                    ],
                  });
                })
                .join('\n');
            return DockerCliResult(exitCode: 0, stdout: ports, stderr: '');
          case '{{.Config.Image}}':
            return DockerCliResult(
              exitCode: 0,
              stdout: containerImage,
              stderr: '',
            );
          case '{{.State.FinishedAt}}':
            final row = _row(names.single);
            if (row == null) {
              return const DockerCliResult(
                exitCode: 1,
                stdout: '',
                stderr: 'no such container',
              );
            }
            return DockerCliResult(
              exitCode: 0,
              stdout: row.finishedAt ?? '0001-01-01T00:00:00Z',
              stderr: '',
            );
        }
        throw StateError('unexpected inspect format: $format');
      case 'volume':
        switch (argv[1]) {
          case 'ls':
            final names = [
              for (final row in rows)
                if (row.volumes) ...[
                  'orb-${row.id}-workspace',
                  'orb-${row.id}-data',
                ],
            ];
            return DockerCliResult(
              exitCode: 0,
              stdout: names.join('\n'),
              stderr: '',
            );
          case 'inspect':
            final names = argv.sublist(2, argv.length - 2);
            final labels = names
                .map((n) {
                  final id = RegExp(r'^orb-(.+)-(workspace|data)$')
                      .firstMatch(n)
                      ?.group(1);
                  _Row? row;
                  for (final candidate in rows) {
                    if (candidate.id == id) row = candidate;
                  }
                  return jsonEncode(row?.labels ?? const <String, String>{});
                })
                .join('\n');
            return DockerCliResult(exitCode: 0, stdout: labels, stderr: '');
          case 'rm':
            volumeRmNames.add(argv[2]);
            return ok;
          default:
            return ok;
        }
    }
    throw StateError('unexpected docker argv: $argv');
  }

  Future<DockerProcess> _spawn(
    List<String> argv, {
    String? workingDirectory,
  }) async {
    final process = _FakeProcess();
    spawned.add(process);
    return process.toProcess();
  }
}

/// A scripted opencode service (the orb's): the pass's busy read
/// ([active]/[pending]) and the stop's session list and deletion.
class _FakeOrbService implements OpencodeService {
  final List<OpencodeSession> sessions = [];
  final Set<String> active = {};

  /// Session id → its pending permission requests (the busy check).
  final Map<String, List<PermissionRequest>> pending = {};

  final List<String> deleted = [];

  @override
  Future<List<OpencodeSession>> listSessions() async => List.of(sessions);

  @override
  Future<Set<String>> activeSessionIds() async => Set.of(active);

  @override
  Future<List<PermissionRequest>> pendingPermissions(String id) async =>
      List.of(pending[id] ?? const []);

  @override
  Future<void> deleteSession(String id) async {
    deleted.add(id);
    sessions.removeWhere((s) => s.id == id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// The host service (the stop imports through the CLI; the host list is
/// unused by the pass).
class _FakeHost implements OpencodeService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A scripted opencode CLI (the stop's export/import — both always succeed).
class _Cli {
  final List<List<String>> argvs = [];

  Future<OpencodeCliResult> run(
    List<String> argv, {
    Map<String, String>? env,
  }) async {
    argvs.add(List.of(argv));
    if (argv.length > 1 && argv[1] == 'export') {
      return const OpencodeCliResult(
        exitCode: 0,
        stdout: '{"info":{},"messages":[]}',
        stderr: '',
      );
    }
    return const OpencodeCliResult(exitCode: 0, stdout: '', stderr: '');
  }
}

/// The host gh CLI seam: `pr view <branch> …` (the merged-PR read) answers
/// the scripted state per branch, an unscripted branch exits non-zero (no
/// PR for the head ref); `auth status` / `auth token` (the mid-run re-stage,
/// issue #167) answer from [auth], keyed by the full argv.
class _FakeGh {
  final List<List<String>> args = [];
  final Map<String, String> states = {};
  final Map<String, GitCliResult> auth = {};

  GhRunner get run => (List<String> argv) async {
    args.add(List.of(argv));
    final authed = auth[argv.join(' ')];
    if (authed != null) return authed;
    final branch = argv[2];
    final state = states[branch];
    if (state == null) {
      return const GitCliResult(exitCode: 1, stdout: '', stderr: 'no PR');
    }
    return GitCliResult(
      exitCode: 0,
      stdout: jsonEncode({'state': state, 'url': 'https://gh/pr/$branch'}),
      stderr: '',
    );
  };
}

/// A clean-tree, everything-pushed guard answer for the throwaway
/// containers' / exec's git calls.
DockerCliResult _guardOk(List<String> argv) {
  if (argv.contains('status')) {
    return const DockerCliResult(exitCode: 0, stdout: '', stderr: '');
  }
  return const DockerCliResult(exitCode: 0, stdout: '0\n', stderr: '');
}

/// A guard answer with [dirty] porcelain lines and [unpushed] commits.
DockerCliResult Function(List<String>) _guardBlocked({
  String dirty = '',
  String unpushed = '0',
}) => (argv) {
  if (argv.contains('status')) {
    return DockerCliResult(exitCode: 0, stdout: dirty, stderr: '');
  }
  return DockerCliResult(exitCode: 0, stdout: '$unpushed\n', stderr: '');
};

const _permission = PermissionRequest(
  id: 'per_1',
  action: 'edit',
  resources: ['src/x.dart'],
);

OpencodeSession _session(String id) => OpencodeSession(
  id: id,
  title: 'session $id',
  projectId: 'proj-1',
  location: '/workspace',
  created: 1700000000000,
);

/// A boot-completing HTTP server (the wake's descriptor verification).
Future<HttpServer> _bootServer() async {
  final http = await HttpServer.bind('127.0.0.1', 0);
  http.listen((request) {
    request.response.statusCode = 200;
    unawaited(request.response.close());
  });
  return http;
}

void main() {
  group('automated lifecycle pass (issue #101, spec §2.10)', () {
    late Directory root;
    late Directory stateRoot;
    late _FakeDocker docker;
    late _FakeGh gh;
    late _Cli cli;
    late _FakeOrbService orbService;
    late OrbService service;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('oc-orb-lifecycle');
      stateRoot = Directory('${root.path}/state')..createSync();
      docker = _FakeDocker();
      gh = _FakeGh();
      cli = _Cli();
      orbService = _FakeOrbService();
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    void build({bool withGh = false, bool busyReadFails = false}) {
      service = OrbService(
        imageBuilder: OrbImageBuilder(
          context: OrbBuildContext(),
          run: docker._run,
          spawn: docker._spawn,
        ),
        run: docker._run,
        spawn: docker._spawn,
        git: (argv, {workingDirectory}) async =>
            const GitCliResult(exitCode: 0, stdout: '', stderr: ''),
        home: root.path,
        stateRoot: stateRoot,
        bridgePort: 48201,
        gh: withGh ? gh.run : null,
        repoFor: withGh ? (projectId) async => 'o/r' : null,
        opencodeCli: cli.run,
        checkoutFor: (projectId) async => '${root.path}/checkout',
        hostSessions: _FakeHost(),
        orbServiceFor: busyReadFails
            ? (url, password) => throw StateError('orb service down')
            : (url, password) => orbService,
        pollInterval: const Duration(milliseconds: 5),
      );
    }

    /// A row with its state dir and boot password staged (a running row is
    /// never `preparing`, and the busy read finds a password).
    _Row addRow(
      String id, {
      String state = 'running',
      int? port = 49153,
      String? finishedAt,
      bool orphan = false,
      bool volumes = true,
      int? restartPort,
    }) {
      final row = _Row(
        id: id,
        state: state,
        port: port,
        finishedAt: finishedAt,
        orphan: orphan,
        volumes: volumes,
        restartPort: restartPort,
      );
      row.log = 'server password pw-$id-orb\n';
      docker.rows.add(row);
      Directory('${stateRoot.path}/$id').createSync(recursive: true);
      return row;
    }

    final t = DateTime.utc(2026, 3, 1, 12);

    test('the thresholds and the pace are named single-source constants '
        '(spec §2.10.5)', () {
      expect(OrbService.idleStopAfter, const Duration(minutes: 60));
      expect(OrbService.stoppedAutoDeleteAfter, const Duration(hours: 24));
      expect(OrbService.lifecyclePassInterval, const Duration(minutes: 1));
      expect(OrbService.ghRestageBackoff, const Duration(minutes: 5));
    });

    group('idle auto-stop (spec §2.10.1)', () {
      test('an orb idle for 60 minutes is auto-stopped through exactly the '
          'shared stop path: every session exported, imported into the '
          'checkout, deleted from the orb, the container stopped, the '
          'marker set', () async {
        build();
        final row = addRow('a1');
        orbService.sessions.add(_session('ses_1'));
        // Pass 1 at t: the first idle observation — the clock starts.
        await service.runLifecyclePass(now: t);
        expect(row.state, 'running');
        // Before the threshold: kept.
        await service.runLifecyclePass(now: t.add(const Duration(minutes: 59)));
        expect(row.state, 'running');
        expect(docker.runArgs.where((a) => a.first == 'stop'), isEmpty);
        // At the threshold: the shared stop path runs.
        await service.runLifecyclePass(now: t.add(const Duration(minutes: 60)));
        expect(row.state, 'exited');
        expect(argsIndex(docker.runArgs, ['stop', 'orb-a1']), isNonNegative);
        expect(cli.argvs.any((a) => a[1] == 'export'), isTrue);
        expect(cli.argvs.any((a) => a[1] == 'import'), isTrue);
        expect(orbService.deleted, ['ses_1']);
        expect(
          File('${stateRoot.path}/a1/stopped').existsSync(),
          isTrue,
          reason: 'the stop marker is set — the shared stop path, unchanged',
        );
      });

      test('a busy orb (active session) resets the idle clock; idleness '
          'starts counting from the first idle observation after the busy '
          'observation', () async {
        build();
        final row = addRow('a2');
        orbService.sessions.add(_session('ses_1'));
        orbService.active.add('ses_1');
        await service.runLifecyclePass(now: t);
        await service.runLifecyclePass(now: t.add(const Duration(minutes: 70)));
        expect(row.state, 'running');
        // It goes idle: the clock restarts here, not at t.
        orbService.active.clear();
        await service.runLifecyclePass(now: t.add(const Duration(minutes: 71)));
        expect(row.state, 'running');
        await service.runLifecyclePass(
          now: t.add(const Duration(minutes: 130)),
        );
        expect(row.state, 'running');
        await service.runLifecyclePass(
          now: t.add(const Duration(minutes: 131)),
        );
        expect(row.state, 'exited');
      });

      test('a pending permission keeps the orb alive (a mid-turn state is '
          'the most fragile thing to carry in a move)', () async {
        build();
        final row = addRow('a3');
        orbService.sessions.add(_session('ses_1'));
        orbService.pending['ses_1'] = [_permission];
        await service.runLifecyclePass(now: t);
        await service.runLifecyclePass(
          now: t.add(const Duration(minutes: 240)),
        );
        expect(row.state, 'running');
      });

      test('an orb whose busy state cannot be read is kept — the pass '
          'never stops an orb it cannot prove idle', () async {
        build(busyReadFails: true);
        final row = addRow('a4');
        await service.runLifecyclePass(now: t);
        await service.runLifecyclePass(
          now: t.add(const Duration(minutes: 240)),
        );
        expect(row.state, 'running');
      });
    });

    group('stopped-TTL auto-delete (spec §2.10.2)', () {
      test('a stopped orb past the 24-h TTL whose guard passes is deleted, '
          'the guard first (never the force path): container and both '
          'volumes gone', () async {
        build();
        final exit = t.subtract(const Duration(hours: 25));
        addRow(
          'b1',
          state: 'exited',
          port: null,
          finishedAt: exit.toIso8601String(),
        );
        docker.runRespond = _guardOk;
        await service.runLifecyclePass(now: t);
        expect(docker.rows.where((r) => r.id == 'b1'), isEmpty);
        expect(docker.volumeRmNames, ['orb-b1-workspace', 'orb-b1-data']);
        // The guard ran (the throwaway git) before the removal.
        final guardIndex = argsIndex(docker.runArgs, [
          'run',
          '--rm',
          '--entrypoint',
          'git',
          '-v',
          'orb-b1-workspace:/ws',
          'orb:abc123',
          '-C',
          '/ws',
          'status',
          '--porcelain',
        ]);
        final rmIndex = argsIndex(docker.runArgs, ['rm', '-f', 'orb-b1']);
        expect(guardIndex, isNonNegative);
        expect(rmIndex, greaterThan(guardIndex));
      });

      test('a stopped orb under the TTL is kept; a never-exited container '
          'clock keeps it too', () async {
        build();
        docker.runRespond = _guardOk;
        final recent = addRow(
          'b2',
          state: 'exited',
          port: null,
          finishedAt: t.subtract(const Duration(hours: 23)).toIso8601String(),
        );
        final never = addRow('b3', state: 'exited', port: null);
        await service.runLifecyclePass(now: t);
        expect(recent.state, 'exited');
        expect(never.state, 'exited');
      });

      test('a guard-blocked candidate is kept, never forced, and surfaced '
          'as cleanup-pending with the reason', () async {
        build();
        final exit = t.subtract(const Duration(hours: 30));
        addRow(
          'b4',
          state: 'exited',
          port: null,
          finishedAt: exit.toIso8601String(),
        );
        docker.runRespond = _guardBlocked(
          dirty: ' M src/main.dart',
          unpushed: '3',
        );
        await service.runLifecyclePass(now: t);
        expect(docker.rows.map((r) => r.id), contains('b4'));
        expect(docker.volumeRmNames, isEmpty);
        expect(
          docker.runArgs.where((a) => a.first == 'rm'),
          isEmpty,
          reason: 'the automated path never forces',
        );
        final rows = await service.list();
        expect(
          rows.single.state,
          'cleanup_pending:uncommitted work and unpushed work',
        );
      });

      test('an unpushed-only candidate says "unpushed work" (the leaked- '
          'variant backstop, §2.10.4)', () async {
        build();
        final exit = t.subtract(const Duration(hours: 30));
        addRow(
          'b5',
          state: 'exited',
          port: null,
          finishedAt: exit.toIso8601String(),
        );
        docker.runRespond = _guardBlocked(unpushed: '2');
        await service.runLifecyclePass(now: t);
        final rows = await service.list();
        expect(rows.single.state, 'cleanup_pending:unpushed work');
      });

      test('the guard is re-evaluated on every pass: once the work is '
          'safe the badge drops and the pass deletes', () async {
        build();
        final exit = t.subtract(const Duration(hours: 30));
        addRow(
          'b6',
          state: 'exited',
          port: null,
          finishedAt: exit.toIso8601String(),
        );
        docker.runRespond = _guardBlocked(dirty: '?? leftover.txt');
        await service.runLifecyclePass(now: t);
        var rows = await service.list();
        expect(rows.single.state, 'cleanup_pending:uncommitted work');
        // The leftover is committed and pushed — the guard passes now.
        docker.runRespond = _guardOk;
        await service.runLifecyclePass(now: t.add(const Duration(minutes: 1)));
        expect(docker.rows.where((r) => r.id == 'b6'), isEmpty);
        rows = await service.list();
        expect(rows, isEmpty);
      });

      test('no badge before candidacy: a fresh stopped orb with dirty work '
          'stays plain stopped', () async {
        build();
        addRow(
          'b7',
          state: 'exited',
          port: null,
          finishedAt: t.subtract(const Duration(hours: 1)).toIso8601String(),
        );
        docker.runRespond = _guardBlocked(dirty: ' M dirty.txt', unpushed: '1');
        await service.runLifecyclePass(now: t);
        final rows = await service.list();
        expect(rows.single.state, 'stopped');
      });

      test('an unreadable workspace keeps the orb and names itself on the '
          'badge (never delete the unverifiable)', () async {
        build();
        addRow(
          'f1',
          state: 'exited',
          port: null,
          finishedAt: t.subtract(const Duration(hours: 30)).toIso8601String(),
        );
        docker.runRespond = (argv) => const DockerCliResult(
          exitCode: 128,
          stdout: '',
          stderr: 'git failed',
        );
        await service.runLifecyclePass(now: t);
        final rows = await service.list();
        expect(rows.single.state, 'cleanup_pending:workspace unreadable');
        expect(docker.rows.map((r) => r.id), contains('f1'));
      });
    });

    group('merged-PR bypass (spec §2.10.3)', () {
      test('a stopped orb with a merged PR is deleted on the pass following '
          'its stop — no 24-h wait — when the guard passes', () async {
        build(withGh: true);
        gh.states['orb/c1'] = 'merged';
        addRow(
          'c1',
          state: 'exited',
          port: null,
          finishedAt: t.subtract(const Duration(minutes: 2)).toIso8601String(),
        );
        docker.runRespond = _guardOk;
        await service.runLifecyclePass(now: t);
        expect(docker.rows.where((r) => r.id == 'c1'), isEmpty);
      });

      test('a merged PR with a guard-blocked workspace keeps the orb and '
          'surfaces the badge', () async {
        build(withGh: true);
        gh.states['orb/c2'] = 'merged';
        addRow(
          'c2',
          state: 'exited',
          port: null,
          finishedAt: t.subtract(const Duration(minutes: 2)).toIso8601String(),
        );
        docker.runRespond = _guardBlocked(dirty: ' M wip.txt');
        await service.runLifecyclePass(now: t);
        final rows = await service.list();
        expect(rows.single.state, 'cleanup_pending:uncommitted work');
      });

      test('a merged PR never stops a live orb: a running merged orb under '
          'the idle threshold is kept, and dies on the normal idle rule '
          'instead', () async {
        build(withGh: true);
        gh.states['orb/c3'] = 'merged';
        final row = addRow('c3');
        await service.runLifecyclePass(now: t);
        expect(row.state, 'running');
        await service.runLifecyclePass(now: t.add(const Duration(hours: 1)));
        expect(row.state, 'exited');
      });

      test('an open PR does not bypass the TTL: a young stopped orb is '
          'kept', () async {
        build(withGh: true);
        gh.states['orb/c4'] = 'open';
        addRow(
          'c4',
          state: 'exited',
          port: null,
          finishedAt: t.subtract(const Duration(hours: 2)).toIso8601String(),
        );
        docker.runRespond = _guardOk;
        await service.runLifecyclePass(now: t);
        expect(docker.rows.map((r) => r.id), contains('c4'));
      });
    });

    group('the mid-run gh re-stage on push-failed (issue #167, spec §4)', () {
      /// The host gh staging side (the re-stage's [OrbService._stageGhConfig]):
      /// `auth status` reports the active github.com login, `auth token`
      /// hands back [token] — or the scripted refusal [tokenRefusal].
      void hostGh({String token = 'gho_NEW', String? tokenRefusal}) {
        gh.auth['auth status --json hosts'] = const GitCliResult(
          exitCode: 0,
          stdout:
              '{"hosts":{"github.com":[{"state":"success","active":true,'
              '"host":"github.com","login":"dev","tokenSource":"keyring"}]}}',
          stderr: '',
        );
        gh.auth['auth token --user dev'] = tokenRefusal == null
            ? GitCliResult(exitCode: 0, stdout: '$token\n', stderr: '')
            : GitCliResult(exitCode: 1, stdout: '', stderr: tokenRefusal);
      }

      /// The in-container probe answer ([OrbService.verifyGhAuth]): a
      /// passing `gh api user` — or the scripted 401 [refusal].
      void probe({String? refusal}) {
        docker.execRespond = (argv) => refusal == null
            ? const DockerCliResult(exitCode: 0, stdout: 'dev\n', stderr: '')
            : const DockerCliResult(
                exitCode: 1,
                stdout: '',
                stderr:
                    'HTTP 401: Bad credentials (https://api.github.com/user)\n',
              );
      }

      /// The re-probes the pass made in-container (`docker exec … gh`).
      int probes() => docker.runArgs
          .where((a) => a.first == 'exec' && a.contains('gh'))
          .length;

      /// The host-token reads the pass made (status + token per attempt).
      int stageAttempts() =>
          gh.args.where((a) => a.first == 'auth').length ~/ 2;

      test('a running orb whose push is failing gets the host token '
          're-staged into its live gh config and re-probed in-container — '
          'no wake', () async {
        build(withGh: true);
        hostGh();
        probe();
        final row = addRow('g1');
        File(
          '${stateRoot.path}/g1/push-failed',
        ).writeAsStringSync('git push origin HEAD:refs/heads/orb/g1 failed\n');

        await service.runLifecyclePass(now: t);

        // The re-stage wrote the host's current token onto the state-dir gh
        // config — the running container's own GH_CONFIG_DIR (no `docker cp`,
        // no restart: gh re-reads hosts.yml on every call).
        expect(
          File('${stateRoot.path}/g1/gh/hosts.yml').readAsStringSync(),
          contains('oauth_token: gho_NEW'),
        );
        // A passing stage cleared the stale push-failed marker (the next
        // push re-proves it).
        expect(File('${stateRoot.path}/g1/push-failed').existsSync(), isFalse);
        // The authoritative re-probe ran in the container, on the staged
        // config dir.
        final execs = docker.runArgs.where((a) => a.first == 'exec').toList();
        expect(execs, hasLength(1));
        expect(
          execs.single.join(' '),
          contains('-e GH_CONFIG_DIR=${OrbService.inContainerGhConfigDir}'),
        );
        expect(execs.single.join(' '), contains('gh api user'));
        expect(execs.single.join(' '), contains('orb-g1'));
        // No wake: the container was never started or stopped, and no
        // session moved.
        expect(
          docker.runArgs.where((a) => a.first == 'start' || a.first == 'stop'),
          isEmpty,
        );
        expect(orbService.deleted, isEmpty);
        expect(row.state, 'running');
      });

      test('a dead host token ends up on the card with its cause, without a '
          'wake (the re-stage fails; the marker stays)', () async {
        build(withGh: true);
        hostGh(tokenRefusal: 'The token in default is invalid.');
        probe();
        final row = addRow('g2');
        File(
          '${stateRoot.path}/g2/push-failed',
        ).writeAsStringSync('git push origin HEAD:refs/heads/orb/g2 failed\n');

        await service.runLifecyclePass(now: t);

        // The stage failed: the stale marker is kept (it fixed nothing), and
        // the cause is on the state dir, host-side readable.
        expect(File('${stateRoot.path}/g2/push-failed').existsSync(), isTrue);
        expect(
          File('${stateRoot.path}/g2/gh-auth-failed').readAsStringSync(),
          contains('The token in default is invalid.'),
        );
        // The card composes it from the host-side read — and the pass
        // probed no container (nothing staged to probe).
        final rows = await service.list();
        expect(rows.single.pushFailing, isTrue);
        expect(rows.single.ghAuthFailed, contains('invalid'));
        expect(probes(), 0);
        // No wake: the orb keeps running, never started or stopped.
        expect(row.state, 'running');
        expect(
          docker.runArgs.where((a) => a.first == 'start' || a.first == 'stop'),
          isEmpty,
        );
      });

      test('a stage the in-container probe refuses writes the in-container '
          'cause (the host gh read the token; GitHub rejected it)', () async {
        build(withGh: true);
        hostGh(token: 'gho_DEAD');
        probe(refusal: 'revoked');
        final row = addRow('g3');
        // The boot staged the token that then died: the stale config is
        // what the probe re-reads.
        Directory('${stateRoot.path}/g3/gh').createSync(recursive: true);
        File('${stateRoot.path}/g3/gh/hosts.yml')
            .writeAsStringSync('github.com:\n    stale: true\n');
        File(
          '${stateRoot.path}/g3/push-failed',
        ).writeAsStringSync('git push origin HEAD:refs/heads/orb/g3 failed\n');

        await service.runLifecyclePass(now: t);

        // The host's token was re-staged (the stage itself passed — it
        // clears the push marker)…
        expect(
          File('${stateRoot.path}/g3/gh/hosts.yml').readAsStringSync(),
          contains('oauth_token: gho_DEAD'),
        );
        expect(File('${stateRoot.path}/g3/push-failed').existsSync(), isFalse);
        // …and the authoritative probe says GitHub rejects it: the cause is
        // the in-container one, on the marker the card composes.
        expect(probes(), 1);
        expect(
          File('${stateRoot.path}/g3/gh-auth-failed').readAsStringSync(),
          contains('Bad credentials'),
        );
        final rows = await service.list();
        expect(rows.single.ghAuthFailed, contains('Bad credentials'));
        expect(row.state, 'running');
      });

      test('a permanently broken token is re-probed at most once per backoff '
          'per marker generation (no per-minute hammering)', () async {
        build(withGh: true);
        hostGh(tokenRefusal: 'The token in default is invalid.');
        probe(refusal: 'revoked');
        final row = addRow('g4');
        // The boot staged the token that then died: the stale config keeps
        // the probe live on every attempt.
        Directory('${stateRoot.path}/g4/gh').createSync(recursive: true);
        File('${stateRoot.path}/g4/gh/hosts.yml')
            .writeAsStringSync('github.com:\n    stale: true\n');
        File('${stateRoot.path}/g4/push-failed').writeAsStringSync('x\n');

        await service.runLifecyclePass(now: t);
        expect(probes(), 1, reason: 'the first attempt probes');
        // Within the backoff: the pass still runs, but re-stages nothing.
        await service.runLifecyclePass(now: t.add(const Duration(minutes: 4)));
        expect(probes(), 1, reason: 'the backoff has not expired');
        // Past it: the generation re-attempts.
        await service.runLifecyclePass(now: t.add(const Duration(minutes: 5)));
        expect(probes(), 2, reason: 'the backoff expired: one re-attempt');
        expect(
          row.state,
          'running',
          reason: 'the throttle never stops the orb',
        );
      });

      test('a fresh push-failed generation re-attempts promptly — the '
          'backoff is per marker generation, not a global pace', () async {
        build(withGh: true);
        hostGh();
        probe();
        final row = addRow('g5');
        final marker = File('${stateRoot.path}/g5/push-failed');
        marker.writeAsStringSync('x\n');
        final firstGeneration = marker.lastModifiedSync();

        // Attempt 1: the stage passes and clears the marker.
        await service.runLifecyclePass(now: t);
        expect(marker.existsSync(), isFalse);

        // A push succeeded (the marker cleared), then the next one failed:
        // a new generation — its mtime moves past the gate's.
        marker.writeAsStringSync('x\n');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(marker.lastModifiedSync(), isNot(firstGeneration));

        await service.runLifecyclePass(now: t.add(const Duration(minutes: 1)));
        expect(
          stageAttempts(),
          2,
          reason:
              'a fresh generation re-attempts promptly, inside the '
              'backoff of the old one',
        );
        expect(row.state, 'running');
      });

      test('the list stays probe-free: a push-failed row triggers no re-stage '
          'and no container probe from it (spec §2.2/§2.9)', () async {
        build(withGh: true);
        hostGh();
        final row = addRow('g6');
        File('${stateRoot.path}/g6/push-failed').writeAsStringSync('x\n');

        final rows = await service.list();

        expect(
          rows.single.pushFailing,
          isTrue,
          reason: 'the marker is still composed host-side',
        );
        expect(
          docker.runArgs.where((a) => a.first == 'exec'),
          isEmpty,
          reason: 'the list adds no container probe',
        );
        expect(
          gh.args.where((a) => a.first == 'auth'),
          isEmpty,
          reason: 'the list never re-stages',
        );
        expect(File('${stateRoot.path}/g6/gh/hosts.yml').existsSync(), isFalse);
        expect(row.state, 'running');
      });

      test('the pass does not re-stage an orb it is auto-stopping (the wake '
          're-stages on its shared start path)', () async {
        build(withGh: true);
        hostGh(tokenRefusal: 'The token in default is invalid.');
        probe();
        final row = addRow('g7');
        File('${stateRoot.path}/g7/push-failed').writeAsStringSync('x\n');

        // The idle clock starts; the re-stage attempts (the stage fails,
        // nothing is staged to probe).
        await service.runLifecyclePass(now: t);
        expect(stageAttempts(), 1);
        expect(probes(), 0);
        // At the threshold the pass auto-stops the orb — and skips the
        // re-stage (a stopping orb is never probed).
        await service.runLifecyclePass(now: t.add(const Duration(minutes: 60)));

        expect(row.state, 'exited');
        expect(stageAttempts(), 1, reason: 'no re-stage of a stopping orb');
        expect(probes(), 0);
      });
    });

    group('orphans, broken orbs, and the pass surface (§2.10.4/§2.10.5)', () {
      test('a leaked orphan and a broken orb are never auto-reaped; a '
          'clean stopped candidate dies', () async {
        build();
        docker.runRespond = _guardOk;
        addRow('d1', orphan: true);
        addRow('d2', state: 'exited', port: null, volumes: false);
        addRow(
          'd3',
          state: 'exited',
          port: null,
          finishedAt: t.subtract(const Duration(hours: 50)).toIso8601String(),
        );
        await service.runLifecyclePass(now: t);
        expect(docker.rows.map((r) => r.id), containsAll(['d1', 'd2']));
        expect(docker.rows.map((r) => r.id), isNot(contains('d3')));
      });

      test('the periodic pass arms and disarms through the service', () {
        build();
        expect(service.lifecyclePassRunning, isFalse);
        service.startLifecyclePass(interval: const Duration(milliseconds: 50));
        expect(service.lifecyclePassRunning, isTrue);
        service.stopLifecyclePass();
        expect(service.lifecyclePassRunning, isFalse);
      });

      test('the periodic pass runs the rule on its timer', () async {
        build();
        docker.runRespond = _guardOk;
        addRow(
          'd4',
          state: 'exited',
          port: null,
          finishedAt: t.subtract(const Duration(hours: 30)).toIso8601String(),
        );
        // A tiny interval + the real clock: FinishedAt is far in the past
        // of DateTime.now(), so the first timer tick deletes.
        service.startLifecyclePass(interval: const Duration(milliseconds: 10));
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (docker.rows.isNotEmpty) {
          if (DateTime.now().isAfter(deadline)) {
            fail('the periodic pass never deleted the candidate');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        service.stopLifecyclePass();
      });

      test('a wake clears the badge and the orb runs again', () async {
        build();
        final http = await _bootServer();
        addRow(
          'e1',
          state: 'exited',
          port: null,
          finishedAt: t.subtract(const Duration(hours: 30)).toIso8601String(),
          restartPort: http.port,
        );
        docker.runRespond = _guardBlocked(dirty: ' M dirty.txt');
        await service.runLifecyclePass(now: t);
        expect(
          (await service.list()).single.state,
          startsWith('cleanup_pending'),
        );
        final woke = await service.wake('e1');
        await http.close(force: true);
        expect(woke.state, 'running');
        expect((await service.list()).single.state, 'running');
      });
    });
  });
}
