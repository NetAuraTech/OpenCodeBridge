import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../tunnel/port_holder.dart';
import '../tunnel/tunnel_supervisor.dart';
import 'opencode_binary.dart';
import 'opencode_cli.dart';
import 'paths.dart';

/// The shared opencode service, or `null` when this machine has none:
/// a failed boot, or a host with no opencode. [owned] is `true` when the
/// app started (or re-attached to) the service — the app stops it on exit —
/// and `false` when it attached to the user's / a TUI's service, which is
/// **never** stopped.
class OpencodeBootResult {
  const OpencodeBootResult({
    this.url,
    this.password,
    this.owned = false,
    this.error,
  });

  /// The service's base URL, e.g. `http://127.0.0.1:4096` — `null` when the
  /// boot did not produce a reachable service.
  final String? url;

  /// The service's Basic-auth password — `null` when there is no service.
  final String? password;

  /// Whether the app owns the service and stops it on exit (cases 2 and 4 of
  /// the resolution order). `false` for an attached user/TUI service (case 3),
  /// which is never stopped.
  final bool owned;

  /// The boot's reason on failure (opencode missing, no free port, boot
  /// timeout); `null` on success.
  final String? error;

  /// Whether the boot produced a reachable, usable service.
  bool get succeeded => error == null && url != null && password != null;
}

/// Resolves the opencode CLI for the host service boot (issue #153).
typedef OpencodeCliResolver = Future<String?> Function();

/// Spawns the opencode child with the given argv (stdout/stderr piped, for
/// draining).
typedef OpencodeSpawner = Future<OpencodeChild> Function(List<String> argv);

/// An authenticated Basic `GET /api/session` (`opencode:<password>`):
/// `true` when the service answers.
typedef OpencodeServiceProbe = Future<bool> Function(Uri url, String password);

/// Whether the process [pid] is the opencode service (the app's child), for
/// the case-2 stop: the port's current holder must be checked before it is
/// signalled (the port may have been re-assigned since the attach).
typedef OpencodeProcessIdentity = bool Function(int pid);

/// The host opencode CLI resolver (issue #153): `OPENCODE_CLI` when set, else
/// `opencode` on the PATH (the existing [findHostOpencode]), else the
/// app-managed pinned install ([OpencodeBinary], the ADR-0002 app-owned
/// binary pattern). `null` when none of the three is available.
Future<String?> resolveHostOpencodeCli({
  Map<String, String>? environment,
  Future<File> Function()? appManaged,
}) async {
  final env = environment ?? Platform.environment;
  final override = env['OPENCODE_CLI'];
  if (override != null && override.trim().isNotEmpty) return override;
  final onPath = findHostOpencode(path: env['PATH']);
  if (onPath != null) return onPath;
  try {
    return (await (appManaged?.call() ?? OpencodeBinary().ensure())).path;
  } catch (_) {
    // The app-managed download failed (no network): no CLI at all.
    return null;
  }
}

/// Boots the host's shared opencode service (issue #153, ADR-0002/ADR-0008):
/// server mode is the app's on-switch, so the app turns opencode on.
///
/// Resolution, in order (cases 2/3 never spawn — an already-running service
/// is always attached to, never replaced):
///  1. a service this app instance already started → reuse it (idempotent);
///  2. a service started by a previous app instance and still alive (the
///     marker, `{url, password}`) → **attach**, it stays the app's (stopped
///     on exit); a stale marker (previous child gone) is removed and
///     resolution continues;
///  3. an existing `service.json` whose service answers an authenticated
///     `GET /api/session` → **attach** and **never** stop it (the user's or a
///     TUI's service);
///  4. otherwise → run `opencode serve --hostname 127.0.0.1 --port <port>`,
///     wait [startTimeout] for the descriptor to be written and the service
///     to answer, mark the service as the app's, then return.
///
/// The child's stdout/stderr are always drained (an undrained pipe would
/// stall the service).
class OpencodeServiceBooter {
  OpencodeServiceBooter({
    this._cli = resolveHostOpencodeCli,
    this._spawner = hostSpawnOpencode,
    this._kill = hostKillPid,
    this._pidAlive = hostPidAlive,
    this._portHolder = portHolderProbe,
    this._isPortFree = hostPortFree,
    this._serviceProbe = probeOpencodeService,
    this._processIsOpencode = isOpencodeProcess,
    this.startTimeout = const Duration(seconds: 20),
    this.killGrace = const Duration(seconds: 5),
    this.portBase = 4096,
    this.portRange = 20,
    File? marker,
    File? descriptor,
    this.emit,
  }) : _markerFile = marker ?? markerFile(),
       _descriptorFile = descriptor ?? descriptorFile();

