import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/docker/docker_backend.dart';
import 'package:opencodebridge/model/compose_project.dart';
import 'package:opencodebridge/model/container.dart';

/// A scripted docker CLI child for the spawner seam.
class _FakeProcess {
  final StreamController<String> stdout = StreamController<String>();
  final StreamController<String> stderr = StreamController<String>();
  final Completer<int> _exit = Completer<int>();
  bool killed = false;

  DockerProcess toProcess() => DockerProcess(
    stdout: stdout.stream,
    stderr: stderr.stream,
    exitCode: _exit.future,
    kill: kill,
  );

  Future<void> kill() async {
    killed = true;
    // Like the real SIGTERM: the streams are closed, but not waited on — a
    // stream nobody listened to never delivers its done event.
    stdout.close();
    stderr.close();
    if (!_exit.isCompleted) _exit.complete(0);
  }
}

/// The DockerRunner/DockerSpawner seam, scripted.
class _FakeDocker {
  final List<List<String>> runArgs = [];
  final List<String?> runWorkingDirs = [];
  final List<List<String>> spawnArgs = [];
  final List<_FakeProcess> spawned = [];
  final List<String> emitted = [];
  DockerCliResult runResult = const DockerCliResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );

  /// Results queued for the next [run] calls, in order; consumed before
  /// [runResult] (which is the fallback for any un-queued call). Lets one
  /// backend return distinct output for `config --services` and `ps --all`.
  final List<DockerCliResult> runResults = [];

  /// The next children the spawner returns, in order.
  final List<_FakeProcess> processes = [];

  DockerBackend bind({
    bool watch = false,
    Duration reconnectDelay = const Duration(milliseconds: 1),
  }) => DockerBackend(
    run: _run,
    spawn: _spawn,
    emit: watch ? emitted.add : null,
    reconnectDelay: reconnectDelay,
  );

  Future<DockerCliResult> _run(
    List<String> argv, {
    String? workingDirectory,
  }) async {
    runArgs.add(List.of(argv));
    runWorkingDirs.add(workingDirectory);
    return runResults.isNotEmpty ? runResults.removeAt(0) : runResult;
  }

  Future<DockerProcess> _spawn(
    List<String> argv, {
    String? workingDirectory,
  }) async {
    spawnArgs.add(List.of(argv));
    if (processes.isNotEmpty) {
      final process = processes.removeAt(0);
      spawned.add(process);
      return process.toProcess();
    }
    final process = _FakeProcess();
    spawned.add(process);
    return process.toProcess();
  }
}

const _psOutput = '''
{"Names": "web, web-1", "Image": "nginx:latest", "State": "running", "RunningFor": "2 hours ago"}
{"Names": "db", "Image": "postgres:16", "State": "exited", "RunningFor": ""}
''';

