import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/docker/docker_backend.dart';
import 'package:opencodebridge/bridge/orb/orb_build_context.dart';
import 'package:opencodebridge/bridge/orb/orb_image_builder.dart';
import 'package:opencodebridge/bridge/orb/orb_service.dart';
import 'package:opencodebridge/bridge/sessions/opencode_service.dart';
import 'package:opencodebridge/model/permission.dart';

/// A deep-equal index lookup ([List.indexOf] compares list elements by
/// identity, which never matches a fresh literal).
int argsIndex(List<List<String>> args, List<String> target) => args.indexWhere(
  (a) =>
      a.length == target.length &&
      [for (var i = 0; i < a.length; i++) a[i] == target[i]].every((x) => x),
);

/// A scripted docker CLI child (the boot follow stream).
class _FakeProcess {
  final StreamController<String> stdout = StreamController<String>();
  final StreamController<String> stderr = StreamController<String>();
  final Completer<int> _exit = Completer<int>();

  /// Whether [kill] ran (the boot wait kills the log follow at the end).
  bool killed = false;

  DockerProcess toProcess() => DockerProcess(
    stdout: stdout.stream,
    stderr: stderr.stream,
    exitCode: _exit.future,
    kill: kill,
  );

  Future<void> kill() async {
    killed = true;
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
    this.restartPort,
    this.orphan = false,
  });

  final String id;
  final String name;
  final String project;
  String state;
  int? port;
  String log;
  final bool volumes;

  /// The password the first boot logs; every later `docker start` mints a
  /// fresh one (`<password>-<boot number>`) — the in-container service
  /// re-derives the password at every start (spec §7.1), and the log
  /// keeps the lines of every boot.
  final String password = 'pw-orb-1';

  /// The ephemeral port a `docker start` re-maps to (the update's port
  /// re-read); `null` keeps the current port (or one is minted).
  final int? restartPort;

  /// Whether the row has no container (an orphan — the labeled volumes
  /// without their container): the `ps` and the container `inspect` skip
  /// it, the volume commands keep it.
  final bool orphan;

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
/// `docker stop`/`start` mutate the row's state, `docker rm` removes it,
/// `docker create` registers a new row, and the one-shot containers
/// (`docker run --rm`, the guard's git and the export's tar) and the
/// `docker exec` (the running-orb guard and export) are answered by the
/// test's callbacks — the throwaway containers' arguments carry the
/// wall-clock export file name, which the tests cannot pre-script by
/// exact-argv match.
class _FakeDocker {
  final List<_Row> rows = [];
  final List<List<String>> runArgs = [];
  final List<List<String>> spawnArgs = [];
  final List<_FakeProcess> spawned = [];
  final List<_FakeProcess> processes = [];

  /// The ephemeral port a `docker create`d + started orb re-maps to (the
  /// update's create path); `null` mints one.
  int? defaultRestartPort;

  /// The `docker exec` responder (the running-orb guard's git, the
  /// running-orb export's tar/rm); `null` fails the call.
  DockerCliResult Function(List<String> argv)? execRespond;

  /// The `docker run --rm` responder (the throwaway-container paths — the
  /// stopped-orb guard's git, the export's tar); `null` fails the call.
  DockerCliResult Function(List<String> argv)? runRespond;

  /// The `volume ls` answer, overriding the row-derived one; `null` derives
  /// it from the rows' volumes.
  String? volumeLs;

  /// The `volume rm <name>` result, keyed by the volume name (default ok) —
  /// the deletion's idempotency (an already-absent volume is tolerated).
  final Map<String, DockerCliResult> volumeRm = {};

  /// The `volume rm` targets, in order.
  final List<String> volumeRmNames = [];

  /// The image the container was created from (`{{.Config.Image}}`);
  /// `null` (or a missing/orphan row) answers the exit-1 `no such
  /// container`.
  String? containerImage;

  /// The container's `Config.Env` (`{{json .Config.Env}}`); `null` (or a
  /// missing/orphan row) answers the exit-1 `no such container`.
  String? containerEnv;