  /// The app's ownership marker (written while the app owns the service,
  /// deleted on stop): `{url, password}`.
  static File markerFile() => File(
    '${homeDirectory()}/.local/state/opencode/opencodebridge-child.json',
  );

  /// The shared-service descriptor the bridge reads (`~/.local/state/opencode/`
  /// `service.json`): `{url, password}`.
  static File descriptorFile() =>
      File('${homeDirectory()}/.local/state/opencode/service.json');

  /// Resolves the opencode CLI (issue #153).
  final OpencodeCliResolver _cli;

  /// Spawns the child with the given argv (stdout/stderr piped for draining).
  final OpencodeSpawner _spawner;

  /// Sends [signal] to [pid]; `true` when a process was signalled (the host
  /// default is the tunnel supervisor's [hostKillPid]).
  final Future<bool> Function(int pid, ProcessSignal signal) _kill;

  /// Whether the process [pid] is alive (the host default is the tunnel
  /// supervisor's [hostPidAlive]).
  final bool Function(int pid) _pidAlive;

  /// Resolves who listens on [port], or `null` when nothing does.
  final PortHolderProbe _portHolder;

  /// Whether [port] is free to bind on loopback.
  final Future<bool> Function(int port) _isPortFree;

  /// An authenticated Basic `GET /api/session` (`opencode:<password>`):
  /// `true` when the service answers.
  final OpencodeServiceProbe _serviceProbe;

  /// Whether [pid] is the opencode service (the case-2 stop checks the
  /// port's current holder is the app's child before signalling it).
  final OpencodeProcessIdentity _processIsOpencode;

  /// How long to wait for the spawned service to write its descriptor and
  /// answer.
  final Duration startTimeout;

  /// The grace between the SIGTERM and the SIGKILL on stop.
  final Duration killGrace;

  /// The base port a spawned service tries first (opencode's default).
  final int portBase;

  /// The bounded increment tried while the base port is taken.
  final int portRange;

  /// The app's ownership marker.
  final File _markerFile;

  /// The shared-service descriptor.
  final File _descriptorFile;

  /// Boot-log lines (the child's stdout/stderr), forwarded to the unified
  /// event stream once the bridge has built it (the "log surface"). Set by
  /// the bridge after the event hub exists (the boot runs before it).
  void Function(String)? emit;

  final List<String> _bootLog = [];

  OpencodeBootResult? _result;

  /// The child this instance spawned (case 4); `null` when the service was
  /// attached to (cases 2/3) or none was started.
  OpencodeChild? _child;

  /// The boot log (the child's stdout/stderr), most recent last.
  List<String> get bootLog => List.unmodifiable(_bootLog);

  /// The resolved outcome once [start] has run, or `null` before that.
  OpencodeBootResult? get result => _result;

  /// Resolves (and, when needed, spawns) the shared opencode service.
  /// Idempotent: a second call returns the instance's own result.
  Future<OpencodeBootResult> start() async {
    final existing = _result;
    if (existing != null) return existing;
    final resolved = await _resolve();
    _result = resolved;
    return resolved;
  }

