import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/docker/docker_backend.dart';
import 'package:opencodebridge/bridge/orb/orb_image_builder.dart';
import 'package:opencodebridge/bridge/orb/orb_service.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';
import 'package:opencodebridge/bridge/orb/orb_build_context.dart';

/// A scripted docker CLI child (the boot follow stream).
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
    this.name = '',
    this.project = '',
    this.state = 'running',
    this.port,
    this.log = '',
    this.volumes = true,
    this.bootable = true,
    this.restartPort,
  });

  final String id;
  final String name;
  final String project;
  String state;
  int? port;
  String log;

  /// Whether the orb's labeled volumes exist (false scripts a broken
  /// workspace — spec §2.2).
  final bool volumes;

  /// Whether `docker start` brings the orb up (a password line lands in
  /// the log); `false` scripts a boot that never completes.
  final bool bootable;

  /// The password the first boot logs; every later `docker start` mints a
  /// fresh one (`<password>-<boot number>`) — the in-container service
  /// re-derives the password at every start (spec §7.1).
  final String password = 'pw-orb-1';

  /// The ephemeral port a `docker start` re-maps to; `null` keeps the
  /// current port (or one is minted).
  final int? restartPort;

  String get container => 'orb-$id';

  Map<String, String> get labels => {
    'ocb.orb': 'true',
    'ocb.id': id,
    'ocb.name': name,
    'ocb.project': project,
    'ocb.branch': 'orb/$id',
    'ocb.created': '2026-01-01T00:00:00.000Z',
  };
}

/// The DockerRunner/DockerSpawner seam over a mutable set of [_Row]s:
/// `docker stop`/`start` mutate the row's state, the multi-container
/// `inspect` answers per row, `volume rm` drops the row's volumes.
class _FakeDocker {
  final List<_Row> rows = [];
  final List<List<String>> runArgs = [];
  final List<_FakeProcess> spawned = [];
  final List<_FakeProcess> processes = [];

  /// Volumes that exist beyond the rows' own (an orphan's labeled volumes).
  final List<String> extraVolumes = [];

  /// Volumes removed through `volume rm` (`docker rm -f` / `volume rm`
  /// otherwise mutate the fake's world).
  final List<String> removedVolumes = [];

  /// Containers removed through `docker rm -f`.
  final List<String> removedContainers = [];

  /// When set, every docker call fails with this (the daemon-down case).
  DockerCliResult? unreachable;

  static const DockerCliResult ok = DockerCliResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );

  (DockerRunner, DockerSpawner) bind() => (_run, _spawn);

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
    final down = unreachable;
    if (down != null) return down;
    return _dispatch(List.of(argv));
  }

  DockerCliResult _dispatch(List<String> argv) {
    switch (argv[0]) {
      case 'ps':
        return DockerCliResult(
          exitCode: 0,
          stdout: rows.map((r) => r.container).join('\n'),
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
        if (!row.bootable) return ok;
        row.state = 'running';
        row.port = row.restartPort ?? row.port ?? 49321;
        // The in-container service mints a fresh password on every start,
        // and the line lands in the log only once the service is up —
        // after the start returns, so the boot wait's first poll can race
        // it (the stale-line trap).
        final bootNumber = OrbService.countServerPasswords(row.log) + 1;
        final minted = bootNumber == 1
            ? row.password
            : '${row.password}-$bootNumber';
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 1), () {
            row.log += 'server password $minted\n';
          }),
        );
        return ok;
      case 'rm':
        // `docker rm -f <container>`.
        final name = argv.last;
        final row = _row(name);
        if (row == null) {
          return const DockerCliResult(
            exitCode: 1,
            stdout: '',
            stderr: 'no such container',
          );
        }
        rows.remove(row);
        removedContainers.add(name);
        return ok;
      case 'cp':
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
        // `--format <fmt>` may precede or follow the names.
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
          case '{{.Id}}':
            final row = _row(names.single);
            if (row == null) {
              return const DockerCliResult(
                exitCode: 1,
                stdout: '',
                stderr: 'no such container',
              );
            }
            return const DockerCliResult(
              exitCode: 0,
              stdout: 'container-id',
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
                ] else
                  // A broken:workspace orb: the workspace volume is the
                  // missing half, the data volume stands.
                  'orb-${row.id}-data',
              ...extraVolumes,
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
            removedVolumes.add(argv.last);
            for (final row in rows) {
              if (argv.last == 'orb-${row.id}-workspace' ||
                  argv.last == 'orb-${row.id}-data') {
                extraVolumes.remove(argv.last);
              }
            }
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
    final process = processes.isNotEmpty
        ? processes.removeAt(0)
        : _FakeProcess();
    spawned.add(process);
    return process.toProcess();
  }
}

