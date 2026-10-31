import 'dart:async';
import 'dart:io';

import '../../model/tunnel_report.dart';
import 'cloudflared_binary.dart';
import 'cloudflared_config.dart';
import 'port_holder.dart';
import 'tunnel_metrics.dart';
import 'tunnel_preconditions.dart';

/// The child's metrics port: the primary port, and the fallback port used
/// when the primary is held by a process that is not cloudflared
/// (orphan handling, ADR-0002).
const int kPrimaryMetricsPort = 20241;
const int kFallbackMetricsPort = 20242;

/// A live child process. `Process` from `dart:io` satisfies this (its
/// `kill()` is the SIGTERM of the supervised lifecycle).
abstract class TunnelProcess {
  /// The pid of the child.
  int get pid;

  /// Completes with the exit code when the child exits.
  Future<int> get exitCode;

  /// Terminates the child (SIGTERM); true when the signal was delivered.
  bool kill();
}

/// Spawns the child with the given argv.
typedef ProcessSpawner = Future<TunnelProcess> Function(List<String> argv);

/// Sends [signal] to [pid]; true when a process was signalled.
typedef ProcessKiller = Future<bool> Function(int pid, ProcessSignal signal);

/// Whether the process [pid] is alive.
typedef PidAlive = bool Function(int pid);

/// Scrapes the child's metrics on [port] and returns the registered edge
/// connections, `null` when the endpoint cannot be scraped.
typedef MetricsScraper = Future<int?> Function(int port);

/// Sends a signal to the pid on the host.
Future<bool> hostKillPid(int pid, ProcessSignal signal) async {
  if (!Platform.isLinux) return false;
  try {
    return Process.killPid(pid, signal);
  } catch (_) {
    return false;
  }
}

/// Whether the process [pid] is alive on the host.
bool hostPidAlive(int pid) {
  if (!Platform.isLinux) return false;
  return Directory('$procPath$pid').existsSync();
}

