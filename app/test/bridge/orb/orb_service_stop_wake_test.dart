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
    this.bootable = true,
    this.restartPort,
  });

  final String id;
  final String name;
  final String project;
  String state;
  int? port;
  String log;
  final bool volumes;

  /// Whether `docker start` brings the orb up (a password line lands in
  /// the log); `false` scripts a boot that never completes.
  final bool bootable;

  /// The password the boot logs (the move's import picks it up).
  final String password = 'pw-orb-1';

  /// The ephemeral port a `docker start` re-maps to (the wake's port
  /// re-read); `null` keeps the current port (or one is minted).
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
/// `inspect` answers per row, `docker create` registers a new row.
class _FakeDocker {
  final List<_Row> rows = [];
  final List<List<String>> runArgs = [];
  final List<List<String>> spawnArgs = [];
  final List<_FakeProcess> spawned = [];
  final List<_FakeProcess> processes = [];

  /// The ephemeral port a `docker create`d + started orb re-maps to (the
  /// move-to-orb's create path); `null` mints one.
  int? defaultRestartPort;

  /// A hook for the unified event ordering (the tests interleave the CLI
  /// calls and the docker calls into one list).
  void Function(List<String>)? onRun;

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
    final hook = onRun;
    if (hook != null) hook(List.of(argv));
    return _dispatch(List.of(argv));
  }

  DockerCliResult _dispatch(List<String> argv) {
    switch (argv[0]) {
      case 'image':
        // `image inspect <tag>` exit 0: the image is present.
        return const DockerCliResult(exitCode: 0, stdout: '{}', stderr: '');
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
        row.state = 'running';
        row.port = row.restartPort ?? row.port ?? 49321;
        if (row.bootable) {
          row.log += 'server password ${row.password}\n';
        }
        return ok;
      case 'cp':
      case 'create':
        if (argv[0] == 'create') {
          // Register the created container (the move-to-orb's create path):
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

/// The GitRunner seam (the move-to-orb's create probes the remote and the
/// host identity).
class _FakeGit {
  final List<List<String>> args = [];
  final Map<String, GitCliResult> results = {};

  GitRunner get run => (List<String> argv, {String? workingDirectory}) async {
    args.add(List.of(argv));
    return results[argv.join(' ')] ??
        const GitCliResult(exitCode: 0, stdout: '', stderr: '');
  };
}

/// A scripted opencode service (the orb's or the host's).
class _FakeOpencode implements OpencodeService {
  final List<OpencodeSession> sessions = [];
  final Map<String, String> names = {};
  final Set<String> active = {};
  final List<String> createdDirectories = [];
  final List<String> deleted = [];
  OpencodeSession? nextCreated;
  Object? deleteError;

  @override
  Future<List<OpencodeSession>> listSessions() async => List.of(sessions);

  @override
  Future<OpencodeSession> createSessionInDirectory(String directory) async {
    createdDirectories.add(directory);
    return nextCreated!;
  }

  @override
  Future<void> deleteSession(String id) async {
    final error = deleteError;
    if (error != null) throw error;
    deleted.add(id);
    sessions.removeWhere((s) => s.id == id);
  }

  @override
  Future<Map<String, String>> projectNames() async => Map.of(names);

  @override
  Future<Set<String>> activeSessionIds() async => Set.of(active);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A scripted opencode CLI (the export/import of the stop and the moves).
class _Cli {
  _Cli(this.respond);

  final Future<OpencodeCliResult> Function(
    List<String> argv,
    Map<String, String>? env,
  )
  respond;
  final List<List<String>> argvs = [];
  final List<Map<String, String>?> envs = [];

  Future<OpencodeCliResult> run(
    List<String> argv, {
    Map<String, String>? env,
  }) async {
    argvs.add(List.of(argv));
    envs.add(env);
    return respond(argv, env);
  }
}

const _exportOk = OpencodeCliResult(
  exitCode: 0,
  stdout: '{"info":{},"messages":[]}',
  stderr: '',
);
const _importOk = OpencodeCliResult(exitCode: 0, stdout: '', stderr: '');
const _import409 = OpencodeCliResult(
  exitCode: 1,
  stdout: 'Error: 409 Conflict: session already exists',
  stderr: '',
);

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
  group('OrbService stop/wake/move (issue #97)', () {
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
      root = await Directory.systemTemp.createTemp('oc-orb-sw');
      home = Directory('${root.path}/home')..createSync();
      checkout = Directory('${root.path}/checkout')..createSync();
      stateRoot = Directory('${root.path}/state');
      final context = OrbBuildContext(dir: Directory('${root.path}/ctx'));
      await context.materialize();
      git = _FakeGit();
      git.results['remote get-url origin'] = const GitCliResult(
        exitCode: 0,
        stdout: 'https://github.com/acme/app.git\n',
        stderr: '',
      );
      git.results['config user.name'] = const GitCliResult(
        exitCode: 0,
        stdout: 'Lhomme Aymeric\n',
        stderr: '',
      );
      git.results['config user.email'] = const GitCliResult(
        exitCode: 0,
        stdout: 'aymeric@example.com\n',
        stderr: '',
      );
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

    /// A running orb with the descriptor's password in its log (the list
    /// keeps it `running`, not `preparing`).
    _Row addOrb({
      String state = 'running',
      int? port,
      String? log,
      bool volumes = true,
      bool bootable = true,
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
        bootable: bootable,
        restartPort: restartPort,
      );
      docker.rows.add(row);
      return row;
    }

    void stateDir() {
      Directory('${stateRoot.path}/$orbId').createSync(recursive: true);
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
      OpencodeCliRunner? cli,
      Future<String?> Function(String projectId)? checkoutFor,
      OpencodeService? hostSessions,
      OpencodeService Function(String url, String password)? orbServiceFor,
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
        opencodeCli: cli,
        checkoutFor: checkoutFor,
        hostSessions: hostSessions,
        orbServiceFor: orbServiceFor,
        bootTimeout: bootTimeout ?? const Duration(minutes: 10),
        pollInterval: pollInterval ?? const Duration(milliseconds: 5),
      );
    }

    // ----------------------------------------------------------------------
    // stop

    group('stop (spec §2.5)', () {
      test('exports every session, imports each into the checkout, deletes '
          'each from the orb only after its import, stops the container last, '
          'and sets the marker', () async {
        addOrb(port: 49153);
        stateDir();
        final orb = _FakeOpencode();
        orb.sessions.addAll([_session('s-parent'), _session('s-child')]);
        final host = _FakeOpencode();
        final events = <String>[];
        final cli = _Cli((argv, env) async {
          events.add('cli ${argv.join(' ')}');
          return argv[1] == 'export' ? _exportOk : _importOk;
        });
        docker.onRun = (argv) => events.add('docker ${argv.join(' ')}');

        await service(
          cli: cli.run,
          checkoutFor: (projectId) async => checkout.path,
          hostSessions: host,
          orbServiceFor: (url, password) => orb,
        ).stop(orbId);

        // The export carries the orb url and the password overlay; the
        // import is bare (the host service is the CLI's default).
        expect(cli.argvs[0], [
          'session',
          'export',
          's-parent',
          '--server',
          'http://127.0.0.1:49153',
        ]);
        expect(cli.envs[0], {'OPENCODE_PASSWORD': orbPassword});
        expect(cli.argvs[1], [
          'session',
          'export',
          's-child',
          '--server',
          'http://127.0.0.1:49153',
        ]);
        final parentImport = cli.argvs[2];
        final childImport = cli.argvs[3];
        expect(parentImport[0], 'session');
        expect(parentImport[1], 'import');
        expect(parentImport[2], endsWith('ocb-stop-$orbId-s-parent.json'));
        expect(parentImport[2], startsWith(Directory.systemTemp.path));
        expect(parentImport[3], '--directory');
        expect(parentImport[4], checkout.path);
        expect(parentImport, hasLength(5));
        expect(childImport, hasLength(5));
        expect(childImport[2], endsWith('ocb-stop-$orbId-s-child.json'));
        expect(cli.envs[2], isNull);
        expect(cli.envs[3], isNull);

        // Delete-after-import, per session: both deleted from the orb,
        // none on the host.
        expect(orb.deleted, ['s-parent', 's-child']);
        expect(host.deleted, isEmpty);

        // The temp files are cleaned.
        expect(File(parentImport[2]).existsSync(), isFalse);
        expect(File(childImport[2]).existsSync(), isFalse);

        // `docker stop` is the last docker call — after every CLI call.
        final stopIndex = events.indexWhere(
          (e) => e == 'docker stop $container',
        );
        expect(stopIndex, isNonNegative);
        expect(
          events.lastIndexWhere((e) => e.startsWith('cli ')) < stopIndex,
          isTrue,
          reason: 'every CLI call must precede `docker stop`',
        );

        // The marker is set.
        expect(markerPresent(), isTrue);
      });

      test(
        'is a no-op while the orb is not running (no export, no stop)',
        () async {
          addOrb(state: 'exited');
          stateDir();
          setMarker();
          final orb = _FakeOpencode();
          orb.sessions.add(_session('s-1'));
          final cli = _Cli((argv, env) async => _exportOk);

          await service(
            cli: cli.run,
            checkoutFor: (projectId) async => checkout.path,
            hostSessions: _FakeOpencode(),
            orbServiceFor: (url, password) => orb,
          ).stop(orbId);

          expect(cli.argvs, isEmpty);
          expect(docker.runArgs.where((a) => a.first == 'stop'), isEmpty);
          // The pre-existing marker is untouched.
          expect(markerPresent(), isTrue);
        },
      );

      test(
        'a re-issue in the same state is a safe no-op (idempotent)',
        () async {
          addOrb(state: 'exited');
          stateDir();
          setMarker();
          final s = service(
            cli: _Cli((argv, env) async => _exportOk).run,
            checkoutFor: (projectId) async => checkout.path,
            hostSessions: _FakeOpencode(),
          );
          await s.stop(orbId);
          await s.stop(orbId);
          expect(markerPresent(), isTrue);
          expect(docker.runArgs.where((a) => a.first == 'stop'), isEmpty);
        },
      );

      test('refuses without the host CLI: nothing is touched', () async {
        addOrb(port: 49153);
        stateDir();
        final orb = _FakeOpencode();
        orb.sessions.add(_session('s-1'));

        await expectLater(
          service(
            checkoutFor: (projectId) async => checkout.path,
            hostSessions: _FakeOpencode(),
            orbServiceFor: (url, password) => orb,
          ).stop(orbId),
          throwsA(isA<OrbSessionsUnavailableError>()),
        );
        expect(orb.deleted, isEmpty);
        expect(docker.runArgs.where((a) => a.first == 'stop'), isEmpty);
        expect(markerPresent(), isFalse);
      });

      test('refuses without the host sessions service', () async {
        addOrb(port: 49153);
        stateDir();
        await expectLater(
          service(
            cli: _Cli((argv, env) async => _exportOk).run,
            checkoutFor: (projectId) async => checkout.path,
            orbServiceFor: (url, password) => _FakeOpencode(),
          ).stop(orbId),
          throwsA(isA<OrbSessionsUnavailableError>()),
        );
        expect(docker.runArgs.where((a) => a.first == 'stop'), isEmpty);
        expect(markerPresent(), isFalse);
      });

      test('refuses when the project checkout is unresolvable, before '
          'any export', () async {
        addOrb(port: 49153);
        stateDir();
        final cli = _Cli((argv, env) async => _exportOk);
        await expectLater(
          service(
            cli: cli.run,
            checkoutFor: (projectId) async => null,
            hostSessions: _FakeOpencode(),
          ).stop(orbId),
          throwsA(isA<OrbSessionsUnavailableError>()),
        );
        expect(cli.argvs, isEmpty);
        expect(docker.runArgs.where((a) => a.first == 'stop'), isEmpty);
        expect(markerPresent(), isFalse);
      });

      test('a failed export is an OrbSessionMoveError: no delete, no stop, '
          'no marker, the temp file is cleaned', () async {
        addOrb(port: 49153);
        stateDir();
        final orb = _FakeOpencode();
        orb.sessions.addAll([_session('s-parent'), _session('s-child')]);
        final cli = _Cli((argv, env) async {
          if (argv[1] == 'export' && argv[2] == 's-parent') {
            return const OpencodeCliResult(
              exitCode: 1,
              stdout: '',
              stderr: 'export boom',
            );
          }
          return argv[1] == 'export' ? _exportOk : _importOk;
        });

        await expectLater(
          service(
            cli: cli.run,
            checkoutFor: (projectId) async => checkout.path,
            hostSessions: _FakeOpencode(),
            orbServiceFor: (url, password) => orb,
          ).stop(orbId),
          throwsA(
            isA<OrbSessionMoveError>()
                .having((e) => e.session, 'session', 's-parent')
                .having((e) => e.detail, 'detail', 'export boom'),
          ),
        );
        expect(orb.deleted, isEmpty);
        expect(docker.runArgs.where((a) => a.first == 'stop'), isEmpty);
        expect(markerPresent(), isFalse);
        final leftovers = Directory.systemTemp
            .listSync()
            .whereType<File>()
            .where((f) => f.path.contains('ocb-stop-$orbId'));
        expect(leftovers, isEmpty);
      });

      test('a failed (non-409) import stops before the delete: no stop, '
          'no marker', () async {
        addOrb(port: 49153);
        stateDir();
        final orb = _FakeOpencode();
        orb.sessions.addAll([_session('s-parent'), _session('s-child')]);
        final cli = _Cli((argv, env) async {
          if (argv[1] == 'import') {
            return const OpencodeCliResult(
              exitCode: 1,
              stdout: '',
              stderr: 'import boom',
            );
          }
          return _exportOk;
        });

        await expectLater(
          service(
            cli: cli.run,
            checkoutFor: (projectId) async => checkout.path,
            hostSessions: _FakeOpencode(),
            orbServiceFor: (url, password) => orb,
          ).stop(orbId),
          throwsA(
            isA<OrbSessionMoveError>().having(
              (e) => e.session,
              'session',
              's-parent',
            ),
          ),
        );
        expect(orb.deleted, isEmpty);
        expect(docker.runArgs.where((a) => a.first == 'stop'), isEmpty);
        expect(markerPresent(), isFalse);
      });

      test('a 409 import is idempotent success: the session is deleted and '
          'the stop completes', () async {
        addOrb(port: 49153);
        stateDir();
        final orb = _FakeOpencode();
        orb.sessions.add(_session('s-1'));
        final cli = _Cli((argv, env) async {
          return argv[1] == 'export' ? _exportOk : _import409;
        });

        await service(
          cli: cli.run,
          checkoutFor: (projectId) async => checkout.path,
          hostSessions: _FakeOpencode(),
          orbServiceFor: (url, password) => orb,
        ).stop(orbId);

        expect(orb.deleted, ['s-1']);
        expect(docker.runArgs, contains(equals(['stop', container])));
        expect(markerPresent(), isTrue);
      });

      test('a failed deletion from the orb is an OrbSessionMoveError: no '
          'stop, no marker', () async {
        addOrb(port: 49153);
        stateDir();
        final orb = _FakeOpencode();
        orb.sessions.add(_session('s-1'));
        orb.deleteError = StateError('delete boom');

        await expectLater(
          service(
            cli: _Cli((argv, env) async {
              return argv[1] == 'export' ? _exportOk : _importOk;
            }).run,
            checkoutFor: (projectId) async => checkout.path,
            hostSessions: _FakeOpencode(),
            orbServiceFor: (url, password) => orb,
          ).stop(orbId),
          throwsA(
            isA<OrbSessionMoveError>().having(
              (e) => e.detail,
              'detail',
              contains('delete boom'),
            ),
          ),
        );
        expect(docker.runArgs.where((a) => a.first == 'stop'), isEmpty);
        expect(markerPresent(), isFalse);
      });

      test('an orb with no sessions is still stopped and marked', () async {
        addOrb(port: 49153);
        stateDir();
        final cli = _Cli((argv, env) async => _exportOk);

        await service(
          cli: cli.run,
          checkoutFor: (projectId) async => checkout.path,
          hostSessions: _FakeOpencode(),
          orbServiceFor: (url, password) => _FakeOpencode(),
        ).stop(orbId);

        expect(cli.argvs, isEmpty);
        expect(docker.runArgs, contains(equals(['stop', container])));
        expect(markerPresent(), isTrue);
      });

      test('an unknown id is an OrbNotFoundError', () async {
        addOrb(port: 49153);
        await expectLater(
          service(
            cli: _Cli((argv, env) async => _exportOk).run,
            checkoutFor: (projectId) async => checkout.path,
            hostSessions: _FakeOpencode(),
          ).stop('ffffffff'),
          throwsA(isA<OrbNotFoundError>()),
        );
      });
    });

    // ----------------------------------------------------------------------
    // wake

    group('wake (spec §2.4)', () {
      test('re-injects the .env*, re-copies the config+auth, starts, waits '
          'for the boot (port + password re-read), removes the marker only on '
          'success, and returns the running record', () async {
        final http = await bootServer();
        final port = http.port;
        addOrb(state: 'exited', restartPort: port);
        stateDir();
        setMarker();
        hostConfig();
        File('${home.path}/.local/share/opencode/auth.json')
          ..createSync(recursive: true)
          ..writeAsStringSync('{}\n');
        checkoutEnv();

        final record = await service(
          checkoutFor: (projectId) async => checkout.path,
        ).wake(orbId);
        await http.close(force: true);

        expect(record.state, 'running');
        expect(record.url, 'http://127.0.0.1:$port');
        expect(record.id, orbId);
        expect(markerPresent(), isFalse);

        // The .env* re-injection: .env + .env.*, never *.example —
        // before the start.
        final copies = docker.runArgs.where((a) => a.first == 'cp').toList();
        expect(
          copies,
          containsAll([
            ['cp', '${checkout.path}/.env', '$container:/workspace/.env'],
            [
              'cp',
              '${checkout.path}/.env.local',
              '$container:/workspace/.env.local',
            ],
          ]),
        );
        expect(copies.where((a) => a.last.contains('.example')), isEmpty);

        // The config re-copy: the staged entries (the host service
        // descriptor is never copied), the auth re-copy.
        final staged = '${stateRoot.path}/staged-$orbId';
        expect(File('$staged/opencode.jsonc').existsSync(), isTrue);
        expect(
          copies,
          contains(
            equals([
              'cp',
              '$staged/opencode.jsonc',
              '$container:/root/.config/opencode/opencode.jsonc',
            ]),
          ),
        );
        expect(copies.where((a) => a.last.contains('service.json')), isEmpty);
        expect(
          copies,
          contains(
            equals([
              'cp',
              '${home.path}/.local/share/opencode/auth.json',
              '$container:/root/.local/share/opencode/auth.json',
            ]),
          ),
        );

        // Every copy precedes the start; the start precedes the follow.
        final startIndex = argsIndex(docker.runArgs, ['start', container]);
        expect(startIndex, isNonNegative);
        expect(
          copies.every((c) => argsIndex(docker.runArgs, c) < startIndex),
          isTrue,
        );
        expect(docker.spawnArgs, [
          ['logs', '--follow', container],
        ]);
        expect(docker.spawned, hasLength(1));
        expect(docker.spawned[0].killed, isTrue);
      });

      test(
        'is a no-op while the orb is running (no start, no marker work)',
        () async {
          addOrb(port: 49153);
          stateDir();

          final record = await service().wake(orbId);

          expect(record.state, 'running');
          expect(record.url, 'http://127.0.0.1:49153');
          expect(docker.runArgs.where((a) => a.first == 'start'), isEmpty);
          expect(markerPresent(), isFalse);
        },
      );

      test('refuses a broken orb with notWakeable', () async {
        addOrb(state: 'exited', volumes: false);
        stateDir();

        await expectLater(
          service().wake(orbId),
          throwsA(
            isA<OrbRefusalError>().having(
              (e) => e.code,
              'code',
              OrbRefusalError.notWakeable,
            ),
          ),
        );
        expect(docker.runArgs.where((a) => a.first == 'start'), isEmpty);
      });

      test('does not remove the marker when the boot fails', () async {
        addOrb(state: 'exited', bootable: false);
        stateDir();
        setMarker();

        await expectLater(
          service(bootTimeout: const Duration(milliseconds: 300)).wake(orbId),
          throwsA(isA<OrbBootError>()),
        );
        expect(markerPresent(), isTrue);
      });

      test('skips the .env* re-injection without a checkout resolver '
          '(non-fatal) and still boots', () async {
        final http = await bootServer();
        final row = addOrb(state: 'exited', restartPort: http.port);
        row.port = null;
        stateDir();
        setMarker();
        hostConfig();
        checkoutEnv();

        final record = await service().wake(orbId);
        await http.close(force: true);

        expect(record.state, 'running');
        expect(
          docker.runArgs.where(
            (a) => a.first == 'cp' && a[1].startsWith(checkout.path),
          ),
          isEmpty,
        );
        expect(markerPresent(), isFalse);
      });

      test('an unknown id is an OrbNotFoundError', () async {
        await expectLater(
          service().wake('ffffffff'),
          throwsA(isA<OrbNotFoundError>()),
        );
      });
    });

    // ----------------------------------------------------------------------
    // moveSession

    group('moveSession (the generic primitive, spec §2.5)', () {
      test('host→orb: exports bare, imports with the orb server + password, '
          'deletes from the host only after the import', () async {
        final host = _FakeOpencode()..sessions.add(_session('s-1'));
        final orb = _FakeOpencode();
        final cli = _Cli((argv, env) async {
          return argv[1] == 'export' ? _exportOk : _importOk;
        });

        await service(
          cli: cli.run,
          hostSessions: host,
          orbServiceFor: (url, password) => orb,
        ).moveSession(
          session: 's-1',
          source: OpencodeEndpoint(service: host),
          target: OpencodeEndpoint(
            service: orb,
            server: 'http://127.0.0.1:49153',
            password: orbPassword,
          ),
          directory: '/workspace',
        );

        expect(cli.argvs[0], ['session', 'export', 's-1']);
        expect(cli.envs[0], isNull);
        expect(cli.argvs[1], [
          'session',
          'import',
          cli.argvs[1][2],
          '--directory',
          '/workspace',
          '--server',
          'http://127.0.0.1:49153',
        ]);
        expect(cli.argvs[1][2], contains('ocb-move-s-1-'));
        expect(cli.argvs[1][2], endsWith('.json'));
        expect(cli.argvs[1][2], startsWith(Directory.systemTemp.path));
        expect(cli.envs[1], {'OPENCODE_PASSWORD': orbPassword});
        expect(host.deleted, ['s-1']);
        expect(orb.deleted, isEmpty);
        expect(File(cli.argvs[1][2]).existsSync(), isFalse);
      });

      test(
        'orb→host: exports with the orb server + password, imports bare',
        () async {
          final orb = _FakeOpencode()..sessions.add(_session('s-1'));
          final host = _FakeOpencode();
          final cli = _Cli((argv, env) async {
            return argv[1] == 'export' ? _exportOk : _importOk;
          });

          await service(
            cli: cli.run,
            hostSessions: host,
            orbServiceFor: (url, password) => orb,
          ).moveSession(
            session: 's-1',
            source: OpencodeEndpoint(
              service: orb,
              server: 'http://127.0.0.1:49153',
              password: orbPassword,
            ),
            target: OpencodeEndpoint(service: host),
            directory: checkout.path,
          );

          expect(cli.argvs[0], [
            'session',
            'export',
            's-1',
            '--server',
            'http://127.0.0.1:49153',
          ]);
          expect(cli.envs[0], {'OPENCODE_PASSWORD': orbPassword});
          expect(cli.argvs[1], [
            'session',
            'import',
            cli.argvs[1][2],
            '--directory',
            checkout.path,
          ]);
          expect(cli.envs[1], isNull);
          expect(orb.deleted, ['s-1']);
          expect(host.deleted, isEmpty);
        },
      );

      test(
        'a 409 import is idempotent success: the source still deletes',
        () async {
          final host = _FakeOpencode()..sessions.add(_session('s-1'));
          final cli = _Cli((argv, env) async {
            return argv[1] == 'export' ? _exportOk : _import409;
          });

          await service(
            cli: cli.run,
            hostSessions: host,
            orbServiceFor: (url, password) => _FakeOpencode(),
          ).moveSession(
            session: 's-1',
            source: OpencodeEndpoint(service: host),
            target: OpencodeEndpoint(
              service: _FakeOpencode(),
              server: 'http://127.0.0.1:49153',
              password: orbPassword,
            ),
            directory: '/workspace',
          );

          expect(host.deleted, ['s-1']);
        },
      );

      test('a failed export is an OrbSessionMoveError: no delete', () async {
        final host = _FakeOpencode()..sessions.add(_session('s-1'));
        final cli = _Cli((argv, env) async {
          if (argv[1] == 'export') {
            return const OpencodeCliResult(
              exitCode: 1,
              stdout: '',
              stderr: 'export boom',
            );
          }
          return _importOk;
        });

        await expectLater(
          service(cli: cli.run, hostSessions: host).moveSession(
            session: 's-1',
            source: OpencodeEndpoint(service: host),
            target: OpencodeEndpoint(
              service: _FakeOpencode(),
              server: 'http://127.0.0.1:49153',
              password: orbPassword,
            ),
            directory: '/workspace',
          ),
          throwsA(
            isA<OrbSessionMoveError>().having(
              (e) => e.detail,
              'detail',
              'export boom',
            ),
          ),
        );
        expect(host.deleted, isEmpty);
      });

      test(
        'a failed (non-409) import is an OrbSessionMoveError: no delete',
        () async {
          final host = _FakeOpencode()..sessions.add(_session('s-1'));
          final cli = _Cli((argv, env) async {
            if (argv[1] == 'import') {
              return const OpencodeCliResult(
                exitCode: 1,
                stdout: '',
                stderr: 'import boom',
              );
            }
            return _exportOk;
          });

          await expectLater(
            service(cli: cli.run, hostSessions: host).moveSession(
              session: 's-1',
              source: OpencodeEndpoint(service: host),
              target: OpencodeEndpoint(
                service: _FakeOpencode(),
                server: 'http://127.0.0.1:49153',
                password: orbPassword,
              ),
              directory: '/workspace',
            ),
            throwsA(
              isA<OrbSessionMoveError>().having(
                (e) => e.detail,
                'detail',
                'import boom',
              ),
            ),
          );
          expect(host.deleted, isEmpty);
        },
      );

      test(
        'refuses without the host CLI: OrbSessionsUnavailableError',
        () async {
          await expectLater(
            service(hostSessions: _FakeOpencode()).moveSession(
              session: 's-1',
              source: OpencodeEndpoint(service: _FakeOpencode()),
              target: OpencodeEndpoint(
                service: _FakeOpencode(),
                server: 'http://127.0.0.1:49153',
                password: orbPassword,
              ),
              directory: '/workspace',
            ),
            throwsA(isA<OrbSessionsUnavailableError>()),
          );
        },
      );
    });

    // ----------------------------------------------------------------------
    // moveSessionToOrb

    group('moveSessionToOrb (host→orb, one action, spec §2.5)', () {
      test('moves a host session onto a running orb of the same project '
          '(no docker start)', () async {
        addOrb(port: 49153, name: 'dev');
        final host = _FakeOpencode()..sessions.add(_session('s-1'));
        final cli = _Cli((argv, env) async {
          return argv[1] == 'export' ? _exportOk : _importOk;
        });

        await service(
          cli: cli.run,
          hostSessions: host,
          orbServiceFor: (url, password) => _FakeOpencode(),
        ).moveSessionToOrb(session: 's-1', orbName: 'dev');

        expect(cli.argvs[0], ['session', 'export', 's-1']);
        expect(cli.argvs[1], [
          'session',
          'import',
          cli.argvs[1][2],
          '--directory',
          '/workspace',
          '--server',
          'http://127.0.0.1:49153',
        ]);
        expect(cli.envs[1], {'OPENCODE_PASSWORD': orbPassword});
        expect(host.deleted, ['s-1']);
        expect(docker.runArgs.where((a) => a.first == 'start'), isEmpty);
      });

      test(
        'wakes a stopped orb before moving (the marker comes off)',
        () async {
          final http = await bootServer();
          final port = http.port;
          addOrb(state: 'exited', restartPort: port, name: 'dev');
          stateDir();
          setMarker();
          hostConfig();
          final host = _FakeOpencode()..sessions.add(_session('s-1'));
          final cli = _Cli((argv, env) async {
            return argv[1] == 'export' ? _exportOk : _importOk;
          });

          await service(
            cli: cli.run,
            hostSessions: host,
            checkoutFor: (projectId) async => checkout.path,
            orbServiceFor: (url, password) => _FakeOpencode(),
          ).moveSessionToOrb(session: 's-1', orbName: 'dev');
          await http.close(force: true);

          expect(docker.runArgs, contains(equals(['start', container])));
          expect(markerPresent(), isFalse);
          expect(host.deleted, ['s-1']);
          // The import hit the woken orb's re-mapped port.
          expect(cli.argvs[1], contains('http://127.0.0.1:$port'));
        },
      );

      test(
        'creates the orb when it is absent (the full §2.3 sequence)',
        () async {
          final http = await bootServer();
          final port = http.port;
          docker.defaultRestartPort = port;
          hostConfig();
          checkoutEnv();
          final host = _FakeOpencode()..sessions.add(_session('s-1'));
          final cli = _Cli((argv, env) async {
            return argv[1] == 'export' ? _exportOk : _importOk;
          });

          await service(
            cli: cli.run,
            hostSessions: host,
            checkoutFor: (projectId) async => checkout.path,
            orbServiceFor: (url, password) => _FakeOpencode(),
          ).moveSessionToOrb(session: 's-1', orbName: 'fresh');
          await http.close(force: true);

          // The create ran (the git remote probe, the labeled container,
          // the env injection, the start) and the move landed on it.
          expect(git.args, isNotEmpty);
          expect(
            docker.runArgs.any((a) => a.first == 'create' && a.contains('-l')),
            isTrue,
          );
          expect(
            docker.runArgs,
            contains(equals(['start', 'orb-${docker.rows.single.id}'])),
          );
          expect(host.deleted, ['s-1']);
          expect(cli.argvs[1], contains('http://127.0.0.1:$port'));
          expect(cli.argvs[1], containsAll(['--directory', '/workspace']));
        },
      );

      test('refuses when the session is not on the host service', () async {
        addOrb(port: 49153, name: 'dev');
        await expectLater(
          service(
            cli: _Cli((argv, env) async => _exportOk).run,
            hostSessions: _FakeOpencode(),
          ).moveSessionToOrb(session: 's-missing', orbName: 'dev'),
          throwsA(
            isA<OrbSessionMoveError>().having(
              (e) => e.session,
              'session',
              's-missing',
            ),
          ),
        );
      });

      test('refuses missingCheckout when the create cannot resolve the '
          'checkout', () async {
        final host = _FakeOpencode()..sessions.add(_session('s-1'));
        await expectLater(
          service(
            cli: _Cli((argv, env) async => _exportOk).run,
            hostSessions: host,
            checkoutFor: (projectId) async => null,
          ).moveSessionToOrb(session: 's-1', orbName: 'fresh'),
          throwsA(
            isA<OrbRefusalError>().having(
              (e) => e.code,
              'code',
              OrbRefusalError.missingCheckout,
            ),
          ),
        );
      });

      test('refuses a broken orb with notWakeable', () async {
        addOrb(state: 'exited', volumes: false, name: 'dev');
        stateDir();
        final host = _FakeOpencode()..sessions.add(_session('s-1'));
        await expectLater(
          service(
            cli: _Cli((argv, env) async => _exportOk).run,
            hostSessions: host,
          ).moveSessionToOrb(session: 's-1', orbName: 'dev'),
          throwsA(
            isA<OrbRefusalError>().having(
              (e) => e.code,
              'code',
              OrbRefusalError.notWakeable,
            ),
          ),
        );
      });

      test('refuses without the host sessions service', () async {
        await expectLater(
          service(cli: _Cli((argv, env) async => _exportOk).run)
              .moveSessionToOrb(session: 's-1', orbName: 'dev'),
          throwsA(isA<OrbSessionsUnavailableError>()),
        );
      });
    });

    // ----------------------------------------------------------------------
    // createSessionOnOrb

    group('createSessionOnOrb (spec §9.5)', () {
      test('creates in the orb workspace and shapes the row with the orb '
          'stamped', () async {
        addOrb(port: 49153);
        final orb = _FakeOpencode()
          ..nextCreated = OpencodeSession(
            id: 's-new',
            title: 'New session',
            projectId: 'proj-orb',
            created: 1700000000001,
            location: '/workspace',
          )
          ..names['proj-orb'] = 'workspace'
          ..active.add('s-new');

        final row = await service(orbServiceFor: (url, password) => orb)
            .createSessionOnOrb(orbId);

        expect(orb.createdDirectories, ['/workspace']);
        expect(row.id, 's-new');
        expect(row.title, 'New session');
        expect(row.project.id, 'proj-orb');
        expect(row.project.name, 'workspace');
        expect(row.created, 1700000000001);
        expect(row.location, '/workspace');
        expect(row.active, isTrue);
        expect(row.orb, orbId);
      });

      test('refuses a stopped orb with notRunning', () async {
        addOrb(state: 'exited');
        stateDir();
        await expectLater(
          service().createSessionOnOrb(orbId),
          throwsA(
            isA<OrbRefusalError>().having(
              (e) => e.code,
              'code',
              OrbRefusalError.notRunning,
            ),
          ),
        );
      });

      test('an unknown id is an OrbNotFoundError', () async {
        await expectLater(
          service().createSessionOnOrb('ffffffff'),
          throwsA(isA<OrbNotFoundError>()),
        );
      });
    });

    // ----------------------------------------------------------------------
    // isStopped

    group('isStopped (the ocb.stopped marker)', () {
      test('reflects the marker file', () async {
        stateDir();
        final s = service();
        expect(s.isStopped(orbId), isFalse);
        setMarker();
        expect(s.isStopped(orbId), isTrue);
        File('${stateRoot.path}/$orbId/stopped').deleteSync();
        expect(s.isStopped(orbId), isFalse);
      });
    });
  });
}
