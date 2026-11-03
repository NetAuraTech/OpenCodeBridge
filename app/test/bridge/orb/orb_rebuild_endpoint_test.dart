import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/bridge_server.dart';
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
  final List<List<String>> spawnArgs = [];
  final List<_FakeProcess> spawned = [];

  /// The next children the spawner returns, in order.
  final List<_FakeProcess> processes = [];

  /// The error the next spawn throws (`null` for none).
  Object? spawnError;

  (DockerRunner, DockerSpawner) bind() => (
    (argv, {workingDirectory}) async {
      throw StateError('no run expected');
    },
    _spawn,
  );

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

Future<(int, String)> _get(Uri base, String path) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(base.replace(path: path));
    final response = await request.close();
    final body = await response.transform(const Utf8Decoder()).join();
    return (response.statusCode, body);
  } finally {
    client.close(force: true);
  }
}

Future<(int, String)> _postRaw(Uri base, String path, String body) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(base.replace(path: path));
    request.headers.contentType = ContentType.json;
    if (body.isNotEmpty) {
      request.write(body);
    }
    final response = await request.close();
    final raw = await response.transform(const Utf8Decoder()).join();
    return (response.statusCode, raw);
  } finally {
    client.close(force: true);
  }
}

/// On a host with the docker CLI on PATH the bridge default builds a real
/// orb builder, so the 503 path is not observable there: the test marks
/// itself skipped and returns true.
bool _hostHasDockerCli() {
  if (findHostDocker() != null) {
    markTestSkipped(
      'the host has a docker CLI on PATH, so the bridge default builds a '
      'real orb builder',
    );
    return true;
  }
  return false;
}

void main() {
  group('POST /api/orb/image/rebuild (issue #92)', () {
    late Directory dir;
    late OrbBuildContext context;
    late _FakeDocker docker;
    late BridgeServer server;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('oc-orb-endpoint');
      context = OrbBuildContext(dir: dir);
      await context.materialize();
      docker = _FakeDocker();
    });

    tearDown(() async {
      await server.stop();
      await dir.delete(recursive: true);
    });

    Future<BridgeServer> start({OrbImageBuilder? orb}) async {
      server = orb == null
          ? await BridgeServer.start(port: 0)
          : await BridgeServer.start(port: 0, orb: orb);
      return server;
    }

    OrbImageBuilder builder() {
      final (run, spawn) = docker.bind();
      return OrbImageBuilder(context: context, run: run, spawn: spawn);
    }

    test('200 with the tag when the build succeeds', () async {
      final child = _FakeProcess();
      docker.processes.add(child);
      await start(orb: builder());

      final pending = _postRaw(server.baseUri, 'api/orb/image/rebuild', '');
      await _until(() => docker.spawnArgs.isNotEmpty);
      child.exit(0);
      final (status, body) = await pending;

      expect(status, 200);
      expect(jsonDecode(body), {'tag': context.expectedTag()});
      expect(docker.spawnArgs, [
        ['build', '-t', context.expectedTag(), dir.path],
      ]);
    });

    test('a failed build is 502 docker_build_failed', () async {
      final child = _FakeProcess();
      docker.processes.add(child);
      await start(orb: builder());

      final pending = _postRaw(server.baseUri, 'api/orb/image/rebuild', '');
      await _until(() => docker.spawnArgs.isNotEmpty);
      child.exit(1);
      final (status, body) = await pending;

      expect(status, 502);
      expect(jsonDecode(body), {'error': 'docker_build_failed'});
    });

    test('a daemon failure is 502 docker_unreachable', () async {
      docker.spawnError = const DockerUnavailableError(
        'Cannot connect to the Docker daemon',
      );
      await start(orb: builder());

      final (status, body) = await _postRaw(
        server.baseUri,
        'api/orb/image/rebuild',
        '',
      );

      expect(status, 502);
      expect(jsonDecode(body), {'error': 'docker_unreachable'});
    });

    test('503 docker_unavailable when the host has no docker CLI', () async {
      if (_hostHasDockerCli()) return;
      await start();

      final (status, body) = await _postRaw(
        server.baseUri,
        'api/orb/image/rebuild',
        '',
      );

      expect(status, 503);
      expect(jsonDecode(body), {'error': 'docker_unavailable'});
    });

    test('GET is not the rebuild route', () async {
      await start(orb: builder());

      final (status, _) = await _get(server.baseUri, 'api/orb/image/rebuild');

      expect(status, 404);
      expect(docker.spawnArgs, isEmpty);
    });
  });
}