  Future<OpencodeBootResult> _resolve() async {
    // Case 1 (already started) is the idempotency guard in [start].

    // Case 2: a previous instance's child still alive (the marker). Attach,
    // and it stays the app's (stopped on exit). A stale marker (previous
    // child gone) is removed and resolution continues.
    final marker = _read(_markerFile);
    if (marker != null) {
      if (await _serviceProbe(Uri.parse(marker.$1), marker.$2)) {
        _log('[opencode] attached to the app-owned service at ${marker.$1}');
        return OpencodeBootResult(
          url: marker.$1,
          password: marker.$2,
          owned: true,
        );
      }
      // Stale marker: the previous child is gone. Remove it and continue.
      await _remove(_markerFile);
      _log('[opencode] removed the stale ownership marker');
    }

    // Case 3: an existing descriptor whose service answers (the user's or a
    // TUI's service). Attach, and never stop it on exit. One bounded re-check
    // absorbs a transient probe failure (the probe times out after 3 s on a
    // busy host): without it, a blip would fall through to case 4 and spawn a
    // second service over the user's, whose descriptor it would then replace.
    final descriptor = _read(_descriptorFile);
    if (descriptor != null) {
      final (url, password) = descriptor;
      if (await _serviceProbe(Uri.parse(url), password) ||
          await _serviceProbe(Uri.parse(url), password)) {
        _log('[opencode] attached to the running service at $url');
        return OpencodeBootResult(url: url, password: password, owned: false);
      }
    }

    // Case 4: nothing reachable — the app starts the service itself.
    return _spawn();
  }

