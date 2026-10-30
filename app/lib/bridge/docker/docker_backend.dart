import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../model/compose_project.dart';
import '../../model/container.dart';
import '../events/bridge_event.dart';

/// The result of one short docker CLI invocation (the list and the
/// start/stop/restart actions).
class DockerCliResult {
  const DockerCliResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Runs one docker CLI argv and waits for it to exit (the short commands).
/// [workingDirectory] is the child's working directory (the `docker compose`
/// commands need it to resolve their compose file); `null` inherits the
/// bridge's, as the plain `docker` commands do.
typedef DockerRunner = Future<DockerCliResult> Function(
  List<String> argv, {
  String? workingDirectory,
});

/// One spawned docker CLI child (the streaming commands: `docker logs`,
/// `docker events`).
class DockerProcess {
  const DockerProcess({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.kill,
  });

  /// The child's stdout, UTF-8 decoded, split into lines.
  final Stream<String> stdout;

  /// The child's stderr, UTF-8 decoded, split into lines.
  final Stream<String> stderr;

  /// Completes with the child's exit code once it exits.
  final Future<int> exitCode;

  /// Terminates the child (best-effort).
  final Future<void> Function() kill;
}

/// Spawns one docker CLI argv as a child (the streaming commands).
/// [workingDirectory] is the child's working directory; `null` inherits the
/// bridge's (the streaming commands never set one).
typedef DockerSpawner = Future<DockerProcess> Function(
  List<String> argv, {
  String? workingDirectory,
});

/// The container does not exist on the host (the docker CLI's `No such
/// container` / `No such object`).
class DockerNotFoundError implements Exception {
  const DockerNotFoundError(this.name);

  final String name;

  @override
  String toString() => 'DockerNotFoundError($name)';
}

/// Docker cannot be reached: the daemon is down, or the docker CLI failed
/// some other way.
class DockerUnavailableError implements Exception {
  const DockerUnavailableError(this.detail);

  final String detail;

  @override
  String toString() => 'DockerUnavailableError($detail)';
}

/// No docker-compose file in the project directory, so the compose project is
/// unknown (a compose action addressed a directory that has no compose file).
class ComposeNotFoundError implements Exception {
  const ComposeNotFoundError(this.detail);

  final String detail;

  @override
  String toString() => 'ComposeNotFoundError($detail)';
}

/// The container's live log stream (issue #21), one CLI child.
class DockerLogStream {
  DockerLogStream._(this._process);

  final DockerProcess _process;

  /// The log lines, one per event, in order.
  Stream<String> get lines => _process.stdout;

  /// The CLI child's exit code (the stream ends when it completes).
  Future<int> get exitCode => _process.exitCode;

  /// Terminates the CLI child (the bridge calls it when the request's client
  /// disconnects).
  Future<void> close() => _process.kill();
}

/// The bridge's Docker backend (issue #21): it shells out to the host docker
/// CLI (ADR-0002, like the terminal-window spawner) and exposes the
/// container list, the name-addressed start/stop/restart actions, the
/// container's log stream, and the host event watch that re-emits
/// `docker.container.stopped` (clean exit) and `docker.container.crashed`
/// (non-zero exit) onto the unified event stream (spec §8).
class DockerBackend {
  DockerBackend({
    required DockerRunner run,
    required DockerSpawner spawn,
    void Function(String)? emit,
    this.reconnectDelay = const Duration(milliseconds: 200),
  }) {
    _run = run;
    _spawn = spawn;
    _emit = emit;
    if (emit != null) {
      // The event watch is the backend's single upstream subscription, like
      // the event hub's opencode one: it runs for the backend's lifetime.
      unawaited(_watchLoop());
    }
  }

  late final DockerRunner _run;
  late final DockerSpawner _spawn;

  /// Where the watched container events go (the event hub's [emit]); `null`
  /// when this machine has no event hub, in which case there is no watch.
  late final void Function(String)? _emit;

  /// How long to wait before re-subscribing the event watch after the
  /// daemon drops it.
  final Duration reconnectDelay;

  bool _closed = false;
  DockerProcess? _watchProcess;

