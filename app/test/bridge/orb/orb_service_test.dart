import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/docker/docker_backend.dart';
import 'package:opencodebridge/bridge/orb/orb_build_context.dart';
import 'package:opencodebridge/bridge/orb/orb_image_builder.dart';
import 'package:opencodebridge/bridge/orb/orb_service.dart';
import 'package:opencodebridge/model/orb.dart';

/// A scripted docker CLI child.
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

/// The DockerRunner/DockerSpawner seam, scripted by the argv's first words
/// (the create flow and the boot loop interleave their commands).
class _FakeDocker {
  final List<List<String>> runArgs = [];
  final List<List<String>> spawnArgs = [];
  final List<_FakeProcess> spawned = [];

  /// The next children the spawner returns, in order.
  final List<_FakeProcess> processes = [];

  /// The error the next spawn throws (`null` for none).
  Object? spawnError;

  DockerCliResult psResult = const DockerCliResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );

  DockerCliResult stateResult = const DockerCliResult(
    exitCode: 0,
    stdout: 'running\n',
    stderr: '',
  );

  /// The `docker logs <container>` full output (the boot wait's password
  /// source and the failure tail).
  String logs = '';

  /// Per-container full logs (the list's preparing derivation): the
  /// container name is the key; [logs] is the fallback when the map has no
  /// entry for the container.
  final Map<String, String> containerLogs = {};

  /// The `{{json .NetworkSettings.Ports}}` inspect output (one line per
  /// container in the multi-arg form).
  String ports = 'null';

  DockerCliResult containerLabelsResult = const DockerCliResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );

  DockerCliResult volumeLsResult = const DockerCliResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );

  DockerCliResult volumeInspectResult = const DockerCliResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );

  /// The `volume rm <name>` result (the orphan cleanup).
  DockerCliResult volumeRmResult = const DockerCliResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );

  /// The names passed to `volume rm`, in order (the orphan cleanup).
  final List<String> volumeRmNames = [];

  /// The `docker inspect orb-<id> --format {{.Id}}` result (the orphan
  /// cleanup's container probe).
  DockerCliResult inspectIdResult = const DockerCliResult(
    exitCode: 1,
    stdout: '',
    stderr: 'no such container',
  );

  (DockerRunner, DockerSpawner) bind() => (_run, _spawn);

  Future<DockerCliResult> _run(
    List<String> argv, {
    String? workingDirectory,
  }) async {
    runArgs.add(List.of(argv));
    return _dispatch(List.of(argv));
  }

  DockerCliResult _dispatch(List<String> argv) {
    final command = argv[0];
    if (command == 'image') {
      return const DockerCliResult(exitCode: 0, stdout: '[]', stderr: '');
    }
    if (command == 'ps') return psResult;
    if (command == 'volume') {
      if (argv[1] == 'create') {
        return const DockerCliResult(exitCode: 0, stdout: '', stderr: '');
      }
      if (argv[1] == 'ls') return volumeLsResult;
      if (argv[1] == 'inspect') return volumeInspectResult;
      if (argv[1] == 'rm') {
        volumeRmNames.add(argv[2]);
        return volumeRmResult;
      }
    }
    if (command == 'create' || command == 'cp' || command == 'start') {
      return const DockerCliResult(exitCode: 0, stdout: '', stderr: '');
    }
    if (command == 'logs') {
      // `docker logs <container>` (the full log): per-container when the
      // test scripted one, the shared [logs] otherwise.
      final container = argv[argv.length - 1];
      return DockerCliResult(
        exitCode: 0,
        stdout: containerLogs[container] ?? logs,
        stderr: '',
      );
    }
    if (command == 'inspect') {
      final format = argv[argv.indexOf('--format') + 1];
      if (format == '{{.State.Status}}') return stateResult;
      if (format == '{{.Id}}') return inspectIdResult;
      if (format == '{{json .NetworkSettings.Ports}}') {
        return DockerCliResult(exitCode: 0, stdout: ports, stderr: '');
      }
      if (format == '{{json .Config.Labels}}') return containerLabelsResult;
    }
    throw StateError('unexpected docker argv: $argv');
  }

  Future<DockerProcess> _spawn(
    List<String> argv, {
    String? workingDirectory,
  }) async {
    spawnArgs.add(List.of(argv));
    final error = spawnError;
    if (error != null) {
      spawnError = null;
      throw error;
    }
    final process = processes.isNotEmpty
        ? processes.removeAt(0)
        : _FakeProcess();
    spawned.add(process);
    return process.toProcess();
  }
}

/// The GitRunner seam, scripted by the argv (the remote probe and the
/// identity read).
class _FakeGit {
  final List<List<String>> args = [];
  final Map<String, GitCliResult> results = {};

  GitRunner get run => (List<String> argv, {String? workingDirectory}) async {
    args.add(List.of(argv));
    return results[argv.join(' ')] ??
        const GitCliResult(exitCode: 0, stdout: '', stderr: '');
  };
}

/// The GhRunner seam, scripted by the argv (the PR-state read, issue #96).
class _FakeGh {
  final List<List<String>> args = [];
  final Map<String, GitCliResult> results = {};