  /// The number of `docker logs` calls that succeed before the fake starts
  /// failing them (the update's unreadable-password path); 0 never fails.
  int logsSucceeds = 0;
  int _logsCalls = 0;

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
    return _dispatch(List.of(argv));
  }

  DockerCliResult _dispatch(List<String> argv) {
    switch (argv[0]) {
      case 'image':
        // `image inspect <tag>` exit 0: the image is present (no rebuild).
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
        // The in-container service mints a fresh password on every
        // start, and the line lands in the log only once the service
        // is up — after the start returns, so the boot wait's first
        // poll can race it (the stale-line trap).
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
        if (argv[0] == 'create') {
          // Register the created container (the update's create path):
          // the labels carry the id, name, and project.
          final labels = <String, String>{};
          for (var i = 1; i < argv.length - 1; i++) {
            if (argv[i] == '-l') {
              final kv = argv[i + 1].split('=');
              labels[kv[0]] = kv.sublist(1).join('=');
            }
          }
          rows.add(
            _Row(
              id: labels['ocb.id'] ?? '',
              name: labels['ocb.name'] ?? '',
              project: labels['ocb.project'] ?? '',
              state: 'created',
              restartPort: defaultRestartPort,
            ),
          );
        }
        return ok;
      case 'logs':
        if (logsSucceeds > 0) {
          _logsCalls++;
          if (_logsCalls > logsSucceeds) {
            return const DockerCliResult(
              exitCode: 1,
              stdout: '',
              stderr: 'logs unavailable',
            );
          }
        }
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
            if (row == null || row.orphan) {
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
          case '{{.Config.Image}}':
            final row = _row(names.single);
            if (row == null || row.orphan || containerImage == null) {
              return const DockerCliResult(
                exitCode: 1,
                stdout: '',
                stderr: 'no such container',
              );
            }
            return DockerCliResult(
              exitCode: 0,
              stdout: containerImage!,
              stderr: '',
            );
          case '{{json .Config.Env}}':
            final row = _row(names.single);
            if (row == null || row.orphan || containerEnv == null) {
              return const DockerCliResult(
                exitCode: 1,
                stdout: '',
                stderr: 'no such container',
              );
            }
            return DockerCliResult(
              exitCode: 0,
              stdout: containerEnv!,
              stderr: '',
            );
        }
        throw StateError('unexpected inspect format: $format');
      case 'volume':
        switch (argv[1]) {
          case 'ls':
            final override = volumeLs;
            if (override != null) {
              return DockerCliResult(exitCode: 0, stdout: override, stderr: '');
            }
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
          case 'rm':
            final name = argv.last;
            volumeRmNames.add(name);
            return volumeRm[name] ?? ok;
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
    spawnArgs.add(List.of(argv));
    final process = processes.isNotEmpty
        ? processes.removeAt(0)
        : _FakeProcess();
    spawned.add(process);
    return process.toProcess();
  }
}

/// The GitRunner seam (the exit paths never run git on the host — the
/// default ok answers the service's required seam).
class _FakeGit {
  final List<List<String>> args = [];
  final Map<String, GitCliResult> results = {};

  GitRunner get run => (List<String> argv, {String? workingDirectory}) async {
    args.add(List.of(argv));
    return results[argv.join(' ')] ??
        const GitCliResult(exitCode: 0, stdout: '', stderr: '');
  };
}

/// The GhRunner seam, scripted by the argv (the gh auth probe, issue #120).
class _FakeGh {
  final List<List<String>> args = [];
  final Map<String, GitCliResult> results = {};

  GhRunner get run => (List<String> argv) async {
    args.add(List.of(argv));
    return results[argv.join(' ')] ??
        const GitCliResult(exitCode: 0, stdout: '', stderr: '');
  };
}

/// A scripted opencode service (the running orb's — the update's busy
/// check).
class _FakeOpencode implements OpencodeService {
  final List<OpencodeSession> sessions = [];
  final Map<String, String> names = {};
  final Set<String> active = {};
  final Map<String, List<PermissionRequest>> pending = {};

  @override
  Future<List<OpencodeSession>> listSessions() async => List.of(sessions);

  @override
  Future<Map<String, String>> projectNames() async => Map.of(names);

  @override
  Future<Set<String>> activeSessionIds() async => Set.of(active);

  @override
  Future<List<PermissionRequest>> pendingPermissions(String id) async =>
      List.of(pending[id] ?? const <PermissionRequest>[]);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

OpencodeSession _session(
  String id, {
  String projectId = 'proj-1',
  String location = '/workspace',
}) => OpencodeSession(
  id: id,
  title: 'title-$id',
  projectId: projectId,
  created: 1700000000000,
  location: location,
);

void main() {
  group('OrbService exit paths (issue #98, spec §2.7/§2.8/§3.4)', () {
    late Directory root;
    late Directory home;
    late Directory checkout;
    late Directory stateRoot;
    late OrbImageBuilder builder;
    late _FakeDocker docker;
    late _FakeGit git;

    const orbId = 'a1b2c3d4';
    const container = 'orb-$orbId';
    const orbPassword = 'pw-orb-1';
    const project = 'proj-1';

    setUp(() async {
      root = await Directory.systemTemp.createTemp('oc-orb-exit');
      home = Directory('${root.path}/home')..createSync();
      checkout = Directory('${root.path}/checkout')..createSync();
      stateRoot = Directory('${root.path}/state');
      final context = OrbBuildContext(dir: Directory('${root.path}/ctx'));
      await context.materialize();
      git = _FakeGit();
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

    /// A labeled orb container row (running by default, with the
    /// descriptor's password in its log so the list keeps it `running`).
    _Row addOrb({
      String state = 'running',
      int? port,
      String? log,
      bool volumes = true,
      int? restartPort,
      String name = 'dev',
    }) {
      final row = _Row(
        id: orbId,
        name: name,
        project: project,
        state: state,
        port: port,
        log: log ?? 'server password $orbPassword\n',
        volumes: volumes,
        restartPort: restartPort,
      );
      docker.rows.add(row);
      return row;
    }

    /// An orphan: the labeled volumes without their container.
    _Row addOrphan({bool volumes = true, String name = 'dev'}) {
      final row = _Row(
        id: orbId,
        name: name,
        project: project,
        state: 'exited',
        log: '',
        volumes: volumes,
        orphan: true,
      );
      docker.rows.add(row);
      return row;
    }

    void stateDir() {
      Directory('${stateRoot.path}/$orbId').createSync(recursive: true);
    }

    /// The last injection's staging copy (bridge-owned, deleted with the
    /// orb — spec §2.7: nothing orb-related remains).
    void stagedDir() {
      final staged = Directory('${stateRoot.path}/staged-$orbId')
        ..createSync(recursive: true);
      File('${staged.path}/opencode.jsonc').writeAsStringSync('{}');
    }

    void setMarker() {
      File('${stateRoot.path}/$orbId/stopped')
        ..createSync(recursive: true)
        ..writeAsStringSync(DateTime.now().toUtc().toIso8601String());
    }

    bool markerPresent() =>
        File('${stateRoot.path}/$orbId/stopped').existsSync();

    void hostConfig() {
      final config = Directory('${home.path}/.config/opencode');
      config.createSync(recursive: true);
      File('${config.path}/opencode.jsonc')
          .writeAsStringSync('{\n  "model": "test"\n}\n');
      File('${config.path}/service.json').writeAsStringSync('{}\n');
    }

    void checkoutEnv() {
      File('${checkout.path}/.env').writeAsStringSync('A=1\n');
      File('${checkout.path}/.env.local').writeAsStringSync('B=2\n');
      File('${checkout.path}/.env.example').writeAsStringSync('EXAMPLE\n');
    }

    Future<HttpServer> bootServer() async {
      final http = await HttpServer.bind('127.0.0.1', 0);
      http.listen((request) {
        request.response.statusCode = 200;
        unawaited(request.response.close());
      });
      return http;
    }

    OrbService service({
      Future<String?> Function(String projectId)? checkoutFor,
      OpencodeService? hostSessions,
      OpencodeService Function(String url, String password)? orbServiceFor,
      GhRunner? gh,
      Duration? bootTimeout,
      Duration? pollInterval,
    }) {
      final (run, spawn) = docker.bind();
      return OrbService(
        imageBuilder: builder,
        run: run,
        spawn: spawn,
        git: git.run,
        home: home.path,
        stateRoot: stateRoot,
        bridgePort: 48201,
        hostIp: () async => '10.1.2.3',
        checkoutFor: checkoutFor,
        hostSessions: hostSessions,
        orbServiceFor: orbServiceFor,
        gh: gh,
        bootTimeout: bootTimeout ?? const Duration(minutes: 10),
        pollInterval: pollInterval ?? const Duration(milliseconds: 5),
      );
    }

    // The update re-stages the gh credentials (issue #120, wake-style
    // re-injection): the recreate writes the current host token into the
    // state dir's gh config and clears a stale push marker.
    test('the update re-stages the gh credentials and clears the push '
        'marker', () async {
      addOrb(state: 'exited');
      stateDir();
      setMarker();
      hostConfig();
      docker.containerEnv = jsonEncode(['ORB_ID=$orbId']);
      // A stale marker from a pre-fix boot: the credentials re-stage
      // clears it (the marker's verdict is no longer known).
      File('${stateRoot.path}/$orbId/push-failed').writeAsStringSync('x\n');
      final gh = _FakeGh();
      gh.results['auth status --json hosts'] = const GitCliResult(
        exitCode: 0,
        stdout:
            '{"hosts":{"github.com":[{"state":"success","active":true,'
            '"host":"github.com","login":"dev","tokenSource":"keyring"}]}}',
        stderr: '',
      );
      gh.results['auth token'] = const GitCliResult(
        exitCode: 0,
        stdout: 'gho_UPDATE\n',
        stderr: '',
      );

      final record = await service(gh: gh.run).update(orbId);

      expect(record.state, 'stopped');
      expect(
        File('${stateRoot.path}/$orbId/gh/hosts.yml').readAsStringSync(),
        contains('oauth_token: gho_UPDATE'),
      );
      expect(
        File('${stateRoot.path}/$orbId/push-failed').existsSync(),
        isFalse,
      );
    });

    // ----------------------------------------------------------------------
    // The deletion guard (spec §2.7)

    group('deleteGuard (spec §2.7)', () {
      test(
        'a running orb with a clean, fully pushed tree is deletable',
        () async {
          addOrb(port: 49101);
          docker.execRespond = (argv) {
            if (argv.last == '--porcelain') {
              return const DockerCliResult(exitCode: 0, stdout: '', stderr: '');
            }
            return const DockerCliResult(
              exitCode: 0,
              stdout: '0\n',
              stderr: '',
            );
          };

          final guard = await service().deleteGuard(orbId);

          expect(guard.evaluable, isTrue);
          expect(guard.dirty, isEmpty);
          expect(guard.unpushedCount, 0);
          expect(guard.canDelete, isTrue);
          expect(guard.reasons, isEmpty);
          // The running container is probed in place.
          expect(
            argsIndex(docker.runArgs, [
              'exec',
              container,
              'git',
              '-C',
              '/workspace',
              'status',
              '--porcelain',
            ]),
            isNonNegative,
          );
          expect(
            argsIndex(docker.runArgs, [
              'exec',
              container,
              'git',
              '-C',
              '/workspace',
              'rev-list',
              '--count',
              'HEAD',
              '--not',
              '--remotes',
            ]),
            isNonNegative,
          );
        },
      );

      test('a running orb with a dirty tree and unpushed commits is not '
          'deletable', () async {
        addOrb(port: 49101);
        docker.execRespond = (argv) {
          if (argv.last == '--porcelain') {
            return const DockerCliResult(
              exitCode: 0,
              stdout: ' M src/app.dart\n?? scratch.txt\n',
              stderr: '',
            );
          }
          return const DockerCliResult(exitCode: 0, stdout: '2\n', stderr: '');
        };

        final guard = await service().deleteGuard(orbId);

        expect(guard.evaluable, isTrue);
        expect(guard.dirty, ['M src/app.dart', '?? scratch.txt']);
        expect(guard.unpushedCount, 2);
        expect(guard.canDelete, isFalse);
        expect(guard.reasons, ['dirty_tree', 'unpushed_commits']);
      });

      test('a stopped orb is guarded through a throwaway git container '
          'over the workspace volume', () async {
        addOrb(state: 'exited');
        stateDir();
        docker.containerImage = 'orb:abc123';
        final runs = <List<String>>[];
        docker.runRespond = (argv) {
          runs.add(List.of(argv));
          if (argv.contains('--porcelain')) {
            return const DockerCliResult(
              exitCode: 0,
              stdout: ' M file.dart\n',
              stderr: '',
            );
          }
          return const DockerCliResult(exitCode: 0, stdout: '1\n', stderr: '');
        };

        final guard = await service().deleteGuard(orbId);

        expect(guard.evaluable, isTrue);
        expect(guard.dirty, ['M file.dart']);
        expect(guard.unpushedCount, 1);
        expect(guard.reasons, ['dirty_tree', 'unpushed_commits']);
        // The throwaway container: --rm, the image's entrypoint overridden
        // by git, the workspace volume mounted at /ws, the orb's own image.
        expect(runs.firstWhere((a) => a.contains('--porcelain')), [
          'run',
          '--rm',
          '--entrypoint',
          'git',
          '-v',
          'orb-$orbId-workspace:/ws',
          'orb:abc123',
          '-C',
          '/ws',
          'status',
          '--porcelain',
        ]);
        expect(runs.firstWhere((a) => a.contains('rev-list')), [
          'run',
          '--rm',
          '--entrypoint',
          'git',
          '-v',
          'orb-$orbId-workspace:/ws',
          'orb:abc123',
          '-C',
          '/ws',
          'rev-list',
          '--count',
          'HEAD',
          '--not',
          '--remotes',
        ]);
      });

      test('a git failure on the throwaway path is unevaluable', () async {
        addOrb(state: 'exited');
        stateDir();
        docker.containerImage = 'orb:abc123';
        docker.runRespond = (argv) => const DockerCliResult(
          exitCode: 128,
          stdout: '',
          stderr: 'not a git repository',
        );

        final guard = await service().deleteGuard(orbId);

        expect(guard.evaluable, isFalse);
        expect(guard.canDelete, isFalse);
        expect(guard.reasons, ['workspace_missing']);
      });

      test('a git failure on the running path is unevaluable', () async {
        addOrb(port: 49101);
        docker.execRespond = (argv) =>
            const DockerCliResult(exitCode: 1, stdout: '', stderr: 'fatal');

        final guard = await service().deleteGuard(orbId);

        expect(guard.evaluable, isFalse);
        expect(guard.reasons, ['workspace_missing']);
      });

      test('an unreadable unpushed count is unevaluable', () async {
        addOrb(port: 49101);
        docker.execRespond = (argv) {
          if (argv.last == '--porcelain') {
            return const DockerCliResult(exitCode: 0, stdout: '', stderr: '');
          }
          return const DockerCliResult(exitCode: 0, stdout: 'N/A', stderr: '');
        };

        final guard = await service().deleteGuard(orbId);

        expect(guard.evaluable, isFalse);
        expect(guard.reasons, ['workspace_missing']);
      });

      test('a missing workspace volume is unevaluable', () async {
        addOrb(state: 'exited', volumes: false);

        final guard = await service().deleteGuard(orbId);

        expect(guard.evaluable, isFalse);
        expect(guard.reasons, ['workspace_missing']);
        // The guard never reached the throwaway container.
        expect(docker.runArgs.any((a) => a.first == 'run'), isFalse);
      });

      test('an unreadable container image is unevaluable', () async {
        addOrb(state: 'exited');
        stateDir();
        // containerImage unset: the inspect answers the exit-1.

        final guard = await service().deleteGuard(orbId);

        expect(guard.evaluable, isFalse);
        expect(guard.reasons, ['workspace_missing']);
        expect(docker.runArgs.any((a) => a.first == 'run'), isFalse);
      });

      test(
        'an orphan is unevaluable (the removal is the orphan cleanup)',
        () async {
          addOrphan();

          final guard = await service().deleteGuard(orbId);

          expect(guard.evaluable, isFalse);
          expect(guard.reasons, ['workspace_missing']);
          expect(
            docker.runArgs.any((a) => a.first == 'run' || a.first == 'exec'),
            isFalse,
          );
        },
      );

      test('an unknown id throws OrbNotFoundError', () {
        expect(
          () => service().deleteGuard('unknown-id'),
          throwsA(isA<OrbNotFoundError>()),
        );
      });
    });

    // ----------------------------------------------------------------------
    // The protected deletion (spec §2.7)

    group('delete (spec §2.7)', () {
      test(
        'refuses a guarded deletion without force, carrying the guard',
        () async {
          addOrb(port: 49101);
          stateDir();
          docker.execRespond = (argv) {
            if (argv.last == '--porcelain') {
              return const DockerCliResult(
                exitCode: 0,
                stdout: ' M src/app.dart\n',
                stderr: '',
              );
            }
            return const DockerCliResult(
              exitCode: 0,
              stdout: '2\n',
              stderr: '',
            );
          };

          late OrbDeletionRefusedError refused;
          try {
            await service().delete(orbId);
          } on OrbDeletionRefusedError catch (e) {
            refused = e;
          }

          expect(refused.id, orbId);
          expect(refused.guard.reasons, ['dirty_tree', 'unpushed_commits']);
          expect(refused.guard.dirty, ['M src/app.dart']);
          expect(refused.guard.unpushedCount, 2);
          // Nothing was removed.
          expect(argsIndex(docker.runArgs, ['rm', '-f', container]), -1);
          expect(docker.volumeRmNames, isEmpty);
          expect(Directory('${stateRoot.path}/$orbId').existsSync(), isTrue);
        },
      );

      test('force overrides the guard and removes the container, both '
          'volumes, and the state dir', () async {
        addOrb(port: 49101);
        stateDir();
        stagedDir();
        docker.execRespond = (argv) {
          if (argv.last == '--porcelain') {
            return const DockerCliResult(
              exitCode: 0,
              stdout: ' M src/app.dart\n',
              stderr: '',
            );
          }
          return const DockerCliResult(exitCode: 0, stdout: '2\n', stderr: '');
        };

        await service().delete(orbId, force: true);

        expect(
          Directory('${stateRoot.path}/staged-$orbId').existsSync(),
          isFalse,
        );

        expect(
          argsIndex(docker.runArgs, ['rm', '-f', container]),
          isNonNegative,
        );
        expect(docker.volumeRmNames, [
          'orb-$orbId-workspace',
          'orb-$orbId-data',
        ]);
        expect(Directory('${stateRoot.path}/$orbId').existsSync(), isFalse);
        expect(docker.rows, isEmpty);
      });

      test('force delete cleans a root-owned state dir through a throwaway '
          'container over the same mount', () async {
        addOrb(port: 49101);
        // The state dir as the container leaves it: content the host user
        // cannot unlink (a directory the recursive delete cannot enter).
        final dir = Directory('${stateRoot.path}/$orbId')
          ..createSync(recursive: true);
        final sub = Directory('${dir.path}/state')..createSync();
        File('${sub.path}/data').writeAsStringSync('x');
        Process.runSync('chmod', ['555', sub.path]);
        docker.execRespond = (argv) => argv.last == '--porcelain'
            ? const DockerCliResult(
                exitCode: 0,
                stdout: ' M src/app.dart\n',
                stderr: '',
              )
            : const DockerCliResult(exitCode: 0, stdout: '2\n', stderr: '');
        // The container-side clean, as root over the same mount: unlock
        // the simulated root-owned content, then wipe it.
        docker.runRespond = (argv) {
          final mount = argv[argv.indexOf('-v') + 1].split(':').first;
          Process.runSync('chmod', ['-R', 'u+rwx', mount]);
          for (final entry in Directory(mount).listSync()) {
            entry.deleteSync(recursive: true);
          }
          return const DockerCliResult(exitCode: 0, stdout: '', stderr: '');
        };

        await service().delete(orbId, force: true);

        final clean = docker.runArgs.indexWhere(
          (a) =>
              a.length > 1 &&
              a[0] == 'run' &&
              a[1] == '--rm' &&
              a.contains('find /ocb-state -mindepth 1 -delete'),
        );
        expect(clean, isNonNegative);
        expect(
          docker.runArgs[clean].join(' '),
          contains('${stateRoot.path}/$orbId:/ocb-state'),
        );
        expect(dir.existsSync(), isFalse);
      });

      test(
        'volume rm tolerates an already-absent volume (idempotent)',
        () async {
          addOrb(port: 49101);
          stateDir();
          docker.execRespond = (argv) {
            if (argv.last == '--porcelain') {
              return const DockerCliResult(
                exitCode: 0,
                stdout: ' M src/app.dart\n',
                stderr: '',
              );
            }
            return const DockerCliResult(
              exitCode: 0,
              stdout: '2\n',
              stderr: '',
            );
          };
          docker.volumeRm['orb-$orbId-data'] = const DockerCliResult(
            exitCode: 1,
            stdout: '',
            stderr: 'Error: No such volume: orb-$orbId-data',
          );

          await service().delete(orbId, force: true);

          expect(docker.volumeRmNames, [
            'orb-$orbId-workspace',
            'orb-$orbId-data',
          ]);
          expect(Directory('${stateRoot.path}/$orbId').existsSync(), isFalse);
        },
      );

      test('an orphan goes through the explicit orphan cleanup', () async {
        addOrphan();
        stateDir();
        stagedDir();

        await service().delete(orbId);

        expect(docker.volumeRmNames, [
          'orb-$orbId-workspace',
          'orb-$orbId-data',
        ]);
        expect(Directory('${stateRoot.path}/$orbId').existsSync(), isFalse);
        expect(
          Directory('${stateRoot.path}/staged-$orbId').existsSync(),
          isFalse,
        );
      });

      test('an unknown id throws OrbNotFoundError', () {
        expect(
          () => service().delete('unknown-id'),
          throwsA(isA<OrbNotFoundError>()),
        );
      });
    });

    // ----------------------------------------------------------------------
    // The per-orb image update (spec §2.8)

    group('update (spec §2.8)', () {
      test('refuses a broken orb (not_updatable)', () async {
        addOrb(state: 'exited', volumes: false); // broken:workspace

        await expectLater(
          service().update(orbId),
          throwsA(
            isA<OrbRefusalError>().having(
              (e) => e.code,
              'code',
              OrbRefusalError.notUpdatable,
            ),
          ),
        );
        expect(
          docker.runArgs.any(
            (a) => a.first == 'stop' || a.first == 'rm' || a.first == 'create',
          ),
          isFalse,
        );
      });

      test('refuses an orphan (not_updatable)', () async {
        addOrphan();

        await expectLater(
          service().update(orbId),
          throwsA(
            isA<OrbRefusalError>().having(
              (e) => e.code,
              'code',
              OrbRefusalError.notUpdatable,
            ),
          ),
        );
      });

      test('refuses when the state dir is missing (not_updatable)', () async {
        addOrb(port: 49101);
        final orb = _FakeOpencode(); // idle: the busy check passes

        await expectLater(
          service(orbServiceFor: (url, password) => orb).update(orbId),
          throwsA(
            isA<OrbRefusalError>().having(
              (e) => e.code,
              'code',
              OrbRefusalError.notUpdatable,
            ),
          ),
        );
      });

      test('refuses a busy running orb (update_busy)', () async {
        addOrb(port: 49101);
        stateDir();
        final orb = _FakeOpencode()..active.add('sess-1');

        await expectLater(
          service(orbServiceFor: (url, password) => orb).update(orbId),
          throwsA(
            isA<OrbRefusalError>().having(
              (e) => e.code,
              'code',
              OrbRefusalError.updateBusy,
            ),
          ),
        );
        // The refusal is before the recreation: the container is intact.
        expect(
          docker.runArgs.any(
            (a) => a.first == 'stop' || a.first == 'rm' || a.first == 'create',
          ),
          isFalse,
        );
        expect(docker.rows.length, 1);
      });

      test(
        'refuses a running orb with a pending permission (update_busy)',
        () async {
          addOrb(port: 49101);
          stateDir();
          final session = _session('sess-1');
          final orb = _FakeOpencode()
            ..sessions.add(session)
            ..pending['sess-1'] = [
              const PermissionRequest(
                id: 'perm-1',
                action: 'shell',
                resources: ['ls -la'],
              ),
            ];

          await expectLater(
            service(orbServiceFor: (url, password) => orb).update(orbId),
            throwsA(
              isA<OrbRefusalError>().having(
                (e) => e.code,
                'code',
                OrbRefusalError.updateBusy,
              ),
            ),
          );
        },
      );

      test('a running orb with an unreadable password is '
          'sessions-unavailable', () async {
        addOrb(port: 49101);
        stateDir();
        // The list's log read succeeds (the record stays running); the
        // update's password read fails.
        docker.logsSucceeds = 1;

        await expectLater(
          service().update(orbId),
          throwsA(isA<OrbSessionsUnavailableError>()),
        );
      });

      test(
        'a stopped orb is recreated on the current image, not started',
        () async {
          addOrb(state: 'exited');
          stateDir();
          setMarker();
          hostConfig();
          File('${home.path}/.local/share/opencode/auth.json')
            ..createSync(recursive: true)
            ..writeAsStringSync('{}\n');
          checkoutEnv();
          docker.containerEnv = jsonEncode([
            'ORB_ID=$orbId',
            'ORB_REPO=https://github.com/acme/app.git',
            'ORB_GIT_NAME=Host',
            'PATH=/usr/local/bin',
          ]);

          final record = await service(
            checkoutFor: (projectId) async => checkout.path,
          ).update(orbId);

          expect(record.state, 'stopped');
          expect(record.id, orbId);
          expect(record.url, isNull);
          expect(markerPresent(), isTrue); // the marker is untouched.

          // Recreated, not started: one row (the created container), no
          // start, no spawn.
          expect(docker.rows.length, 1);
          expect(docker.rows.single.state, 'created');
          expect(argsIndex(docker.runArgs, ['start', container]), -1);
          expect(docker.spawnArgs, isEmpty);

          // The create: the current shared image (present — no rebuild), the
          // same five mounts, the labels, and the carried ORB_* env (minus
          // ORB_ID, which the create sets explicitly — exactly once).
          final create = docker.runArgs.singleWhere((a) => a.first == 'create');
          expect(create.last, builder.expectedTag);
          for (final mount in [
            '${home.path}/.ssh:/root/.ssh:ro',
            '${home.path}/.config/gh:/root/.config/gh:ro',
            'orb-$orbId-workspace:/workspace',
            'orb-$orbId-data:/var/lib/orb-data',
            '${stateRoot.path}/$orbId:/root/.local',
          ]) {
            expect(create, contains(mount));
          }
          expect(create, contains('ocb.orb=true'));
          expect(create, contains('ocb.name=dev'));
          expect(create, contains('ORB_REPO=https://github.com/acme/app.git'));
          expect(create, contains('ORB_GIT_NAME=Host'));
          expect(create.where((a) => a == 'ORB_ID=$orbId').length, 1);
          expect(create, isNot(contains('PATH=/usr/local/bin')));

          // The wake-style re-injection: the checkout's .env* (the example
          // excluded), the staged config, the auth.
          expect(
            argsIndex(docker.runArgs, [
              'cp',
              '${checkout.path}/.env',
              '$container:/workspace/.env',
            ]),
            isNonNegative,
          );
          expect(
            argsIndex(docker.runArgs, [
              'cp',
              '${checkout.path}/.env.local',
              '$container:/workspace/.env.local',
            ]),
            isNonNegative,
          );
          expect(
            argsIndex(docker.runArgs, [
              'cp',
              '${stateRoot.path}/staged-$orbId/opencode.jsonc',
              '$container:/root/.config/opencode/opencode.jsonc',
            ]),
            isNonNegative,
          );
          expect(
            argsIndex(docker.runArgs, [
              'cp',
              '${home.path}/.local/share/opencode/auth.json',
              '$container:/root/.local/share/opencode/auth.json',
            ]),
            isNonNegative,
          );
        },
      );

      test('a running orb is recreated on the current image and comes back '
          'running', () async {
        final http = await bootServer();
        final port = http.port;
        addOrb(port: 49101);
        stateDir();
        hostConfig();
        File('${home.path}/.local/share/opencode/auth.json')
          ..createSync(recursive: true)
          ..writeAsStringSync('{}\n');
        checkoutEnv();
        docker.containerEnv = jsonEncode([
          'ORB_ID=$orbId',
          'ORB_REPO=https://github.com/acme/app.git',
        ]);
        docker.defaultRestartPort = port;

        final record = await service(
          checkoutFor: (projectId) async => checkout.path,
          orbServiceFor: (url, password) => _FakeOpencode(),
        ).update(orbId);
        await http.close(force: true);

        expect(record.state, 'running');
        expect(record.url, 'http://127.0.0.1:$port');
        expect(record.id, orbId);

        // The old container is gone; the fresh one is running on the new
        // ephemeral port, with a fresh log (no stale password lines).
        expect(docker.rows.length, 1);
        expect(docker.rows.single.state, 'running');
        expect(docker.rows.single.port, port);
        expect(docker.rows.single.log, 'server password $orbPassword\n');

        // The sequence: stop, rm, create (on the current image tag), start.
        final stopIndex = argsIndex(docker.runArgs, ['stop', container]);
        final rmIndex = argsIndex(docker.runArgs, ['rm', container]);
        final create = docker.runArgs.firstWhere((a) => a.first == 'create');
        final createIndex = docker.runArgs.indexWhere(
          (a) => a.first == 'create',
        );
        final startIndex = argsIndex(docker.runArgs, ['start', container]);
        expect(stopIndex, isNonNegative);
        expect(rmIndex, greaterThan(stopIndex));
        expect(createIndex, greaterThan(rmIndex));
        expect(startIndex, greaterThan(createIndex));
        expect(create.last, builder.expectedTag);
        expect(create, contains('ORB_REPO=https://github.com/acme/app.git'));
        expect(create.where((a) => a == 'ORB_ID=$orbId').length, 1);
      });
    });

    // ----------------------------------------------------------------------
    // The docker cp export (spec §3.4)

    group('export (spec §3.4)', () {
      test(
        'a running orb tars in place and is copied out (docker cp)',
        () async {
          addOrb(port: 49101);
          final execs = <List<String>>[];
          docker.execRespond = (argv) {
            execs.add(List.of(argv));
            return const DockerCliResult(exitCode: 0, stdout: '', stderr: '');
          };

          final target = await service(
            checkoutFor: (projectId) async => checkout.path,
          ).export(orbId);

          final name = target.split('/').last;
          expect(target, startsWith('${root.path}/'));
          final pattern = RegExp(
            '^dev-${RegExp.escape(orbId)}-'
            r'\d{8}-\d{6}UTC\.tar\.gz$',
          );
          expect(name, matches(pattern));
          // The tar ran in place, the archive was copied out to the checkout
          // parent, then cleaned up inside the orb (best effort).
          expect(execs, [
            [
              'exec',
              container,
              'tar',
              'czf',
              '/tmp/$name',
              '-C',
              '/workspace',
              '.',
            ],
            ['exec', container, 'rm', '-f', '/tmp/$name'],
          ]);
          expect(
            argsIndex(docker.runArgs, ['cp', '$container:/tmp/$name', target]),
            isNonNegative,
          );
        },
      );

      test('a stopped orb exports through a throwaway tar container into '
          'the bind-mounted out dir', () async {
        addOrb(state: 'exited');
        stateDir();
        docker.containerImage = 'orb:abc123';
        final runs = <List<String>>[];
        docker.runRespond = (argv) {
          runs.add(List.of(argv));
          return const DockerCliResult(exitCode: 0, stdout: '', stderr: '');
        };

        final target = await service(
          checkoutFor: (projectId) async => checkout.path,
        ).export(orbId);

        final name = target.split('/').last;
        expect(target, '${root.path}/$name');
        expect(runs.single, [
          'run',
          '--rm',
          '--entrypoint',
          'tar',
          '-v',
          'orb-$orbId-workspace:/ws',
          '-v',
          '${root.path}:/out',
          'orb:abc123',
          '-czf',
          '/out/$name',
          '-C',
          '/ws',
          '.',
        ]);
      });

      test('an orphan exports on the current shared image', () async {
        addOrphan();
        final runs = <List<String>>[];
        docker.runRespond = (argv) {
          runs.add(List.of(argv));
          return const DockerCliResult(exitCode: 0, stdout: '', stderr: '');
        };

        final target = await service(
          checkoutFor: (projectId) async => checkout.path,
        ).export(orbId);

        final name = target.split('/').last;
        expect(target, '${root.path}/$name');
        expect(runs.single, [
          'run',
          '--rm',
          '--entrypoint',
          'tar',
          '-v',
          'orb-$orbId-workspace:/ws',
          '-v',
          '${root.path}:/out',
          builder.expectedTag,
          '-czf',
          '/out/$name',
          '-C',
          '/ws',
          '.',
        ]);
      });

      test('a missing checkout refuses (missing_checkout)', () async {
        addOrb(port: 49101);

        await expectLater(
          service(checkoutFor: (projectId) async => null).export(orbId),
          throwsA(
            isA<OrbRefusalError>().having(
              (e) => e.code,
              'code',
              OrbRefusalError.missingCheckout,
            ),
          ),
        );
      });

      test('a missing workspace volume refuses (missing_workspace)', () async {
        addOrb(state: 'exited', volumes: false);

        await expectLater(
          service(checkoutFor: (projectId) async => checkout.path)
              .export(orbId),
          throwsA(
            isA<OrbRefusalError>().having(
              (e) => e.code,
              'code',
              OrbRefusalError.missingWorkspace,
            ),
          ),
        );
      });

      test(
        'an unreadable container image refuses (missing_workspace)',
        () async {
          addOrb(state: 'exited');
          stateDir();
          // containerImage unset: the inspect answers the exit-1.

          await expectLater(
            service(checkoutFor: (projectId) async => checkout.path)
                .export(orbId),
            throwsA(
              isA<OrbRefusalError>().having(
                (e) => e.code,
                'code',
                OrbRefusalError.missingWorkspace,
              ),
            ),
          );
        },
      );
    });

    // ----------------------------------------------------------------------
    // The export file name (spec §3.4)

    group('exportFileName (spec §3.4)', () {
      test('is deterministic for a given name, id, and instant', () {
        final now = DateTime.utc(2026, 11, 6, 12, 30, 5);
        expect(
          OrbService.exportFileName('My Repo', 'abcd1234', now),
          'my-repo-abcd1234-20261106-123005UTC.tar.gz',
        );
        expect(
          OrbService.exportFileName('My Repo', 'abcd1234', now),
          OrbService.exportFileName('My Repo', 'abcd1234', now),
        );
      });

      test('sanitizes the name part', () {
        final now = DateTime.utc(2026, 1, 2, 3, 4, 5);
        expect(
          OrbService.exportFileName('My  Repo!!', 'x1', now),
          'my-repo-x1-20260102-030405UTC.tar.gz',
        );
        // The dots are legal file-name characters: they are kept (the
        // leading and trailing runs are trimmed).
        expect(
          OrbService.exportFileName('..tricky..name..', 'x1', now),
          'tricky..name-x1-20260102-030405UTC.tar.gz',
        );
        expect(
          OrbService.exportFileName('!!!', 'x1', now),
          'orb-x1-20260102-030405UTC.tar.gz',
        );
      });
    });
  });
}