  /// The host backend: the docker CLI resolved on this host's PATH, the
  /// events watched through `docker events` when [emit] is given. Returns
  /// `null` when the host has no docker CLI, in which case the docker
  /// endpoints report `docker_unavailable`.
  static Future<DockerBackend?> host({
    void Function(String)? emit,
    String? path,
  }) async {
    final binary = findHostDocker(path: path);
    if (binary == null) return null;
    return DockerBackend(
      run: (argv, {workingDirectory}) =>
          _hostRun(binary, argv, workingDirectory: workingDirectory),
      spawn: (argv, {workingDirectory}) =>
          _hostSpawn(binary, argv, workingDirectory: workingDirectory),
      emit: emit,
    );
  }

  /// Stop the event watch and release its child.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final process = _watchProcess;
    _watchProcess = null;
    if (process != null) {
      await process.kill();
    }
  }

  /// Every container on the host (issue #21): name, image, state, uptime, in
  /// the docker CLI's order (newest first).
  Future<List<DockerContainer>> list() async {
    final result = await _run(const ['ps', '-a', '--format', '{{json .}}']);
    if (result.exitCode != 0) {
      throw DockerUnavailableError(result.stderr.trim());
    }
    return parseContainerList(result.stdout);
  }

  /// Start the container named [name] (issue #21).
  Future<void> start(String name) => _act(['start', name], name);

  /// Stop the container named [name] (issue #21).
  Future<void> stop(String name) => _act(['stop', name], name);

  /// Restart the container named [name] (issue #21).
  Future<void> restart(String name) => _act(['restart', name], name);

  /// The container's log lines, one per line (issue #21). With [follow] the
  /// stream stays open and keeps yielding the container's new output; without
  /// it, the stream ends after the existing log. The CLI's errors (unknown
  /// container, daemon down) surface as [DockerNotFoundError] /
  /// [DockerUnavailableError] before the first line.
  Future<DockerLogStream> logs(String name, {required bool follow}) async {
    // The preflight is what makes the unknown-container / daemon-down errors
    // a proper 404 / 502 rather than a silently empty stream: `docker logs`
    // itself only fails by exiting (with no stdout) once spawned.
    final probe = await _run(['inspect', '--format', '{{.Id}}', name]);
    if (probe.exitCode != 0) {
      throw _cliError(name, probe.stderr);
    }
    final process = await _spawn(['logs', if (follow) '--follow', name]);
    return DockerLogStream._(process);
  }

  /// The compose files the bridge looks for in a repo root, in priority order
  /// (the first that exists wins).
  static const List<String> composeFileNames = [
    'docker-compose.yml',
    'docker-compose.yaml',
    'compose.yml',
    'compose.yaml',
  ];

  /// The compose file in the directory [dir] (the first of
  /// [composeFileNames] that exists there), or `null` when the directory has
  /// no compose file. A cheap filesystem check, no process.
  static String? findComposeFile(String dir) {
    final base = dir.endsWith('/') ? dir : '$dir/';
    for (final name in composeFileNames) {
      final file = File('$base$name');
      if (file.existsSync()) return file.path;
    }
    return null;
  }

  /// The compose projects among the given repo directories (issue #21 follow-
  /// on): for each [dirs] entry that holds a compose file, the creatable
  /// services (`docker compose config --services`) merged with their live
  /// state (`docker compose ps --all --format json`). Directories without a
  /// compose file are skipped; the result is in [dirs] order.
  Future<List<ComposeProject>> composeProjects(List<String> dirs) async {
    final projects = <ComposeProject>[];
    for (final dir in dirs) {
      final composeFile = DockerBackend.findComposeFile(dir);
      if (composeFile == null) continue;
      final config = await _run([
        'compose',
        'config',
        '--services',
      ], workingDirectory: dir);
      if (config.exitCode != 0) {
        throw DockerUnavailableError(config.stderr.trim());
      }
      final ps = await _run([
        'compose',
        'ps',
        '--all',
        '--format',
        'json',
      ], workingDirectory: dir);
      if (ps.exitCode != 0) {
        throw DockerUnavailableError(ps.stderr.trim());
      }
      projects.add(
        ComposeProject(
          id: ComposeProject.encodeId(dir),
          project: _composeProjectName(dir),
          path: dir,
          composeFile: composeFile,
          services: parseComposeServices(
            configServices: _serviceNames(config.stdout),
            psOutput: ps.stdout,
          ),
        ),
      );
    }
    return projects;
  }

