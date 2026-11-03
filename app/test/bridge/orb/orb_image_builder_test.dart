import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/docker/docker_backend.dart';
import 'package:opencodebridge/bridge/orb/orb_build_context.dart';
import 'package:opencodebridge/bridge/orb/orb_image_builder.dart';

/// A scripted docker CLI child.
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

/// The DockerRunner/DockerSpawner seam, scripted.
class _FakeDocker {
  final List<List<String>> runArgs = [];
  final List<List<String>> spawnArgs = [];
  final List<_FakeProcess> spawned = [];
  final List<String> emitted = [];
  final List<DockerCliResult> runResults = [];
  DockerCliResult runResult = const DockerCliResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );

  /// The next children the spawner returns, in order.
  final List<_FakeProcess> processes = [];

  /// The error the next spawn throws (`null` for none).
  Object? spawnError;

  (DockerRunner, DockerSpawner) bind() => (_run, _spawn);

  Future<DockerCliResult> _run(
    List<String> argv, {
    String? workingDirectory,
  }) async {
    runArgs.add(List.of(argv));
    return runResults.isNotEmpty ? runResults.removeAt(0) : runResult;
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
  group('OrbImageBuilder (issue #92)', () {
    late Directory dir;
    late OrbBuildContext context;
    late _FakeDocker docker;
    late String tag;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('oc-orb-build');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    Future<OrbImageBuilder> builderFor(void Function(String)? emit) async {
      context = OrbBuildContext(dir: dir);
      await context.materialize();
      docker = _FakeDocker();
      final (run, spawn) = docker.bind();
      return OrbImageBuilder(
        context: context,
        run: run,
        spawn: spawn,
        emit: emit,
      );
    }

    test('ensureImage builds when the image is missing', () async {
      final builder = await builderFor(null);
      tag = builder.expectedTag;
      // `docker image inspect` of a missing image exits non-zero.
      docker.runResult = const DockerCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Error response from daemon: No such image',
      );
      final child = _FakeProcess();
      docker.processes.add(child);

      final pending = builder.ensureImage();
      await _until(() => docker.spawnArgs.isNotEmpty);
      child.exit(0);

      expect(await pending, tag);
      expect(docker.runArgs, [
        ['image', 'inspect', tag],
      ]);
      expect(docker.spawnArgs, [
        ['build', '-t', tag, dir.path],
      ]);
    });

    test('ensureImage reuses the image when it is present', () async {
      final builder = await builderFor(null);
      tag = builder.expectedTag;
      docker.runResult = const DockerCliResult(
        exitCode: 0,
        stdout: '[]',
        stderr: '',
      );

      expect(await builder.ensureImage(), tag);
      expect(docker.runArgs, [
        ['image', 'inspect', tag],
      ]);
      expect(docker.spawnArgs, isEmpty);
    });

    test('rebuild always builds, even when the image is present', () async {
      final builder = await builderFor(null);
      tag = builder.expectedTag;
      docker.runResult = const DockerCliResult(
        exitCode: 0,
        stdout: '[]',
        stderr: '',
      );
      final child = _FakeProcess();
      docker.processes.add(child);

      final pending = builder.rebuild();
      await _until(() => docker.spawnArgs.isNotEmpty);
      child.exit(0);

      expect(await pending, tag);
      expect(docker.runArgs, isEmpty); // No inspect: a rebuild never probes.
      expect(docker.spawnArgs, [
        ['build', '-t', tag, dir.path],
      ]);
    });

    test('the build logs stream as orb.image.build events', () async {
      final events = <Map<String, Object?>>[];
      final builder = await builderFor(
        (payload) => events.add(jsonDecode(payload) as Map<String, Object?>),
      );
      tag = builder.expectedTag;
      docker.runResult = const DockerCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Error response from daemon: No such image',
      );
      final child = _FakeProcess();
      docker.processes.add(child);

      final pending = builder.ensureImage();
      await _until(() => docker.spawnArgs.isNotEmpty);
      child.stdout.add('Step 1/14 : RUN apt-get update');
      await _until(() => events.length == 1);
      child.stderr.add('warning: something noisy');
      child.exit(0);
      await pending;

      expect(events, hasLength(2));
      for (final event in events) {
        expect(event['type'], 'orb.image.build');
      }
      expect(events[0]['data'], {
        'tag': tag,
        'line': 'Step 1/14 : RUN apt-get update',
      });
      expect(events[1]['data'], {
        'tag': tag,
        'line': 'warning: something noisy',
      });
    });

    test('a non-zero build exit is an OrbImageBuildError', () async {
      final builder = await builderFor(null);
      tag = builder.expectedTag;
      docker.runResult = const DockerCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Error response from daemon: No such image',
      );
      final child = _FakeProcess();
      docker.processes.add(child);

      final pending = builder.ensureImage();
      await _until(() => docker.spawnArgs.isNotEmpty);
      child.stdout.add('step 3/14: some output');
      child.stderr.add('step 3/14: ERROR');
      child.exit(1);

      await expectLater(
        pending,
        throwsA(
          isA<OrbImageBuildError>()
              .having((e) => e.tag, 'tag', tag)
              .having((e) => e.exitCode, 'exitCode', 1),
        ),
      );
    });

    test('a daemon failure on inspect is a DockerUnavailableError', () async {
      final builder = await builderFor(null);
      docker.runResult = const DockerCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Cannot connect to the Docker daemon',
      );

      await expectLater(
        builder.ensureImage(),
        throwsA(isA<DockerUnavailableError>()),
      );
      expect(docker.spawnArgs, isEmpty);
    });

    test('a daemon failure on spawn is a DockerUnavailableError', () async {
      final builder = await builderFor(null);
      tag = builder.expectedTag;
      docker.spawnError = const DockerUnavailableError(
        'Cannot connect to the Docker daemon',
      );

      await expectLater(
        builder.rebuild(),
        throwsA(isA<DockerUnavailableError>()),
      );
      expect(docker.spawnArgs, [
        ['build', '-t', tag, dir.path],
      ]);
    });

    test('without an emit the build output is still drained', () async {
      final builder = await builderFor(null);
      docker.runResult = const DockerCliResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Error response from daemon: No such image',
      );
      final child = _FakeProcess();
      docker.processes.add(child);

      final pending = builder.ensureImage();
      await _until(() => docker.spawnArgs.isNotEmpty);
      child.stdout.add('a lot of build output');
      child.stderr.add('more output');
      child.exit(0);

      expect(await pending, builder.expectedTag);
    });
  });
}