  /// The case-4 spawn: run `opencode serve` on a free port, wait for the
  /// descriptor to be written and the service to answer, mark it the app's.
  /// Any failure stops the (just-spawned) child and leaves the bridge
  /// degraded (no descriptor → `opencode_unavailable`), never the app.
  Future<OpencodeBootResult> _spawn() async {
    final binary = await _cli();
    if (binary == null) {
      return _failed(
        'no opencode CLI is available (OPENCODE_CLI, PATH, '
        'or the app-managed install)',
      );
    }
    final port = await _resolvePort();
    final argv = [
      binary,
      'serve',
      '--hostname',
      '127.0.0.1',
      '--port',
      '$port',
    ];
    _log('[opencode] starting opencode serve on port $port');
    OpencodeChild child;
    try {
      child = await _spawner(argv);
    } catch (e) {
      return _failed('could not start opencode serve: $e');
    }
    _child = child;

    // Drain stdout/stderr unconditionally (an undrained pipe would stall the
    // service); the lines are the boot log.
    unawaited(_drain(child));

    // Wait [startTimeout] for the descriptor to be written AND the service
    // to answer: the `server listening on …` + `server password …` lines
    // appear on stdout, then the descriptor is written, then the probe
    // (Basic-auth `GET /api/session`) must answer.
    final deadline = DateTime.now().add(startTimeout);
    String? url;
    String? password;
    while (true) {
      if (DateTime.now().isAfter(deadline)) {
        await _stopChild(child);
        return _failed('opencode did not answer within $startTimeout');
      }
      final (seenUrl, seenPassword) = _bootCredentials(_bootLog);
      url ??= seenUrl;
      password ??= seenPassword;
      if (url != null &&
          password != null &&
          await _serviceProbe(Uri.parse(url), password)) {
        // The service answers: now — and only now — write the descriptor the
        // bridge reads (a directly-invoked `opencode serve` writes none —
        // issue #83) and the app's ownership marker. A failed boot writes
        // neither, so it leaves nothing to clean up.
        await _write(_descriptorFile, url, password);
        await _write(_markerFile, url, password);
        _log('[opencode] service ready at $url');
        return OpencodeBootResult(url: url, password: password, owned: true);
      }
      if (!_childAlive(child)) {
        await _stopChild(child);
        return _failed(
          'opencode exited during boot'
          '${_tail(_bootLog)}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  /// Terminates the service the app owns (cases 2 and 4 of [start]), then
  /// removes the app's files. A service attached to in case 3 is **never**
  /// touched.
  Future<void> stop() async {
    final resolved = _result;
    if (resolved == null || !resolved.owned) return;
    final child = _child;
    if (child != null) {
      // Case 4: the child this instance spawned (it holds the process).
      await _stopChild(child);
      _child = null;
    } else if (resolved.url != null) {
      // Case 2: a previous instance's child, re-attached — resolve its pid
      // from the port and stop it.
      await _stopByPort(resolved.url!);
    }
    await _remove(_markerFile);
    // The descriptor is the app's only when it points at the owned service
    // (never delete a concurrently-owned descriptor).
    final descriptor = _read(_descriptorFile);
    if (descriptor != null && descriptor.$1 == resolved.url) {
      await _remove(_descriptorFile);
    }
    _log('[opencode] stopped the app-owned service');
  }

  OpencodeBootResult _failed(String reason) {
    _log('[opencode] boot failed: $reason');
    final result = OpencodeBootResult(error: reason);
    _result = result;
    return result;
  }

  /// The boot log tail (at most [max] lines) for a failure message.
  String _tail(List<String> lines, {int max = 3}) {
    if (lines.isEmpty) return '';
    final tail = lines.length > max ? lines.sublist(lines.length - max) : lines;
    return ' — last lines: ${tail.join(' | ')}';
  }

  /// Chooses the port a spawned service binds: the base port (opencode's
  /// default, or the port of a stale descriptor when one is present),
  /// incrementing while it is taken, bounded by [portRange].
  Future<int> _resolvePort() async {
    int base = portBase;
    final descriptor = _read(_descriptorFile);
    if (descriptor != null) {
      final port = Uri.tryParse(descriptor.$1)?.port;
      if (port != null && port > 0 && port <= 65535) base = port;
    }
    for (var candidate = base; candidate < base + portRange; candidate++) {
      if (await _isPortFree(candidate)) return candidate;
    }
    return base; // All taken: let the spawn surface the conflict.
  }

  /// The `server listening on <url>` + `server password <pw>` pair parsed
  /// from the boot log (the most recent of each), or `null`s when either is
  /// not there yet.
  (String?, String?) _bootCredentials(List<String> lines) {
    String? url;
    String? password;
    for (final line in lines) {
      final listening = _parseListening(line);
      if (listening != null) url = listening;
      final pw = _parsePassword(line);
      if (pw != null) password = pw;
    }
    return (url, password);
  }

  static String? _parseListening(String line) {
    final match = RegExp(r'server listening on (https?://\S+)')
        .firstMatch(line.trim());
    return match?.group(1);
  }

  static String? _parsePassword(String line) {
    final match = RegExp(r'server password (\S+)').firstMatch(line.trim());
    return match?.group(1);
  }

  /// Whether the spawned child is still alive (the poll loop uses it to fail
  /// a boot that exited early, before the full [startTimeout]).
  bool _childAlive(OpencodeChild child) => _pidAlive(child.pid);

  /// Drains the child's stdout/stderr into [bootLog] (and [emit], when set),
  /// unconditionally — a full pipe would stall the service.
  Future<void> _drain(OpencodeChild child) async {
    void sink(String line) {
      line = line.trim();
      if (line.isEmpty) return;
      _bootLog.add(line);
      emit?.call(line);
    }

    try {
      await Future.wait<void>([
        child.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(sink, onError: (Object _) {})
            .asFuture(),
        child.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(sink, onError: (Object _) {})
            .asFuture(),
      ]);
    } catch (_) {
      // The streams closed (the child exited); the log is what it is.
    }
  }

  /// Terminates a spawned child: SIGTERM, then SIGKILL after [killGrace].
  Future<void> _stopChild(OpencodeChild child) async {
    try {
      child.kill();
    } catch (_) {
      // The child is probably gone already.
    }
    try {
      await child.exitCode.timeout(killGrace);
    } on TimeoutException {
      try {
        await _kill(child.pid, ProcessSignal.sigkill);
      } catch (_) {
        // Nothing else to do.
      }
    } catch (_) {
      // The exit reported an error; nothing left to terminate.
    }
  }

  /// Stops a re-attached (case-2) service by resolving its pid from the port
  /// it answers on — and only when that pid is still the opencode service
  /// (the port may have been re-assigned since the attach; a foreign holder
  /// is never signalled) — SIGTERM, then SIGKILL after [killGrace].
  Future<void> _stopByPort(String url) async {
    final port = Uri.tryParse(url)?.port;
    if (port == null) return;
    PortHolder? holder;
    try {
      holder = await _portHolder(port);
    } catch (_) {
      holder = null;
    }
    if (holder == null || !_processIsOpencode(holder.pid)) return;
    try {
      await _kill(holder.pid, ProcessSignal.sigterm);
    } catch (_) {
      return;
    }
    final deadline = DateTime.now().add(killGrace);
    while (_pidAlive(holder.pid) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_pidAlive(holder.pid)) {
      try {
        await _kill(holder.pid, ProcessSignal.sigkill);
      } catch (_) {
        // Nothing else to do.
      }
    }
  }

  void _log(String line) {
    _bootLog.add(line);
    emit?.call(line);
  }

  (String url, String password)? _read(File file) {
    try {
      final raw = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final url = raw['url'];
      final password = raw['password'];
      if (url is String && url.isNotEmpty && password is String) {
        return (url, password);
      }
    } catch (_) {
      // Missing or malformed file: treat as absent.
    }
    return null;
  }

  Future<void> _write(File file, String url, String password) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'url': url, 'password': password}));
  }