/// Scrapes `cloudflared_tunnel_ha_connections` from the metrics endpoint on
/// [port].
Future<int?> scrapeRegisteredConnections(int port) async {
  final client = HttpClient();
  try {
    final request = await client
        .getUrl(Uri.parse('http://127.0.0.1:$port/metrics'))
        .timeout(const Duration(seconds: 2));
    final response = await request.close().timeout(const Duration(seconds: 2));
    final body = await response
        .transform(const SystemEncoding().decoder)
        .join();
    return parseRegisteredConnections(body);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Adapts a `dart:io` [Process] to [TunnelProcess] (Dart is nominal-typed,
/// so `Process` is not a `TunnelProcess` on its own).
class _ProcessAdapter implements TunnelProcess {
  _ProcessAdapter(this._process);

  final Process _process;

  @override
  int get pid => _process.pid;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  bool kill() => _process.kill();
}

/// Spawns the child on the host with `Process.start`.
Future<TunnelProcess> hostSpawnProcess(List<String> argv) async {
  final process = await Process.start(argv.first, argv.sublist(1));
  return _ProcessAdapter(process);
}

/// Supervises the cloudflared child (issue #22, ADR-0002): spawns it with
/// the app-owned config, handles the orphaned tunnel, auto-respawns with a
/// cap, and reports the tunnel health.
class TunnelSupervisor {
  TunnelSupervisor({
    required this._binary,
    required this._configFile,
    this.preconditions,
    this._spawner = hostSpawnProcess,
    this._kill = hostKillPid,
    this._pidAlive = hostPidAlive,
    this._scrape = scrapeRegisteredConnections,
    this._portHolder = portHolderProbe,
    this.killGrace = const Duration(seconds: 5),
    this.respawnCap = 3,
    this.respawnWindow = const Duration(seconds: 60),
    this.connectTimeout = const Duration(seconds: 10),
  });

  /// The app-managed cloudflared binary.
  final CloudflaredBinary _binary;

  /// The app-owned tunnel config.
  final CloudflaredConfigFile _configFile;

  final ProcessSpawner _spawner;
  final ProcessKiller _kill;
  final PidAlive _pidAlive;
  final MetricsScraper _scrape;
  final PortHolderProbe _portHolder;

  /// The grace period between the SIGTERM and the SIGKILL on stop.
  final Duration killGrace;

  /// The auto-respawn cap: at most [respawnCap] respawns within
  /// [respawnWindow].
  final int respawnCap;

  /// The sliding window for the auto-respawn cap.
  final Duration respawnWindow;

  /// How long the recheck / assisted-setup actions wait for a freshly
  /// (re)started child to hold edge connections, so their report already
  /// shows the connected tunnel (issue #34).
  final Duration connectTimeout;

  /// The precondition checker for the missing-steps report; `null` means
  /// the caller guarantees the preconditions (tests).
  final TunnelPreconditionChecker? preconditions;

  TunnelProcess? _child;
  int? _metricsPort;
  bool _active = false;
  bool _stopping = false;
  bool _respawnCapExhausted = false;
  final List<DateTime> _respawnTimes = [];
  PreconditionResult? _lastCheck;
  ParsedCloudflaredConfig? _lastConfig;
  String? _binaryError;

  /// Whether the supervisor is running (between `start` and `stop`).
  bool get active => _active;

  /// The metrics port of the running child, `null` when no child runs.
  int? get metricsPort => _child != null ? _metricsPort : null;

  /// Runs the precondition pass and, when every precondition is met, spawns
  /// the child.
  Future<void> start() async {
    if (_active) return;
    _active = true;
    _stopping = false;
    _respawnCapExhausted = false;
    _respawnTimes.clear();
    _binaryError = null;
    await _refreshCheck();
    if (_lastCheck == null || _lastCheck!.allMet) {
      await _spawn();
    }
  }

  /// Re-runs the precondition pass (the `POST /api/tunnel/check` action) and
  /// returns the result, `null` when no checker was given. When every step
  /// is met and no child runs, the child is spawned: the guided-setup
  /// recheck brings the tunnel up once every step is done (issue #34),
  /// waiting up to [connectTimeout] for the fresh child's edge connections
  /// so the answer already shows the connected tunnel.
  Future<PreconditionResult?> check() async {
    final preconditions = this.preconditions;
    if (preconditions == null) return null;
    _binaryError = null;
    _lastCheck = await preconditions.check();
    _lastConfig = _lastCheck!.config;
    if (_lastCheck!.allMet && _child == null) {
      _active = true;
      await _spawn();
      await _awaitEdgeConnections();
    }
    return _lastCheck;
  }

  /// The assisted-setup completion (issue #34): the setup service has just
  /// written the app-owned files. Re-runs the precondition pass and, when
  /// every step is met, (re)starts the child so it runs the fresh files
  /// (waiting up to [connectTimeout] for its edge connections). When a step
  /// is still missing, the child is left untouched.
  Future<PreconditionResult?> applySetup() async {
    final preconditions = this.preconditions;
    if (preconditions == null) return null;
    _binaryError = null;
    _lastCheck = await preconditions.check();
    _lastConfig = _lastCheck!.config;
    if (_lastCheck!.allMet) {
      await _killChild();
      _respawnCapExhausted = false;
      _respawnTimes.clear();
      _active = true;
      await _spawn();
      await _awaitEdgeConnections();
    }
    return _lastCheck;
  }

  Future<void> _refreshCheck() async {
    final preconditions = this.preconditions;
    if (preconditions == null) {
      _lastCheck = null;
      return;
    }
    try {
      _lastCheck = await preconditions.check();
      _lastConfig = _lastCheck!.config;
    } catch (_) {
      _lastCheck = null;
    }
  }

  /// Manual restart, for the user after the capped auto-respawn was
  /// exhausted: re-runs the precondition pass and respawns.
  Future<void> restart() async {
    await _killChild();
    _respawnCapExhausted = false;
    _respawnTimes.clear();
    _binaryError = null;
    _active = true;
    await _refreshCheck();
    if (_lastCheck == null || _lastCheck!.allMet) {
      await _spawn();
    }
  }

  /// Terminates the running child (if any) without touching the auto-respawn
  /// bookkeeping: [restart] and [applySetup] share it.
  Future<void> _killChild() async {
    final child = _child;
    _child = null;
    _stopping = true;
    if (child != null) {
      try {
        child.kill();
      } catch (_) {
        // The child is probably gone already.
      }
    }
    _stopping = false;
  }

  /// Waits for the freshly (re)started child to hold edge connections,
  /// bounded by [connectTimeout] (issue #34): the recheck / assisted-setup
  /// answers carry the connected state, not a just-spawned child.
  Future<void> _awaitEdgeConnections() async {
    final child = _child;
    final port = _metricsPort;
    if (child == null || port == null) return;
    final deadline = DateTime.now().add(connectTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!(_pidAlive(child.pid))) return;
      final connections = await _scrape(port);
      if (connections != null && connections > 0) return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  /// Terminates the child: SIGTERM, then SIGKILL after [killGrace].
  Future<void> stop() async {
    _active = false;
    final child = _child;
    _child = null;
    _stopping = true;
    if (child != null) {
      try {
        child.kill();
      } catch (_) {
        // The child is probably gone already.
      }
      // Wait up to [killGrace] for the child to exit; escalate to SIGKILL
      // when it ignores the SIGTERM.
      try {
        await child.exitCode.timeout(killGrace);
      } on TimeoutException {
        try {
          await _kill(child.pid, ProcessSignal.sigkill);
        } catch (_) {
          // Nothing else to do.
        }
      } catch (_) {
        // The child's exit reported an error; nothing left to terminate.
      }
    }
    _stopping = false;
    _metricsPort = null;
  }

  Future<void> _spawn() async {
    final config = _configFile.read();
    if (config == null) return;
    _lastConfig = config;
    File binary;
    try {
      binary = await _binary.ensure();
      _binaryError = null;
    } catch (e) {
      _binaryError = 'the cloudflared binary could not be installed: $e';
      return;
    }
    final port = await _resolveMetricsPort();
    final argv = [
      binary.path,
      'tunnel',
      'run',
      config.tunnel,
      '--config',
      _configFile.file.path,
      '--no-autoupdate',
      '--metrics',
      '127.0.0.1:$port',
    ];
    try {
      final child = await _spawner(argv);
      _child = child;
      _metricsPort = port;
      unawaited(child.exitCode.then(_onChildExit));
    } catch (_) {
      _child = null;
    }
  }

  /// Chooses the child's metrics port: the primary port, after terminating
  /// a cloudflared orphan holding it; the fallback port when something that
  /// is not cloudflared holds it.
  Future<int> _resolveMetricsPort() async {
    PortHolder? holder;
    try {
      holder = await _portHolder(kPrimaryMetricsPort);
    } catch (_) {
      holder = null;
    }
    if (holder == null) return kPrimaryMetricsPort;
    if (!holder.isCloudflared) return kFallbackMetricsPort;
    await _killOrphan(holder.pid);
    return kPrimaryMetricsPort;
  }

  /// Terminates the orphan: SIGTERM, then SIGKILL after [killGrace].
  Future<void> _killOrphan(int pid) async {
    try {
      await _kill(pid, ProcessSignal.sigterm);
    } catch (_) {
      return;
    }
    final deadline = DateTime.now().add(killGrace);
    while (_pidAlive(pid) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_pidAlive(pid)) {
      try {
        await _kill(pid, ProcessSignal.sigkill);
      } catch (_) {
        // Nothing else to do.
      }
    }
  }

  Future<void> _onChildExit(int exitCode) async {
    final exited = _child;
    if (exited == null || !identical(exited, _child)) return;
    _child = null;
    _metricsPort = null;
    if (!_active || _stopping) return;
    // Capped auto-respawn: at most [respawnCap] respawns within the
    // sliding [respawnWindow]; after that the tunnel stays down until the
    // user restarts it manually.
    final now = DateTime.now();
    final windowStart = now.subtract(respawnWindow);
    _respawnTimes.removeWhere((time) => time.isBefore(windowStart));
    if (_respawnTimes.length >= respawnCap) {
      _respawnCapExhausted = true;
      return;
    }
    _respawnTimes.add(now);
    await _spawn();
  }

  /// The current tunnel report. The health definition: `up` is the child
  /// running *and* holding registered connections to the edge; anything
  /// else is `down` (with the missing steps when the setup is incomplete).
  Future<TunnelReport> report() async {
    var running = false;
    if (_active && _child != null) {
      running = _pidAlive(_child!.pid);
      if (!running) {
        _child = null;
        _metricsPort = null;
      }
    }
    var connections = 0;
    if (running && _metricsPort != null) {
      connections = await _scrape(_metricsPort!) ?? 0;
    }
    final missing = <String>[];
    final details = <String>[];
    final check = _lastCheck;
    if (check != null) {
      for (final step in check.missing) {
        missing.add(step.id);
        details.add(step.message);
      }
    }
    if (_binaryError != null && !missing.contains(TunnelSetupStep.binary)) {
      missing.add(TunnelSetupStep.binary);
      details.add(_binaryError!);
    }
    return TunnelReport(
      status: running && connections > 0 ? TunnelStatus.up : TunnelStatus.down,
      running: running,
      registeredConnections: connections,
      metricsPort: running ? _metricsPort : null,
      hostname: _lastConfig?.hostname,
      missing: missing,
      missingDetails: details,
    );
  }

  /// The capped auto-respawn was exhausted: the tunnel is down until a
  /// manual [restart].
  bool get respawnCapExhausted => _respawnCapExhausted;
}