  /// Start (creating if needed) the compose services [services] in the
  /// project [dir] (`docker compose up -d`); `null` starts the whole project.
  Future<void> composeUp(String dir, {List<String>? services}) =>
      _composeAct(dir, ['compose', 'up', '-d', ...?services]);

  /// Stop the compose services [services] in the project [dir] (keeping their
  /// containers, `docker compose stop`); `null` stops the whole project.
  Future<void> composeStop(String dir, {List<String>? services}) =>
      _composeAct(dir, ['compose', 'stop', ...?services]);

  Future<void> _composeAct(String dir, List<String> argv) async {
    if (DockerBackend.findComposeFile(dir) == null) {
      throw ComposeNotFoundError(dir);
    }
    final result = await _run(argv, workingDirectory: dir);
    if (result.exitCode != 0) {
      throw DockerUnavailableError(result.stderr.trim());
    }
  }

  /// The compose project name the docker CLI derives for a directory: the
  /// directory's basename, lower-cased, with characters outside
  /// `[a-z0-9_-]` replaced by `-` (as `docker compose` does).
  static String _composeProjectName(String dir) {
    final trimmed = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
    final base = trimmed.split('/').last;
    return base.toLowerCase().replaceAll(RegExp('[^a-z0-9_-]'), '-');
  }

  Future<void> _act(List<String> argv, String name) async {
    final result = await _run(argv);
    if (result.exitCode != 0) {
      throw _cliError(name, result.stderr);
    }
  }

  Future<void> _watchLoop() async {
    while (!_closed) {
      DockerProcess? process;
      try {
        process = await _spawn([
          'events',
          '--filter',
          'type=container',
          '--format',
          '{{json .}}',
        ]);
        _watchProcess = process;
        await for (final line in process.stdout) {
          if (_closed) break;
          _handleEventLine(line);
        }
      } catch (_) {
        // The spawn failed (no daemon): re-subscribe after the delay.
      }
      _watchProcess = null;
      if (!_closed) {
        await Future<void>.delayed(reconnectDelay);
      }
    }
  }

  /// One `docker events --format '{{json .}}'` line: the `die` of a
  /// container is its exit — clean (exit 0) or crashed (non-zero).
  void _handleEventLine(String line) {
    final emit = _emit;
    if (emit == null) return;
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      return; // A malformed line is not an event.
    }
    if (decoded is! Map<String, Object?>) return;
    if (decoded['Action'] != 'die') return; // Only container exits.
    final actor = decoded['Actor'];
    if (actor is! Map<String, Object?>) return;
    final attributes = actor['Attributes'];
    if (attributes is! Map<String, Object?>) return;
    final name = attributes['name'];
    if (name is! String || name.isEmpty) return;
    final exitCode = _intValue(attributes['exitCode']) ?? 0;
    if (exitCode == 0) {
      emit(
        bridgeEvent(
          type: BridgeEventType.dockerContainerStopped,
          data: {'name': name},
        ),
      );
    } else {
      emit(
        bridgeEvent(
          type: BridgeEventType.dockerContainerCrashed,
          data: {'name': name, 'exitCode': exitCode},
        ),
      );
    }
  }

  /// The docker CLI's error → the typed exception the bridge maps to a 404
  /// or a 502.
  Object _cliError(String name, String stderr) {
    if (stderr.contains('No such container') ||
        stderr.contains('No such object')) {
      return DockerNotFoundError(name);
    }
    return DockerUnavailableError(stderr.trim());
  }

  static int? _intValue(Object? value) => switch (value) {
    num n => n.toInt(),
    String s => int.tryParse(s),
    _ => null,
  };
}

/// Parses the docker CLI's `ps -a --format '{{json .}}'` output (one JSON
/// object per line) into container rows.
List<DockerContainer> parseContainerList(String output) {
  final rows = <DockerContainer>[];
  for (final line in const LineSplitter().convert(output)) {
    if (line.trim().isEmpty) continue;
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      continue; // A malformed line is not a container.
    }
    if (decoded is! Map<String, Object?>) continue;
    rows.add(_parseContainerLine(decoded));
  }
  return rows;
}