  GhRunner get run => (List<String> argv) async {
    args.add(List.of(argv));
    return results[argv.join(' ')] ??
        const GitCliResult(exitCode: 0, stdout: '', stderr: '');
  };
}

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for the condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  group('OrbService (issue #93)', () {
    late Directory root;
    late Directory home;
    late Directory checkout;
    late Directory stateRoot;
    late OrbBuildContext context;
    late OrbImageBuilder builder;
    late _FakeDocker docker;
    late _FakeGit git;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('oc-orb-service');
      home = Directory('${root.path}/home')..createSync();
      checkout = Directory('${root.path}/checkout')..createSync();
      stateRoot = Directory('${root.path}/state');
      context = OrbBuildContext(dir: Directory('${root.path}/ctx'));
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
      final (run, spawn) = docker.bind();
      builder = OrbImageBuilder(context: context, run: run, spawn: spawn);
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    OrbService service({
      Duration? bootTimeout,
      Duration? pollInterval,
      void Function(String)? emit,
      GhRunner? gh,
      Future<String?> Function(String projectId)? repoFor,
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
        emit: emit,
        hostIp: () async => '10.1.2.3',
        gh: gh,
        repoFor: repoFor,
        bootTimeout: bootTimeout ?? const Duration(minutes: 10),
        pollInterval: pollInterval ?? const Duration(milliseconds: 5),
      );
    }

    void hostConfig({bool withPlugins = true}) {
      final config = Directory('${home.path}/.config/opencode');
      config.createSync(recursive: true);
      File('${config.path}/opencode.jsonc')
          .writeAsStringSync('{\n  "model": "test"\n}\n');
      File('${config.path}/service.json').writeAsStringSync('{}\n');
      if (withPlugins) {
        Directory('${config.path}/plugins').createSync();
        File('${config.path}/plugins/p.txt').writeAsStringSync('plugin\n');
      }
    }

    void checkoutEnv() {
      File('${checkout.path}/.env').writeAsStringSync('A=1\n');
      File('${checkout.path}/.env.local').writeAsStringSync('B=2\n');
      File('${checkout.path}/.env.example').writeAsStringSync('EXAMPLE\n');
    }

    test(
      'create runs the full bridge-owned sequence and returns the descriptor',
      () async {
        checkoutEnv();
        hostConfig();

        // The real local server the descriptor verification hits (the fake
        // inspect scripts the ephemeral host port at it).
        const password = 'pw-secret-123';
        final http = await HttpServer.bind('127.0.0.1', 0);
        var requests = 0;
        http.listen((request) {
          requests++;
          final auth = request.headers.value('authorization') ?? '';
          request.response.statusCode =
              auth ==
                  'Basic ${base64.encode(utf8.encode('opencode:$password'))}'
              ? 200
              : 401;
          unawaited(request.response.close());
        });
        final port = http.port;
        docker.ports =
            '{"4096/tcp":[{"HostIp":"127.0.0.1","HostPort":"$port"}]}';
        docker.logs = 'server password $password\nlistening on 0.0.0.0:4096\n';

        final record = await service().create(
          project: 'proj-1',
          name: 'dev',
          checkout: checkout.path,
        );
        await http.close(force: true);

        // The descriptor verified exactly once, with the Basic auth.
        expect(requests, 1);
        expect(record.url, 'http://127.0.0.1:$port');
        expect(record.state, 'running');

        final create = docker.runArgs.firstWhere((a) => a.first == 'create');
        final container = create[2];
        final id = container.substring('orb-'.length);
        final createdIndex = create.indexWhere(
          (element) => element.startsWith('ocb.created='),
        );
        expect(createdIndex, isNonNegative);
        final created = create[createdIndex];
        final actualCreate = List.of(create)..[createdIndex] = 'ocb.created=*';
        expect(actualCreate, [
          'create',
          '--name',
          container,
          '-p',
          '127.0.0.1:0:${OrbService.inContainerPort}',
          '--add-host',
          'host.docker.internal:10.1.2.3',
          '-v',
          '${home.path}/.ssh:/root/.ssh:ro',
          '-v',
          '${home.path}/.config/gh:/root/.config/gh:ro',
          '-v',
          'orb-$id-workspace:/workspace',
          '-v',
          'orb-$id-data:/var/lib/orb-data',
          '-v',
          '${stateRoot.path}/$id:/root/.local',
          '-e',
          'ORB_ID=$id',
          '-e',
          'ORB_REPO_URL=https://github.com/acme/app.git',
          '-e',
          'ORB_GIT_NAME=Lhomme Aymeric',
          '-e',
          'ORB_GIT_EMAIL=aymeric@example.com',
          '-l',
          'ocb.orb=true',
          '-l',
          'ocb.id=$id',
          '-l',
          'ocb.name=dev',
          '-l',
          'ocb.project=proj-1',
          '-l',
          'ocb.branch=orb/$id',
          '-l',
          'ocb.created=*',
          builder.expectedTag,
        ]);

        // The state dir exists (the bind mount) and the volumes are labeled.
        expect(Directory('${stateRoot.path}/$id').existsSync(), isTrue);
        for (final suffix in const ['workspace', 'data']) {
          final volume = docker.runArgs.firstWhere(
            (a) => a.first == 'volume' && a[3] == 'orb-$id-$suffix',
          );
          final volumeCreated = volume.indexWhere(
            (element) => element.startsWith('ocb.created='),
          );
          final actualVolume = List.of(volume)
            ..[volumeCreated] = 'ocb.created=*';
          expect(actualVolume, [
            'volume',
            'create',
            '--name',
            'orb-$id-$suffix',
            '--label',
            'ocb.orb=true',
            '--label',
            'ocb.id=$id',
            '--label',
            'ocb.name=dev',
            '--label',
            'ocb.project=proj-1',
            '--label',
            'ocb.branch=orb/$id',
            '--label',
            'ocb.created=*',
          ]);
        }

        // The `.env*` injection: `.env` + `.env.*`, never `*.example`.
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

        // The host opencode config, staged outside the per-orb state dir
        // (the state dir is bind-mounted into the container), the bridge
        // URL injected, the service descriptor never copied.
        final staged = '${stateRoot.path}/staged-$id';
        final stagedConfig = File('$staged/opencode.jsonc');
        expect(stagedConfig.existsSync(), isTrue);
        final configText = stagedConfig.readAsStringSync();
        expect(
          configText,
          contains('"bridgeUrl": "http://host.docker.internal:48201"'),
        );
        expect(configText, contains('"model": "test"'));
        // The host config file itself is never modified (#117).
        expect(
          File('${home.path}/.config/opencode/opencode.jsonc')
              .readAsStringSync(),
          isNot(contains('host.docker.internal')),
        );
        expect(File('$staged/service.json').existsSync(), isFalse);
        expect(File('$staged/plugins/p.txt').existsSync(), isTrue);
        // The staged entries ride in per TOP-LEVEL entry: directories as
        // the merge form (`<src>/. -> <dest>/`: a plain directory cp into an
        // existing destination lands inside it — `plugins/plugins/… — on
        // the wake re-copy), files plain (overwrite). A per-file copy would
        // fail in the created (not started) container where the parent
        // directory does not exist yet.
        expect(
          copies,
          containsAll([
            [
              'cp',
              '$staged/opencode.jsonc',
              '$container:/root/.config/opencode/opencode.jsonc',
            ],
            [
              'cp',
              '$staged/plugins/.',
              '$container:/root/.config/opencode/plugins/',
            ],
          ]),
        );
        expect(copies.where((a) => a.last.contains('service.json')), isEmpty);
        // Copy-if-exists: no host auth.json on this fake host.
        expect(copies.where((a) => a.last.endsWith('auth.json')), isEmpty);

        // The start, and the boot wait's follow stream (killed at the end).
        expect(
          docker.runArgs,
          containsAll([
            ['start', container],
          ]),
        );
        expect(docker.spawnArgs, [
          ['logs', '--follow', container],
        ]);
        expect(docker.spawned, hasLength(1));
        expect(docker.spawned[0].killed, isTrue);

        // The record carries the full label set (no password, ADR-0001).
        expect(record.id, id);
        expect(record.name, 'dev');
        expect(record.project, 'proj-1');
        expect(record.branch, 'orb/$id');
        expect(record.created, created.substring('ocb.created='.length));

        // The up-front refusals ran before the image ensure: the run order
        // is ps, image inspect, the two volumes, create, the cps, start.
        final firstRun = docker.runArgs.take(5).toList();
        expect(firstRun.first.first, 'ps');
        expect(firstRun[1], ['image', 'inspect', builder.expectedTag]);
        expect(firstRun.where((a) => a.first == 'volume').length, 2);
      },
    );

    test('the host auth.json is copied in when it exists', () async {
      hostConfig(withPlugins: false);
      File('${home.path}/.local/share/opencode/auth.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{}\n');
      const password = 'pw';
      final http = await HttpServer.bind('127.0.0.1', 0);
      http.listen((request) {
        request.response.statusCode = 200;
        unawaited(request.response.close());
      });
      final port = http.port;
      docker.ports = '{"4096/tcp":[{"HostIp":"127.0.0.1","HostPort":"$port"}]}';
      docker.logs = 'server password $password\n';

      await service().create(
        project: 'proj-1',
        name: 'dev',
        checkout: checkout.path,
      );
      await http.close(force: true);

      final container = docker.runArgs.firstWhere(
        (a) => a.first == 'create',
      )[2];
      expect(
        docker.runArgs.where((a) => a.first == 'cp'),
        containsAll([
          [
            'cp',
            '${home.path}/.local/share/opencode/auth.json',
            '$container:/root/.local/share/opencode/auth.json',
          ],
        ]),
      );
    });

    test('the boot streams orb.boot events', () async {
      final events = <Map<String, Object?>>[];
      hostConfig(withPlugins: false);
      const password = 'pw';
      final http = await HttpServer.bind('127.0.0.1', 0);
      http.listen((request) {
        request.response.statusCode = 200;
        unawaited(request.response.close());
      });
      final port = http.port;
      docker.ports = '{"4096/tcp":[{"HostIp":"127.0.0.1","HostPort":"$port"}]}';
      docker.logs = 'server password $password\n';
      final child = _FakeProcess();
      docker.processes.add(child);

      final pending = service(
        emit: (payload) =>
            events.add(jsonDecode(payload) as Map<String, Object?>),
      ).create(project: 'proj-1', name: 'dev', checkout: checkout.path);
      await _until(() => docker.spawnArgs.isNotEmpty);
      child.stdout.add('cloning the remote');
      child.stderr.add('fetch origin');
      child.exit(0);
      final record = await pending;
      await http.close(force: true);

      expect(events, isNotEmpty);
      for (final event in events) {
        expect(event['type'], 'orb.boot');
      }
      expect(
        events.map((e) => e['data']),
        containsAll([
          {'id': record.id, 'line': 'cloning the remote'},
          {'id': record.id, 'line': 'fetch origin'},
        ]),
      );
    });

    test(
      'a name taken in the project is refused before anything else',
      () async {
        docker.psResult = const DockerCliResult(
          exitCode: 0,
          stdout: 'other\ndev\n',
          stderr: '',
        );

        await expectLater(
          service().create(
            project: 'proj-1',
            name: 'dev',
            checkout: checkout.path,
          ),
          throwsA(
            isA<OrbNameTakenError>()
                .having((e) => e.project, 'project', 'proj-1')
                .having((e) => e.name, 'name', 'dev'),
          ),
        );
        expect(docker.runArgs, [
          [
            'ps',
            '-a',
            '--filter',
            'label=ocb.orb=true',
            '--filter',
            'label=ocb.project=proj-1',
            '--format',
            '{{.Label "ocb.name"}}',
          ],
        ]);
        expect(docker.spawnArgs, isEmpty);
        expect(git.args, isEmpty);
      },
    );

    test('a project with no remote is refused', () async {
      git.results['remote get-url origin'] = const GitCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'error: No remote named origin',
      );

      await expectLater(
        service().create(
          project: 'proj-1',
          name: 'dev',
          checkout: checkout.path,
        ),
        throwsA(
          isA<OrbRefusalError>().having(
            (e) => e.code,
            'code',
            OrbRefusalError.noRemote,
          ),
        ),
      );
      expect(docker.runArgs, hasLength(1)); // The name-taken ps only.
    });

    test('a non-GitHub remote is refused', () async {
      git.results['remote get-url origin'] = const GitCliResult(
        exitCode: 0,
        stdout: 'https://gitlab.com/acme/app.git\n',
        stderr: '',
      );

      await expectLater(
        service().create(
          project: 'proj-1',
          name: 'dev',
          checkout: checkout.path,
        ),
        throwsA(
          isA<OrbRefusalError>().having(
            (e) => e.code,
            'code',
            OrbRefusalError.nonGithubRemote,
          ),
        ),
      );
      expect(docker.runArgs, hasLength(1));
    });

    test('a missing host git identity is refused', () async {
      git.results['config user.name'] = const GitCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'fatal: no such config',
      );

      await expectLater(
        service().create(
          project: 'proj-1',
          name: 'dev',
          checkout: checkout.path,
        ),
        throwsA(
          isA<OrbRefusalError>().having(
            (e) => e.code,
            'code',
            OrbRefusalError.missingGitIdentity,
          ),
        ),
      );
      expect(docker.runArgs, hasLength(1));
    });

    test(
      'a seeded create passes ORB_BASE_BRANCH and the ocb.base label',
      () async {
        checkoutEnv();
        hostConfig();
        const password = 'pw-seed-123';
        final http = await HttpServer.bind('127.0.0.1', 0);
        http.listen((request) {
          final auth = request.headers.value('authorization') ?? '';
          request.response.statusCode =
              auth ==
                  'Basic ${base64.encode(utf8.encode('opencode:$password'))}'
              ? 200
              : 401;
          unawaited(request.response.close());
        });
        docker.ports =
            '{"4096/tcp":[{"HostIp":"127.0.0.1","HostPort":"${http.port}"}]}';
        docker.logs = 'server password $password\n';

        final record = await service().create(
          project: 'proj-1',
          name: 'variant',
          checkout: checkout.path,
          base: 'orb/seedid',
        );
        await http.close(force: true);

        expect(record.base, 'orb/seedid');
        final create = docker.runArgs.firstWhere((a) => a.first == 'create');
        expect(
          create,
          containsAllInOrder(['-e', 'ORB_BASE_BRANCH=orb/seedid']),
        );
        expect(create, containsAllInOrder(['-l', 'ocb.base=orb/seedid']));
        for (final suffix in const ['workspace', 'data']) {
          final volume = docker.runArgs.firstWhere(
            (a) => a.first == 'volume' && a[3] == 'orb-${record.id}-$suffix',
          );
          expect(volume, contains('--label'));
          expect(volume, contains('ocb.base=orb/seedid'));
        }
      },
    );

    test(
      'seedBranch: a stopped seed with a pushed branch resolves its branch',
      () async {
        // The seed's row: a stopped orb of the project.
        docker.psResult = const DockerCliResult(
          exitCode: 0,
          stdout: 'orb-seed9\n',
          stderr: '',
        );
        docker.containerLabelsResult = DockerCliResult(
          exitCode: 0,
          stdout: jsonEncode({
            'ocb.orb': 'true',
            'ocb.id': 'seed9',
            'ocb.name': 'parent',
            'ocb.project': 'proj-1',
            'ocb.branch': 'orb/seed9',
            'ocb.created': '2026-11-04T00:00:00.000Z',
          }),
          stderr: '',
        );
        docker.stateResult = const DockerCliResult(
          exitCode: 0,
          stdout: 'exited\n',
          stderr: '',
        );
        docker.volumeLsResult = const DockerCliResult(
          exitCode: 0,
          stdout: 'orb-seed9-workspace\norb-seed9-data\n',
          stderr: '',
        );
        docker.volumeInspectResult = DockerCliResult(
          exitCode: 0,
          stdout: [
            for (final _ in [0, 1])
              jsonEncode({
                'ocb.orb': 'true',
                'ocb.id': 'seed9',
                'ocb.name': 'parent',
                'ocb.project': 'proj-1',
                'ocb.branch': 'orb/seed9',
                'ocb.created': '2026-11-04T00:00:00.000Z',
              }),
          ].join('\n'),
          stderr: '',
        );
        // ls-remote finds the branch on the remote (the parent may be
        // stopped — the probe never touches the container).
        git.results['ls-remote --heads origin orb/seed9'] = const GitCliResult(
          exitCode: 0,
          stdout: 'deadbeef\trefs/heads/orb/seed9\n',
          stderr: '',
        );

        final base = await service().seedBranch(
          project: 'proj-1',
          seed: 'parent',
          checkout: checkout.path,
        );
        expect(base, 'orb/seed9');
        // The probe ran from the project checkout, against origin.
        expect(git.args.last, ['ls-remote', '--heads', 'origin', 'orb/seed9']);
      },
    );

    test('seedBranch: a branch never pushed is refused', () async {
      docker.psResult = const DockerCliResult(
        exitCode: 0,
        stdout: 'orb-seed9\n',
        stderr: '',
      );
      docker.containerLabelsResult = DockerCliResult(
        exitCode: 0,
        stdout: jsonEncode({
          'ocb.orb': 'true',
          'ocb.id': 'seed9',
          'ocb.name': 'parent',
          'ocb.project': 'proj-1',
          'ocb.branch': 'orb/seed9',
          'ocb.created': '2026-11-04T00:00:00.000Z',
        }),
        stderr: '',
      );
      docker.stateResult = const DockerCliResult(
        exitCode: 0,
        stdout: 'exited\n',
        stderr: '',
      );
      docker.volumeLsResult = const DockerCliResult(
        exitCode: 0,
        stdout: 'orb-seed9-workspace\norb-seed9-data\n',
        stderr: '',
      );
      docker.volumeInspectResult = DockerCliResult(
        exitCode: 0,
        stdout:
            '${jsonEncode({'ocb.orb': 'true', 'ocb.id': 'seed9', 'ocb.name': 'parent', 'ocb.project': 'proj-1', 'ocb.branch': 'orb/seed9', 'ocb.created': '2026-11-04T00:00:00.000Z'})}\n'
            '${jsonEncode({'ocb.orb': 'true', 'ocb.id': 'seed9', 'ocb.name': 'parent', 'ocb.project': 'proj-1', 'ocb.branch': 'orb/seed9', 'ocb.created': '2026-11-04T00:00:00.000Z'})}',
        stderr: '',
      );
      // The remote has no such branch (no commits pushed): empty output.
      git.results['ls-remote --heads origin orb/seed9'] = const GitCliResult(
        exitCode: 0,
        stdout: '',
        stderr: '',
      );

      await expectLater(
        service().seedBranch(
          project: 'proj-1',
          seed: 'parent',
          checkout: checkout.path,
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

    test('seedBranch: no orb with that name resolves null', () async {
      final base = await service().seedBranch(
        project: 'proj-1',
        seed: 'ghost',
        checkout: checkout.path,
      );
      expect(base, isNull);
      // No remote probe ran for a nonexistent seed.
      expect(git.args.where((a) => a.first == 'ls-remote'), isEmpty);
    });

    test(
      'a container exiting during boot is an OrbBootError with the tail',
      () async {
        docker.stateResult = const DockerCliResult(
          exitCode: 0,
          stdout: 'exited\n',
          stderr: '',
        );
        docker.logs = 'cloning the remote\nfatal: repository not found\n';

        await expectLater(
          service().create(
            project: 'proj-1',
            name: 'dev',
            checkout: checkout.path,
          ),
          throwsA(
            isA<OrbBootError>()
                .having(
                  (e) => e.detail,
                  'detail',
                  'the orb container exited during boot',
                )
                .having((e) => e.logTail, 'logTail', [
                  'cloning the remote',
                  'fatal: repository not found',
                ]),
          ),
        );
        expect(docker.spawned[0].killed, isTrue);
      },
    );

    test('a boot that never comes up times out', () async {
      docker.logs = 'starting...'; // No `server password` line, ever.

      await expectLater(
        service(bootTimeout: const Duration(milliseconds: 300))
            .create(project: 'proj-1', name: 'dev', checkout: checkout.path),
        throwsA(
          isA<OrbBootError>().having(
            (e) => e.detail,
            'detail',
            startsWith('the orb did not come up within'),
          ),
        ),
      );
      expect(docker.spawned[0].killed, isTrue);
    });

    test('a descriptor that does not accept yet is retried until it does', () async {
      const password = 'pw';
      final http = await HttpServer.bind('127.0.0.1', 0);
      var requests = 0;
      http.listen((request) {
        requests++;
        // The first hit is refused (the server not accepting yet); after
        // it, the auth verifies.
        final accept = requests > 1;
        final auth = request.headers.value('authorization') ?? '';
        request.response.statusCode =
            accept &&
                auth ==
                    'Basic ${base64.encode(utf8.encode('opencode:$password'))}'
            ? 200
            : 401;
        unawaited(request.response.close());
      });
      final port = http.port;
      docker.ports = '{"4096/tcp":[{"HostIp":"127.0.0.1","HostPort":"$port"}]}';
      docker.logs = 'server password $password\n';

      final record = await service().create(
        project: 'proj-1',
        name: 'dev',
        checkout: checkout.path,
      );
      await http.close(force: true);

      expect(requests, greaterThan(1));
      expect(record.url, 'http://127.0.0.1:$port');
    });

    test('list composes running, stopped, broken, and orphan rows', () async {
      const created = '2026-11-04T00:00:00.000Z';
      String labels(String id, String name) => jsonEncode({
        'ocb.orb': 'true',
        'ocb.id': id,
        'ocb.name': name,
        'ocb.project': 'p1',
        'ocb.branch': 'orb/$id',
        'ocb.created': created,
      });

      const a = 'aaaaaaaaaaaaaaaa';
      const b = 'bbbbbbbbbbbbbbbb';
      const c = 'cccccccccccccccc';
      const d = 'dddddddddddddddd';
      const e = 'eeeeeeeeeeeeeeee';
      docker.psResult = const DockerCliResult(
        exitCode: 0,
        stdout: 'orb-$a\norb-$b\norb-$c\norb-$d\n',
        stderr: '',
      );
      docker.containerLabelsResult = DockerCliResult(
        exitCode: 0,
        stdout:
            '${labels(a, 'dev')}\n${labels(b, 'beta')}\n'
            '${labels(c, 'gamma')}\n${labels(d, 'delta')}\n',
        stderr: '',
      );
      docker.stateResult = const DockerCliResult(
        exitCode: 0,
        stdout: 'running\nstopped\nstopped\nstopped\n',
        stderr: '',
      );
      docker.ports = '{"4096/tcp":[{"HostIp":"127.0.0.1","HostPort":"39999"}]}\nnull\nnull\nnull\n';
      // a's full log carries the password line, so it is `running` (not
      // `preparing`).
      docker.containerLogs['orb-$a'] =
          '[orb] stage: ready\nserver password pw\n';
      // c has no workspace volume (broken:workspace), d has its volumes but
      // its state dir is removed (broken:state), e's volumes have no
      // container (orphan), b's state dir exists (clean stopped).
      docker.volumeLsResult = DockerCliResult(
        exitCode: 0,
        stdout:
            'orb-$a-workspace\norb-$a-data\norb-$b-workspace\norb-$b-data\n'
            'orb-$d-workspace\norb-$d-data\norb-$e-workspace\norb-$e-data\n',
        stderr: '',
      );
      docker.volumeInspectResult = DockerCliResult(
        exitCode: 0,
        stdout: [
          for (final (id, name) in [
            (a, 'dev'),
            (a, 'dev'),
            (b, 'beta'),
            (b, 'beta'),
            (d, 'delta'),
            (d, 'delta'),
            (e, 'epsilon'),
            (e, 'epsilon'),
          ])
            labels(id, name),
        ].join('\n'),
        stderr: '',
      );
      Directory('${stateRoot.path}/$b').createSync(recursive: true);

      final rows = await service().list();

      expect(rows, [
        OrbRecord(
          id: a,
          name: 'dev',
          project: 'p1',
          branch: 'orb/$a',
          state: 'running',
          created: created,
          url: 'http://127.0.0.1:39999',
        ),
        OrbRecord(
          id: b,
          name: 'beta',
          project: 'p1',
          branch: 'orb/$b',
          state: 'stopped',
          created: created,
        ),
        OrbRecord(
          id: c,
          name: 'gamma',
          project: 'p1',
          branch: 'orb/$c',
          state: 'broken:workspace',
          created: created,
        ),
        OrbRecord(
          id: d,
          name: 'delta',
          project: 'p1',
          branch: 'orb/$d',
          state: 'broken:state',
          created: created,
        ),
        OrbRecord(
          id: e,
          name: 'epsilon',
          project: 'p1',
          branch: 'orb/$e',
          state: 'orphan',
          created: created,
        ),
      ]);
    });

    test(
      'list marks a not-yet-booted container as preparing with the stage',
      () async {
        const created = '2026-11-04T00:00:00.000Z';
        String labels(String id, String name) => jsonEncode({
          'ocb.orb': 'true',
          'ocb.id': id,
          'ocb.name': name,
          'ocb.project': 'p1',
          'ocb.branch': 'orb/$id',
          'ocb.created': created,
        });

        const a = 'aaaaaaaaaaaaaaaa';
        const b = 'bbbbbbbbbbbbbbbb';
        docker.psResult = const DockerCliResult(
          exitCode: 0,
          stdout: 'orb-$a\norb-$b\n',
          stderr: '',
        );
        docker.containerLabelsResult = DockerCliResult(
          exitCode: 0,
          stdout: '${labels(a, 'dev')}\n${labels(b, 'beta')}\n',
          stderr: '',
        );
        // a was created but never started; b is running but its boot is
        // still in flight (no `server password` line yet, last stage
        // `installing`).
        docker.stateResult = const DockerCliResult(
          exitCode: 0,
          stdout: 'created\nrunning\n',
          stderr: '',
        );
        docker.ports = 'null\nnull\n';
        docker.containerLogs['orb-$b'] =
            '[orb] stage: cloning\n[orb] stage: installing\n';
        docker.volumeLsResult = DockerCliResult(
          exitCode: 0,
          stdout:
              'orb-$a-workspace\norb-$a-data\norb-$b-workspace\norb-$b-data\n',
          stderr: '',
        );

        final rows = await service().list();

        expect(rows, [
          const OrbRecord(
            id: a,
            name: 'dev',
            project: 'p1',
            branch: 'orb/$a',
            state: 'preparing',
            created: created,
          ),
          const OrbRecord(
            id: b,
            name: 'beta',
            project: 'p1',
            branch: 'orb/$b',
            state: 'preparing:installing',
            created: created,
          ),
        ]);
      },
    );

    test('list with includePr enriches the rows with their PR', () async {
      const created = '2026-11-04T00:00:00.000Z';
      String labels(String id, String name) => jsonEncode({
        'ocb.orb': 'true',
        'ocb.id': id,
        'ocb.name': name,
        'ocb.project': 'p1',
        'ocb.branch': 'orb/$id',
        'ocb.created': created,
      });

      const a = 'aaaaaaaaaaaaaaaa';
      const b = 'bbbbbbbbbbbbbbbb';
      docker.psResult = const DockerCliResult(
        exitCode: 0,
        stdout: 'orb-$a\norb-$b\n',
        stderr: '',
      );
      docker.containerLabelsResult = DockerCliResult(
        exitCode: 0,
        stdout: '${labels(a, 'dev')}\n${labels(b, 'beta')}\n',
        stderr: '',
      );
      docker.stateResult = const DockerCliResult(
        exitCode: 0,
        stdout: 'running\nrunning\n',
        stderr: '',
      );
      docker.ports = 'null\nnull\n';
      final log = 'server password pw\n';
      docker.containerLogs['orb-$a'] = log;
      docker.containerLogs['orb-$b'] = log;
      docker.volumeLsResult = const DockerCliResult(
        exitCode: 0,
        stdout: '',
        stderr: '',
      );

      final gh = _FakeGh();
      gh.results['pr view orb/$a --repo acme/app --json state,url'] =
          const GitCliResult(
            exitCode: 0,
            stdout:
                '{"state":"OPEN","url":"https://github.com/acme/app/pull/7"}',
            stderr: '',
          );
      gh.results['pr view orb/$b --repo acme/app --json state,url'] =
          const GitCliResult(
            exitCode: 1,
            stdout: '',
            stderr: 'no pull requests found',
          );

      final rows = await service(
        gh: gh.run,
        repoFor: (projectId) async => projectId == 'p1' ? 'acme/app' : null,
      ).list(includePr: true);

      expect(rows, [
        const OrbRecord(
          id: a,
          name: 'dev',
          project: 'p1',
          branch: 'orb/$a',
          state: 'running',
          created: created,
          pr: OrbPr(state: 'open', url: 'https://github.com/acme/app/pull/7'),
        ),
        const OrbRecord(
          id: b,
          name: 'beta',
          project: 'p1',
          branch: 'orb/$b',
          state: 'running',
          created: created,
        ),
      ]);
      expect(gh.args, hasLength(2));
    });

    test('list without includePr never queries gh', () async {
      const created = '2026-11-04T00:00:00.000Z';
      const a = 'aaaaaaaaaaaaaaaa';
      docker.psResult = const DockerCliResult(
        exitCode: 0,
        stdout: 'orb-$a\n',
        stderr: '',
      );
      docker.containerLabelsResult = DockerCliResult(
        exitCode: 0,
        stdout: jsonEncode({
          'ocb.orb': 'true',
          'ocb.id': a,
          'ocb.name': 'dev',
          'ocb.project': 'p1',
          'ocb.branch': 'orb/$a',
          'ocb.created': created,
        }),
        stderr: '',
      );
      docker.stateResult = const DockerCliResult(
        exitCode: 0,
        stdout: 'running\n',
        stderr: '',
      );
      docker.ports = 'null\n';
      docker.containerLogs['orb-$a'] = 'server password pw\n';
      docker.volumeLsResult = const DockerCliResult(
        exitCode: 0,
        stdout: '',
        stderr: '',
      );

      final gh = _FakeGh();

      final rows = await service(
        gh: gh.run,
        repoFor: (projectId) async => 'acme/app',
      ).list();

      expect(gh.args, isEmpty);
      expect(rows.single.pr, isNull);
    });

    test('deleteOrphan removes the orphan volumes and the state dir', () async {
      const id = 'eeeeeeeeeeeeeeee';
      // No container: the inspect probe exits 1.
      docker.inspectIdResult = const DockerCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'no such container',
      );
      docker.volumeLsResult = const DockerCliResult(
        exitCode: 0,
        stdout: 'orb-$id-workspace\norb-$id-data\n',
        stderr: '',
      );
      final stateDir = Directory('${stateRoot.path}/$id')
        ..createSync(recursive: true);

      await service().deleteOrphan(id);

      expect(docker.volumeRmNames, ['orb-$id-workspace', 'orb-$id-data']);
      expect(stateDir.existsSync(), isFalse);
    });

    test('deleteOrphan refuses a live container', () async {
      const id = 'eeeeeeeeeeeeeeee';
      docker.inspectIdResult = const DockerCliResult(
        exitCode: 0,
        stdout: 'cid',
        stderr: '',
      );

      await expectLater(
        service().deleteOrphan(id),
        throwsA(isA<OrbExistsError>()),
      );
      expect(docker.volumeRmNames, isEmpty);
    });

    test('deleteOrphan reports a missing orphan', () async {
      const id = 'eeeeeeeeeeeeeeee';
      docker.inspectIdResult = const DockerCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'no such container',
      );
      docker.volumeLsResult = const DockerCliResult(
        exitCode: 0,
        stdout: '',
        stderr: '',
      );

      await expectLater(
        service().deleteOrphan(id),
        throwsA(isA<OrbOrphanNotFoundError>()),
      );
    });

    test('deleteOrphan surfaces the daemon failure', () async {
      const id = 'eeeeeeeeeeeeeeee';
      docker.inspectIdResult = const DockerCliResult(
        exitCode: 2,
        stdout: '',
        stderr: 'Cannot connect to the Docker daemon',
      );

      await expectLater(
        service().deleteOrphan(id),
        throwsA(isA<DockerUnavailableError>()),
      );
    });

    test('an empty host is an empty list', () async {
      expect(await service().list(), isEmpty);
    });

    test('a daemon failure is a DockerUnavailableError', () async {
      docker.psResult = const DockerCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Cannot connect to the Docker daemon',
      );

      await expectLater(
        service().list(),
        throwsA(isA<DockerUnavailableError>()),
      );
    });

    test('rewriteLoopbackUrls swaps the loopback hosts only', () {
      // Provider baseURL + MCP server URL, port + path kept.
      expect(
        OrbService.rewriteLoopbackUrls(
          '{"baseURL": "http://localhost:8081/v1", '
          '"url": "http://127.0.0.1:3000/mcp", '
          '"baseURL2": "https://0.0.0.0:9/"}',
        ),
        '{"baseURL": "http://host.docker.internal:8081/v1", '
        '"url": "http://host.docker.internal:3000/mcp", '
        '"baseURL2": "https://host.docker.internal:9/"}',
      );
      // Remote URLs and loopback without a scheme pass through untouched.
      expect(
        OrbService.rewriteLoopbackUrls(
          '{"baseURL": "https://api.openai.com/v1", "note": "localhost dev"}',
        ),
        '{"baseURL": "https://api.openai.com/v1", "note": "localhost dev"}',
      );
      // A URL-less config (no provider block) survives untouched.
      expect(
        OrbService.rewriteLoopbackUrls('{"model": "test"}'),
        '{"model": "test"}',
      );
      // A loopback URL ending the string (no port/path) is still rewritten.
      expect(
        OrbService.rewriteLoopbackUrls('{"url": "http://localhost"}'),
        '{"url": "http://host.docker.internal"}',
      );
    });

    test(
      'the staging rewrites loopback provider URLs, remote ones untouched',
      () async {
        // A host config with a loopback provider + MCP server and a remote
        // provider (json, not jsonc — the rewrite must cover both names).
        final config = Directory('${home.path}/.config/opencode')
          ..createSync(recursive: true);
        const hostText =
            '{\n'
            '  "model": "local-machine/qwen",\n'
            '  "provider": {\n'
            '    "local-machine": {\n'
            '      "settings": { "baseURL": "http://localhost:8081/v1" }\n'
            '    },\n'
            '    "remote": {\n'
            '      "settings": { "baseURL": "https://api.example.com/v1" }\n'
            '    }\n'
            '  },\n'
            '  "mcp": { "local": { "url": "http://127.0.0.1:3000" } }\n'
            '}\n';
        File('${config.path}/opencode.json').writeAsStringSync(hostText);
        const password = 'pw';
        final http = await HttpServer.bind('127.0.0.1', 0);
        http.listen((request) {
          request.response.statusCode = 200;
          unawaited(request.response.close());
        });
        docker.ports =
            '{"4096/tcp":[{"HostIp":"127.0.0.1","HostPort":"${http.port}"}]}';
        docker.logs = 'server password $password\n';

        await service().create(
          project: 'proj-1',
          name: 'dev',
          checkout: checkout.path,
        );
        await http.close(force: true);

        final container = docker.runArgs.firstWhere(
          (a) => a.first == 'create',
        )[2];
        final id = container.substring('orb-'.length);
        final stagedText = File('${stateRoot.path}/staged-$id/opencode.json')
            .readAsStringSync();
        // Loopback URLs rewritten to host.docker.internal, port kept.
        expect(
          stagedText,
          contains('"baseURL": "http://host.docker.internal:8081/v1"'),
        );
        expect(
          stagedText,
          contains('"url": "http://host.docker.internal:3000"'),
        );
        // The remote provider untouched, the rest of the config intact.
        expect(stagedText, contains('"baseURL": "https://api.example.com/v1"'));
        expect(stagedText, contains('"model": "local-machine/qwen"'));
        // The host config file itself is never modified.
        expect(
          File('${config.path}/opencode.json').readAsStringSync(),
          hostText,
        );
      },
    );

    test('the staging survives a config without any provider block', () async {
      hostConfig(withPlugins: false);
      const password = 'pw';
      final http = await HttpServer.bind('127.0.0.1', 0);
      http.listen((request) {
        request.response.statusCode = 200;
        unawaited(request.response.close());
      });
      docker.ports =
          '{"4096/tcp":[{"HostIp":"127.0.0.1","HostPort":"${http.port}"}]}';
      docker.logs = 'server password $password\n';

      await service().create(
        project: 'proj-1',
        name: 'dev',
        checkout: checkout.path,
      );
      await http.close(force: true);

      final container = docker.runArgs.firstWhere(
        (a) => a.first == 'create',
      )[2];
      final id = container.substring('orb-'.length);
      final stagedText = File('${stateRoot.path}/staged-$id/opencode.jsonc')
          .readAsStringSync();
      // Untouched apart from the injected bridge URL.
      expect(stagedText, contains('"model": "test"'));
    });

    test('lastServerPassword takes the last line, or null', () {
      expect(
        OrbService.lastServerPassword(
          'a\nserver password one\nserver password two\n',
        ),
        'two',
      );
      expect(OrbService.lastServerPassword('nothing here'), isNull);
    });

    test('isGitHubRemote accepts the GitHub remote forms only', () {
      expect(
        OrbService.isGitHubRemote('https://github.com/acme/app.git'),
        isTrue,
      );
      expect(
        OrbService.isGitHubRemote('http://github.com/acme/app.git'),
        isTrue,
      );
      expect(OrbService.isGitHubRemote('git@github.com:acme/app.git'), isTrue);
      expect(
        OrbService.isGitHubRemote('ssh://git@github.com/acme/app.git'),
        isTrue,
      );
      expect(
        OrbService.isGitHubRemote('https://gitlab.com/acme/app.git'),
        isFalse,
      );
      expect(OrbService.isGitHubRemote('git@gitlab.com:acme/app.git'), isFalse);
      expect(OrbService.isGitHubRemote(''), isFalse);
    });

    test('lastStage takes the last stage word, or null', () {
      expect(
        OrbService.lastStage(
          '[orb] stage: cloning\n[orb] stage: installing\n[orb] other\n',
        ),
        'installing',
      );
      expect(
        OrbService.lastStage('[orb] stage: services\n[orb] stage: health\n'),
        'health',
      );
      expect(OrbService.lastStage('no stage lines here'), isNull);
    });

    test('githubRepo parses the four GitHub remote forms', () {
      expect(
        OrbService.githubRepo('https://github.com/acme/app.git'),
        'acme/app',
      );
      expect(OrbService.githubRepo('http://github.com/acme/app'), 'acme/app');
      expect(OrbService.githubRepo('git@github.com:acme/app.git'), 'acme/app');
      expect(
        OrbService.githubRepo('ssh://git@github.com/acme/app.git'),
        'acme/app',
      );
      expect(OrbService.githubRepo('https://gitlab.com/acme/app.git'), isNull);
      expect(OrbService.githubRepo('https://github.com/'), isNull);
      expect(OrbService.githubRepo('github.com/acme/app'), isNull);
      expect(OrbService.githubRepo(''), isNull);
    });
  });
}