String _dieEvent(String name, String exitCode, {String action = 'die'}) =>
    jsonEncode({
      'Action': action,
      'Actor': {
        'Attributes': {'exitCode': exitCode, 'name': name},
      },
      'Type': 'container',
    });

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
  group('DockerBackend.list', () {
    test('returns the containers in the CLI order', () async {
      final fake = _FakeDocker();
      fake.runResult = const DockerCliResult(
        exitCode: 0,
        stdout: _psOutput,
        stderr: '',
      );
      final backend = fake.bind();
      try {
        final rows = await backend.list();
        expect(rows, [
          const DockerContainer(
            name: 'web',
            image: 'nginx:latest',
            state: DockerState.running,
            uptime: '2 hours ago',
          ),
          const DockerContainer(
            name: 'db',
            image: 'postgres:16',
            state: DockerState.exited,
            uptime: null,
          ),
        ]);
        expect(fake.runArgs.single, const [
          'ps',
          '-a',
          '--format',
          '{{json .}}',
        ]);
      } finally {
        await backend.close();
      }
    });

    test('a CLI failure is DockerUnavailableError', () async {
      final fake = _FakeDocker();
      fake.runResult = const DockerCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Cannot connect to the Docker daemon',
      );
      final backend = fake.bind();
      try {
        await expectLater(
          backend.list(),
          throwsA(isA<DockerUnavailableError>()),
        );
      } finally {
        await backend.close();
      }
    });
  });

  group('DockerBackend actions', () {
    test('start, stop, restart address the container by name', () async {
      final fake = _FakeDocker();
      final backend = fake.bind();
      try {
        await backend.start('web');
        await backend.stop('web');
        await backend.restart('web');
        expect(fake.runArgs, [
          const ['start', 'web'],
          const ['stop', 'web'],
          const ['restart', 'web'],
        ]);
      } finally {
        await backend.close();
      }
    });

    test('an unknown container is DockerNotFoundError', () async {
      final fake = _FakeDocker();
      fake.runResult = const DockerCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Error response from daemon: No such container: web',
      );
      final backend = fake.bind();
      try {
        await expectLater(
          backend.start('web'),
          throwsA(isA<DockerNotFoundError>()),
        );
        await expectLater(
          backend.stop('web'),
          throwsA(isA<DockerNotFoundError>()),
        );
        await expectLater(
          backend.restart('web'),
          throwsA(isA<DockerNotFoundError>()),
        );
      } finally {
        await backend.close();
      }
    });

    test('a daemon failure is DockerUnavailableError', () async {
      final fake = _FakeDocker();
      fake.runResult = const DockerCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Cannot connect to the Docker daemon',
      );
      final backend = fake.bind();
      try {
        await expectLater(
          backend.stop('web'),
          throwsA(isA<DockerUnavailableError>()),
        );
      } finally {
        await backend.close();
      }
    });
  });

  group('DockerBackend.logs', () {
    test(
      'probes with inspect, then spawns docker logs with --follow',
      () async {
        final fake = _FakeDocker();
        final child = _FakeProcess();
        fake.processes.add(child);
        final backend = fake.bind();
        try {
          final stream = await backend.logs('web', follow: true);
          expect(fake.runArgs.single, [
            'inspect',
            '--format',
            '{{.Id}}',
            'web',
          ]);
          expect(fake.spawnArgs.single, ['logs', '--follow', 'web']);

          final lines = <String>[];
          final sub = stream.lines.listen(lines.add);
          child.stdout.add('alpha');
          child.stdout.add('beta');
          child.stdout.close();
          await sub.asFuture<void>();
          expect(lines, ['alpha', 'beta']);
          await stream.close();
        } finally {
          await backend.close();
        }
      },
    );

    test('follow: false omits --follow', () async {
      final fake = _FakeDocker();
      final child = _FakeProcess();
      fake.processes.add(child);
      final backend = fake.bind();
      try {
        final stream = await backend.logs('web', follow: false);
        expect(fake.spawnArgs.single, ['logs', 'web']);
        child.stdout.close();
        await stream.close();
      } finally {
        await backend.close();
      }
    });

    test('an unknown container fails before spawning', () async {
      final fake = _FakeDocker();
      fake.runResult = const DockerCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Error: No such container: web',
      );
      final backend = fake.bind();
      try {
        await expectLater(
          backend.logs('web', follow: true),
          throwsA(isA<DockerNotFoundError>()),
        );
        expect(fake.spawnArgs, isEmpty);
      } finally {
        await backend.close();
      }
    });

    test('a daemon failure fails with DockerUnavailableError', () async {
      final fake = _FakeDocker();
      fake.runResult = const DockerCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Cannot connect to the Docker daemon',
      );
      final backend = fake.bind();
      try {
        await expectLater(
          backend.logs('web', follow: true),
          throwsA(isA<DockerUnavailableError>()),
        );
        expect(fake.spawnArgs, isEmpty);
      } finally {
        await backend.close();
      }
    });
  });

  group('DockerBackend event watch', () {
    test('a clean die emits docker.container.stopped', () async {
      final fake = _FakeDocker();
      final child = _FakeProcess();
      fake.processes.add(child);
      final backend = fake.bind(watch: true);
      try {
        await _until(() => fake.spawnArgs.length == 1);
        expect(fake.spawnArgs.single, const [
          'events',
          '--filter',
          'type=container',
          '--format',
          '{{json .}}',
        ]);

        child.stdout.add(_dieEvent('web', '0'));
        await _until(() => fake.emitted.isNotEmpty);
        final event = jsonDecode(fake.emitted.single) as Map<String, Object?>;
        expect(event['type'], 'docker.container.stopped');
        expect(event['data'], {'name': 'web'});
      } finally {
        await backend.close();
      }
    });

    test(
      'a non-zero die emits docker.container.crashed with the exit code',
      () async {
        final fake = _FakeDocker();
        final child = _FakeProcess();
        fake.processes.add(child);
        final backend = fake.bind(watch: true);
        try {
          await _until(() => fake.spawnArgs.length == 1);

          child.stdout.add(_dieEvent('web', '137'));
          await _until(() => fake.emitted.isNotEmpty);
          final event = jsonDecode(fake.emitted.single) as Map<String, Object?>;
          expect(event['type'], 'docker.container.crashed');
          expect(event['data'], {'name': 'web', 'exitCode': 137});
        } finally {
          await backend.close();
        }
      },
    );

    test(
      'non-die actions, malformed lines, and nameless dies are ignored',
      () async {
        final fake = _FakeDocker();
        final child = _FakeProcess();
        fake.processes.add(child);
        final backend = fake.bind(watch: true);
        try {
          await _until(() => fake.spawnArgs.length == 1);

          child.stdout.add(_dieEvent('web', '0', action: 'update'));
          child.stdout.add('not json');
          child.stdout.add(
            jsonEncode({
              'Action': 'die',
              'Actor': {
                'Attributes': {'exitCode': '1'},
              },
            }),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(fake.emitted, isEmpty);
        } finally {
          await backend.close();
        }
      },
    );

    test('the watch re-subscribes when the child exits', () async {
      final fake = _FakeDocker();
      final first = _FakeProcess();
      fake.processes.add(first);
      fake.processes.add(_FakeProcess());
      final backend = fake.bind(watch: true);
      try {
        await _until(() => fake.spawnArgs.length == 1);
        first.stdout.close(); // The daemon dropped the watch.
        await _until(
          () => fake.spawnArgs.length == 2,
          timeout: const Duration(seconds: 5),
        );
      } finally {
        await backend.close();
      }
    });

    test('close kills the watch child and stops re-subscribing', () async {
      final fake = _FakeDocker();
      final child = _FakeProcess();
      fake.processes.add(child);
      final backend = fake.bind(watch: true);
      await _until(() => fake.spawnArgs.length == 1);
      await backend.close();
      expect(child.killed, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fake.spawnArgs.length, 1);
    });
  });

  group('parseContainerList', () {
    test('parses the CLI rows, taking the first of several names', () {
      final rows = parseContainerList(_psOutput);
      expect(rows, [
        const DockerContainer(
          name: 'web',
          image: 'nginx:latest',
          state: DockerState.running,
          uptime: '2 hours ago',
        ),
        const DockerContainer(
          name: 'db',
          image: 'postgres:16',
          state: DockerState.exited,
          uptime: null,
        ),
      ]);
    });

    test('skips malformed and blank lines', () {
      final rows = parseContainerList(
        'not json\n\n'
        '{"Names": "web", "Image": "nginx:latest", "State": "running", '
        '"RunningFor": "1 hour ago"}\n',
      );
      expect(rows, [
        const DockerContainer(
          name: 'web',
          image: 'nginx:latest',
          state: DockerState.running,
          uptime: '1 hour ago',
        ),
      ]);
    });

    test('an unknown state falls back to created', () {
      final rows = parseContainerList(
        '{"Names": "web", "Image": "img", "State": "time-traveling", '
        '"RunningFor": ""}\n',
      );
      expect(rows.single.state, DockerState.created);
    });

    test('empty output is no containers', () {
      expect(parseContainerList(''), isEmpty);
    });
  });

  group('DockerBackend.host', () {
    test('resolves the docker CLI on the given PATH', () async {
      final dir = await Directory.systemTemp.createTemp('oc-docker-host');
      try {
        final binary = File('${dir.path}/docker');
        await binary.writeAsString('#!/bin/sh\n');
        Process.runSync('chmod', ['755', binary.path]);
        final backend = await DockerBackend.host(path: dir.path);
        expect(backend, isNotNull);
        await backend?.close();
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('returns null when the docker CLI is absent', () async {
      final dir = await Directory.systemTemp.createTemp('oc-docker-none');
      try {
        expect(await DockerBackend.host(path: dir.path), isNull);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('findHostDocker', () {
    test('skips non-executable files and keeps going', () async {
      final dir = await Directory.systemTemp.createTemp('oc-docker-exec');
      try {
        final binary = File('${dir.path}/docker');
        await binary.writeAsString('#!/bin/sh\n');
        Process.runSync('chmod', ['644', binary.path]);
        expect(findHostDocker(path: dir.path), isNull);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('returns null when nothing matches', () {
      expect(findHostDocker(path: '/definitely/not/a/path-$_pid'), isNull);
    });
  });

  group('findComposeFile', () {
    test('finds the compose file in the directory', () async {
      final dir = await Directory.systemTemp.createTemp('oc-compose-file');
      try {
        final file = File('${dir.path}/docker-compose.yml');
        await file.writeAsString('services: {}\n');
        expect(DockerBackend.findComposeFile(dir.path), file.path);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('returns null when no compose file is present', () async {
      final dir = await Directory.systemTemp.createTemp('oc-compose-none');
      try {
        expect(DockerBackend.findComposeFile(dir.path), isNull);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('parseComposeServices', () {
    test('merges the creatable names with their live state', () {
      const psOutput = '''
{"Service": "web", "Name": "proj-web-1", "Image": "nginx:latest", "State": "running"}
{"Service": "db", "Name": "proj-db-1", "Image": "postgres:16", "State": "exited"}
''';
      final services = parseComposeServices(
        configServices: ['web', 'db', 'cache'],
        psOutput: psOutput,
      );
      expect(services, [
        const ComposeService(
          name: 'web',
          state: DockerState.running,
          image: 'nginx:latest',
          container: 'proj-web-1',
        ),
        const ComposeService(
          name: 'db',
          state: DockerState.exited,
          image: 'postgres:16',
          container: 'proj-db-1',
        ),
        // `cache` is creatable but never created: no live row.
        const ComposeService(name: 'cache', state: null),
      ]);
    });
  });

  group('DockerBackend.composeProjects', () {
    Future<Directory> repo() async {
      final dir = await Directory.systemTemp.createTemp('oc-compose-repo');
      await File('${dir.path}/docker-compose.yml')
          .writeAsString('services: {}\n');
      return dir;
    }

    test('skips directories without a compose file', () async {
      final withCompose = await repo();
      final without = await Directory.systemTemp.createTemp('oc-compose-skip');
      final fake = _FakeDocker();
      fake.runResults
        ..add(const DockerCliResult(exitCode: 0, stdout: 'web\n', stderr: ''))
        ..add(const DockerCliResult(exitCode: 0, stdout: '', stderr: ''));
      final backend = fake.bind();
      try {
        final projects = await backend.composeProjects([
          without.path,
          withCompose.path,
        ]);
        expect(projects, hasLength(1));
        expect(projects.single.path, withCompose.path);
        // Only the directory with a compose file ran docker.
        expect(fake.runWorkingDirs, [withCompose.path, withCompose.path]);
      } finally {
        await backend.close();
        await withCompose.delete(recursive: true);
        await without.delete(recursive: true);
      }
    });

    test('reports the project with its services and live state', () async {
      final dir = await repo();
      final fake = _FakeDocker();
      fake.runResults
        ..add(
          const DockerCliResult(exitCode: 0, stdout: 'web\ndb\n', stderr: ''),
        )
        ..add(
          const DockerCliResult(
            exitCode: 0,
            stdout: '{"Service": "db", "Name": "x-db-1", "Image": "alpine", "State": "exited"}\n',
            stderr: '',
          ),
        );
      final backend = fake.bind();
      try {
        final projects = await backend.composeProjects([dir.path]);
        final project = projects.single;
        expect(project.path, dir.path);
        expect(project.project, _basename(dir.path));
        expect(project.id, ComposeProject.encodeId(dir.path));
        expect(project.services, [
          const ComposeService(name: 'web', state: null),
          const ComposeService(
            name: 'db',
            state: DockerState.exited,
            image: 'alpine',
            container: 'x-db-1',
          ),
        ]);
      } finally {
        await backend.close();
        await dir.delete(recursive: true);
      }
    });

    test('a config failure is DockerUnavailableError', () async {
      final dir = await repo();
      final fake = _FakeDocker();
      fake.runResults.add(
        const DockerCliResult(
          exitCode: 1,
          stdout: '',
          stderr: 'cannot connect to the daemon',
        ),
      );
      final backend = fake.bind();
      try {
        await expectLater(
          backend.composeProjects([dir.path]),
          throwsA(isA<DockerUnavailableError>()),
        );
      } finally {
        await backend.close();
        await dir.delete(recursive: true);
      }
    });
  });

  group('DockerBackend compose actions', () {
    Future<Directory> repo() async {
      final dir = await Directory.systemTemp.createTemp('oc-compose-act');
      await File('${dir.path}/docker-compose.yml')
          .writeAsString('services: {}\n');
      return dir;
    }

    test('up the whole project', () async {
      final dir = await repo();
      final fake = _FakeDocker();
      final backend = fake.bind();
      try {
        await backend.composeUp(dir.path);
        expect(fake.runArgs.single, const ['compose', 'up', '-d']);
        expect(fake.runWorkingDirs.single, dir.path);
      } finally {
        await backend.close();
        await dir.delete(recursive: true);
      }
    });

    test('up one service', () async {
      final dir = await repo();
      final fake = _FakeDocker();
      final backend = fake.bind();
      try {
        await backend.composeUp(dir.path, services: ['web']);
        expect(fake.runArgs.single, const ['compose', 'up', '-d', 'web']);
      } finally {
        await backend.close();
        await dir.delete(recursive: true);
      }
    });

    test('stop the services', () async {
      final dir = await repo();
      final fake = _FakeDocker();
      final backend = fake.bind();
      try {
        await backend.composeStop(dir.path, services: ['db', 'web']);
        expect(fake.runArgs.single, const ['compose', 'stop', 'db', 'web']);
      } finally {
        await backend.close();
        await dir.delete(recursive: true);
      }
    });

    test(
      'a directory without a compose file is ComposeNotFoundError',
      () async {
        final dir = await Directory.systemTemp.createTemp('oc-compose-none');
        final fake = _FakeDocker();
        final backend = fake.bind();
        try {
          await expectLater(
            backend.composeUp(dir.path),
            throwsA(isA<ComposeNotFoundError>()),
          );
        } finally {
          await backend.close();
          await dir.delete(recursive: true);
        }
      },
    );

    test('a compose failure is DockerUnavailableError', () async {
      final dir = await repo();
      final fake = _FakeDocker();
      fake.runResult = const DockerCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'no such service',
      );
      final backend = fake.bind();
      try {
        await expectLater(
          backend.composeStop(dir.path),
          throwsA(isA<DockerUnavailableError>()),
        );
      } finally {
        await backend.close();
        await dir.delete(recursive: true);
      }
    });
  });
}

/// The directory's basename as the backend derives the compose project name
/// (lower-cased; the temp names are all `[a-z0-9]`, so this is exact).
String _basename(String path) {
  final trimmed = path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
  return trimmed.split('/').last.toLowerCase();
}

final int _pid = Random().nextInt(1 << 30);