/// Merges the creatable service names (from `docker compose config
/// --services`) with their live state (from `docker compose ps --all --format
/// json`, one JSON object per line). A service in [configServices] that is
/// absent from [psOutput] has never been created (its [ComposeService.state]
/// is `null`). The result keeps [configServices] order.
List<ComposeService> parseComposeServices({
  required List<String> configServices,
  required String psOutput,
}) {
  final live = <String, Map<String, Object?>>{};
  for (final line in const LineSplitter().convert(psOutput)) {
    if (line.trim().isEmpty) continue;
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      continue; // A malformed line is not a service.
    }
    if (decoded is! Map<String, Object?>) continue;
    final service = decoded['Service'];
    if (service is String && service.isNotEmpty) live[service] = decoded;
  }
  return [
    for (final name in configServices)
      _composeServiceFromLive(name, live[name]),
  ];
}

/// One service row: [liveState] is the `ps` row when the service is created,
/// `null` when it has never been created.
ComposeService _composeServiceFromLive(
  String name,
  Map<String, Object?>? liveState,
) {
  if (liveState == null) {
    return ComposeService(
      name: name,
      state: null,
      image: null,
      container: null,
    );
  }
  final image = liveState['Image'];
  final container = liveState['Name'];
  return ComposeService(
    name: name,
    state: DockerState.fromWire(liveState['State']),
    image: image is String && image.isNotEmpty ? image : null,
    container: container is String && container.isNotEmpty ? container : null,
  );
}

/// The service names in `docker compose config --services` output (one per
/// line, trimmed, empties dropped).
List<String> _serviceNames(String output) => [
  for (final line in const LineSplitter().convert(output))
    if (line.trim().isNotEmpty) line.trim(),
];

/// One `docker ps` JSON row → the contract row (name, image, state,
/// uptime).
DockerContainer _parseContainerLine(Map<String, Object?> row) {
  // A container can carry several names; the first is its address.
  final rawName = row['Names'] is String ? (row['Names'] as String) : '';
  final name = rawName.split(',').first.trim();
  final runningFor = row['RunningFor'] is String
      ? (row['RunningFor'] as String).trim()
      : '';
  return DockerContainer(
    name: name,
    image: row['Image'] is String ? (row['Image'] as String) : '',
    state: DockerState.fromWire(row['State']),
    uptime: runningFor.isEmpty ? null : runningFor,
  );
}

/// Resolves the docker CLI on this host's PATH, or `null` when it is not
/// found. [path] overrides `PATH` (tests).
String? findHostDocker({String? path}) {
  final pathValue = path ?? Platform.environment['PATH'] ?? '';
  for (final dir in pathValue.split(':')) {
    if (dir.isEmpty) continue;
    try {
      final candidate = File('$dir/docker');
      final stat = candidate.statSync();
      if (stat.type != FileSystemEntityType.file) continue;
      if ((stat.mode & 0x49) == 0) continue; // No exec bit (u/g/o).
      return candidate.path;
    } on FileSystemException {
      // Missing file or broken symlink: not this entry.
      continue;
    }
  }
  return null;
}

Future<DockerCliResult> _hostRun(
  String binary,
  List<String> argv, {
  String? workingDirectory,
}) async {
  final result = await Process.run(
    binary,
    argv,
    workingDirectory: workingDirectory,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  return DockerCliResult(
    exitCode: result.exitCode,
    stdout: result.stdout as String,
    stderr: result.stderr as String,
  );
}

Future<DockerProcess> _hostSpawn(
  String binary,
  List<String> argv, {
  String? workingDirectory,
}) async {
  final process = await Process.start(
    binary,
    argv,
    workingDirectory: workingDirectory,
  );
  return DockerProcess(
    stdout: process.stdout
        .transform(const Utf8Decoder())
        .transform(const LineSplitter()),
    stderr: process.stderr
        .transform(const Utf8Decoder())
        .transform(const LineSplitter()),
    exitCode: process.exitCode,
    kill: () async {
      process.kill(ProcessSignal.sigterm);
    },
  );
}