/// The GitRunner seam (the wake's probes never fire on recovery, but the
/// constructor requires one).
class _FakeGit {
  GitRunner get run =>
      (List<String> argv, {String? workingDirectory}) async =>
          const GitCliResult(exitCode: 0, stdout: '', stderr: '');
}

/// A scripted opencode service (an orb's or the host's).
class _FakeOpencode implements OpencodeService {
  _FakeOpencode([List<String> sessionIds = const []])
    : sessions = [for (final id in sessionIds) _session(id)];

  final List<OpencodeSession> sessions;
  final List<String> deleted = [];

  @override
  Future<List<OpencodeSession>> listSessions() async => List.of(sessions);

  @override
  Future<void> deleteSession(String id) async {
    deleted.add(id);
    sessions.removeWhere((s) => s.id == id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

OpencodeSession _session(String id) => OpencodeSession(
  id: id,
  title: 'title-$id',
  projectId: 'proj-1',
  created: 1700000000000,
  location: '/workspace',
);

void main() {
  group('OrbService recovery (issue #102, spec §2.11)', () {
    late Directory root;
    late Directory home;
    late Directory stateRoot;
    late OrbImageBuilder builder;
    late _FakeDocker docker;

    const orbId = 'a1b2c3d4';
    const project = 'proj-1';

    setUp(() async {
      root = await Directory.systemTemp.createTemp('oc-orb-rec');
      home = Directory('${root.path}/home')..createSync();
      stateRoot = Directory('${root.path}/state');
      final context = OrbBuildContext(dir: Directory('${root.path}/ctx'));
      await context.materialize();
      docker = _FakeDocker();
      builder = OrbImageBuilder(
        context: context,
        run: docker._run,
        spawn: docker._spawn,
      );
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    /// A labeled orb container; the default log carries its first boot's
    /// password (a crashed orb always logged at least one).
    _Row addOrb({
      String id = orbId,
      String state = 'exited',
      int? port,
      String? log,
      bool volumes = true,
      bool bootable = true,
      int? restartPort,
      String name = 'dev',
    }) {
      final row = _Row(
        id: id,
        name: name,
        project: project,
        state: state,
        port: port,
        log: log ?? 'server password pw-orb-1\n',
        volumes: volumes,
        bootable: bootable,
        restartPort: restartPort,
      );
      docker.rows.add(row);
      return row;
    }

    void stateDir({String id = orbId}) {
      Directory('${stateRoot.path}/$id').createSync(recursive: true);
    }

    void setMarker({String id = orbId}) {
      File('${stateRoot.path}/$id/stopped')
        ..createSync(recursive: true)
        ..writeAsStringSync(DateTime.now().toUtc().toIso8601String());
    }

    bool markerPresent({String id = orbId}) =>
        File('${stateRoot.path}/$id/stopped').existsSync();

    /// The orb service accepting descriptor verification (every request
    /// answers 200, like a booted orb's `/api/session`).
    Future<HttpServer> bootServer() async {
      final http = await HttpServer.bind('127.0.0.1', 0);
      http.listen((request) {
        request.response.statusCode = 200;
        unawaited(request.response.close());
      });
      return http;
    }

    OrbService service({
      OpencodeService? hostSessions,
      OpencodeService Function(String url, String password)? orbServiceFor,
      Duration? bootTimeout,
    }) {
      final (run, spawn) = docker.bind();
      return OrbService(
        imageBuilder: builder,
        run: run,
        spawn: spawn,
        git: _FakeGit().run,
        home: home.path,
        stateRoot: stateRoot,
        bridgePort: 48201,
        hostIp: () async => '10.1.2.3',
        hostSessions: hostSessions,
        orbServiceFor: orbServiceFor,
        bootTimeout: bootTimeout ?? const Duration(seconds: 5),
        pollInterval: const Duration(milliseconds: 5),
      );
    }

    List<List<String>> dockerArgsStartingWith(List<String> prefix) => [
      for (final argv in docker.runArgs)
        if (argv.length >= prefix.length &&
            argv.sublist(0, prefix.length).join(' ') == prefix.join(' '))
          argv,
    ];

    // ------------------------------------------------------------------
    // The startup auto-wake (spec §2.11: the bridge owns every start)

    test('a stopped orb without the ocb.stopped marker is auto-woken '
        'through the full start path', () async {
      final http = await bootServer();
      addOrb(restartPort: http.port);
      stateDir();

      await service().recover();

      await http.close();
      expect(
        dockerArgsStartingWith(['start', 'orb-$orbId']),
        hasLength(1),
        reason:
            'the bridge owns every start: the label-less orb was '
            'running at crash time and must come back up',
      );
      expect(docker.rows.single.state, 'running');
      expect(markerPresent(), isFalse);
    });

    test('a stopped orb with the ocb.stopped marker is left stopped (the '
        'move-to-host already ran)', () async {
      addOrb();
      stateDir();
      setMarker();

      await service().recover();

      expect(
        dockerArgsStartingWith(['start', 'orb-$orbId']),
        isEmpty,
        reason:
            'a clean stop is a user decision — the bridge never wakes '
            'what the user stopped',
      );
      expect(docker.rows.single.state, 'exited');
      expect(markerPresent(), isTrue);
    });

    test('a failed auto-wake is the boot-failure state and does not block '
        "the other orbs' recovery", () async {
      final http = await bootServer();
      // The first orb's boot never completes; the second boots fine.
      addOrb(id: 'deadbeef', bootable: false, name: 'stuck');
      addOrb(id: orbId, restartPort: http.port, name: 'dev');
      stateDir(id: 'deadbeef');
      stateDir();

      await service(bootTimeout: const Duration(milliseconds: 100)).recover();

      await http.close();
      // The unbootable orb is left as-is (no marker: the next startup
      // re-tries); the healthy one came back up.
      final stuck = docker.rows.singleWhere((r) => r.id == 'deadbeef');
      final healthy = docker.rows.singleWhere((r) => r.id == orbId);
      expect(stuck.state, 'exited');
      expect(healthy.state, 'running');
    });

    // ------------------------------------------------------------------
    // The startup reconciliation (spec §2.11: host canonical)

    test('a session id present on both the host and a running orb has its '
        'in-orb copy deleted (the host is canonical)', () async {
      addOrb(state: 'running', port: 49153);
      stateDir();
      final orb = _FakeOpencode(['s-1', 's-2']);
      final host = _FakeOpencode(['s-1']);

      await service(
        hostSessions: host,
        orbServiceFor: (url, password) => orb,
      ).recover();

      // The interrupted stop completes: s-1 exists exactly once, on the
      // host. s-2 lives only on the orb and is untouched.
      expect(orb.deleted, ['s-1']);
      expect(host.deleted, isEmpty);
      expect(orb.sessions.map((s) => s.id), ['s-2']);
      expect(host.sessions.map((s) => s.id), ['s-1']);
    });

    test('an auto-woken orb is reconciled in the same pass: the stop the '
        'crash interrupted completes (every session exactly once)', () async {
      final http = await bootServer();
      // The crash mid-stop: the container is down unmarked, s-1 already
      // imported on the host but still present on the orb.
      addOrb(restartPort: http.port);
      stateDir();
      final orb = _FakeOpencode(['s-1']);
      final host = _FakeOpencode(['s-1']);

      await service(
        hostSessions: host,
        orbServiceFor: (url, password) => orb,
      ).recover();

      await http.close();
      expect(docker.rows.single.state, 'running');
      // The in-orb duplicate is deleted; the host copy is canonical.
      expect(orb.deleted, ['s-1']);
      expect(host.deleted, isEmpty);
    });

    // ------------------------------------------------------------------
    // The broken orb actions (spec §2.2/§9.4: surfaced, never silently
    // repaired)

    test('start-with-fresh-state on a broken:state orb recreates the state '
        'dir and runs the normal wake', () async {
      final http = await bootServer();
      addOrb(restartPort: http.port);
      // The state dir is gone (broken:state); the volumes exist.

      final record = await service().startWithFreshState(orbId);

      await http.close();
      expect(record.state, 'running');
      // A fresh state dir exists (a fresh opencode db comes with it).
      expect(Directory('${stateRoot.path}/$orbId').existsSync(), isTrue);
      expect(dockerArgsStartingWith(['start', 'orb-$orbId']), hasLength(1));
    });

    test('start-with-fresh-state refuses a broken:workspace orb (the '
        'workspace is what a fresh state cannot replace)', () async {
      addOrb(volumes: false);
      // The state dir is gone too — the workspace check runs first, so the
      // state is `broken:workspace`; nothing may be created either way.

      expect(
        service().startWithFreshState(orbId),
        throwsA(
          isA<OrbRefusalError>().having(
            (e) => e.code,
            'code',
            OrbRefusalError.notWakeable,
          ),
        ),
      );
      expect(
        dockerArgsStartingWith(['start', 'orb-$orbId']),
        isEmpty,
        reason: 'the refusal must come before any start',
      );
      expect(
        Directory('${stateRoot.path}/$orbId').existsSync(),
        isFalse,
        reason: 'the refusal must not recreate the state dir',
      );
    });

    test(
      'start-with-fresh-state refuses a running orb and an unknown id',
      () async {
        addOrb(state: 'running', port: 49153);
        stateDir();
        expect(
          service().startWithFreshState(orbId),
          throwsA(isA<OrbRefusalError>()),
        );
        expect(
          service().startWithFreshState('ffffffff'),
          throwsA(isA<OrbNotFoundError>()),
        );
      },
    );
  });
}