  Future<void> _remove(File file) async {
    try {
      await file.delete();
    } catch (_) {
      // Already gone.
    }
  }
}

/// A live opencode child process. `dart:io`'s [Process] satisfies this
/// through [_IoProcess]; tests inject a fake.
abstract class OpencodeChild {
  /// The child's pid.
  int get pid;

  /// Completes with the exit code when the child exits.
  Future<int> get exitCode;

  /// The child's stdout (drained by the booter).
  Stream<List<int>> get stdout;

  /// The child's stderr (drained by the booter).
  Stream<List<int>> get stderr;

  /// Terminates the child (SIGTERM); `true` when the signal was delivered.
  bool kill();
}

/// Adapts a `dart:io` [Process] to [OpencodeChild].
class _IoProcess implements OpencodeChild {
  _IoProcess(this._process);

  final Process _process;

  @override
  int get pid => _process.pid;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  bool kill() => _process.kill();
}

/// Spawns the opencode child on the host with `Process.start`.
Future<OpencodeChild> hostSpawnOpencode(List<String> argv) async {
  final process = await Process.start(argv.first, argv.sublist(1));
  return ioProcessAdapter(process);
}

/// Adapts a `dart:io` [Process] to [OpencodeChild] (public so a caller —
/// including a test that boots the real CLI in an isolated environment — can
/// wrap a child it spawned itself).
OpencodeChild ioProcessAdapter(Process process) => _IoProcess(process);

/// Whether [pid] is an opencode process (the case-2 stop's identity check):
/// argv[0] named `opencode` (a host install or the app-managed binary).
bool isOpencodeProcess(int pid) {
  if (!Platform.isLinux) return false;
  try {
    final cmdline = File('$procPath$pid/cmdline').readAsStringSync();
    final first = cmdline.split('\x00').first;
    if (first.isEmpty) return false;
    final base = first.split('/').last;
    return base == 'opencode' || base.startsWith('opencode-');
  } catch (_) {
    return false;
  }
}

/// Whether [port] can be bound on loopback (nothing holds it).
Future<bool> hostPortFree(int port) async {
  try {
    final socket = await ServerSocket.bind('127.0.0.1', port);
    await socket.close();
    return true;
  } catch (_) {
    return false;
  }
}

/// The authenticated Basic `GET /api/session` (`opencode:<password>`): `true`
/// when the service answers, `false` on any error (refused, 401, timeout).
Future<bool> probeOpencodeService(Uri url, String password) async {
  final client = HttpClient();
  try {
    final request = await client
        .getUrl(url.replace(path: '/api/session'))
        .timeout(const Duration(seconds: 3));
    request.headers.set(
      'Authorization',
      'Basic ${base64Encode(utf8.encode('opencode:$password'))}',
    );
    final response = await request.close().timeout(const Duration(seconds: 3));
    await response.drain<void>();
    return response.statusCode == HttpStatus.ok;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}
