import 'dart:async';
import 'dart:io';

import 'cloudflared_binary.dart';

/// One driven `cloudflared` CLI invocation's result (issue #37, ADR-0003):
/// the exit code plus the captured output.
class CliRun {
  const CliRun({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// The child's exit code.
  final int exitCode;

  /// The child's captured stdout.
  final String stdout;

  /// The child's captured stderr.
  final String stderr;

  /// Whether the child exited 0.
  bool get success => exitCode == 0;

  /// The first non-blank output line (stderr first, then stdout), `''`
  /// when both are empty: the line to show the user.
  String get firstOutputLine {
    for (final line in [...stderr.split('\n'), ...stdout.split('\n')]) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return '';
  }
}

/// Driving the app-managed cloudflared binary failed (issue #37): the
/// binary could not be made available, or the invocation timed out.
class CloudflaredCliError implements Exception {
  const CloudflaredCliError(this.message);

  /// The human-readable explanation, shown as-is.
  final String message;

  @override
  String toString() => 'CloudflaredCliError: $message';
}

/// A live CLI child. `Process` from `dart:io` is adapted to this (the
/// repo's `TunnelProcess` pattern).
abstract class CliProcess {
  /// The child's pid.
  int get pid;

  /// Completes with the exit code when the child exits.
  Future<int> get exitCode;

  /// The child's stdout bytes.
  Stream<List<int>> get stdout;

  /// The child's stderr bytes.
  Stream<List<int>> get stderr;

  /// Terminates the child; true when the signal was delivered.
  bool kill();
}

/// Spawns the CLI child with the given argv.
typedef CliSpawner = Future<CliProcess> Function(List<String> argv);

/// Adapts a `dart:io` [Process] to [CliProcess].
class _CliProcessAdapter implements CliProcess {
  _CliProcessAdapter(this._process);

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

/// Spawns the CLI child on the host with `Process.start`.
Future<CliProcess> hostCliSpawn(List<String> argv) async {
  final process = await Process.start(argv.first, argv.sublist(1));
  return _CliProcessAdapter(process);
}

/// Drives the app-managed cloudflared binary as a CLI (issue #37,
/// ADR-0003): `tunnel login` opens the default browser on Cloudflare's
/// OAuth consent page, and `tunnel create` creates the tunnel and writes
/// `~/.cloudflared/<uuid>.json` — both by cloudflared itself, into the
/// user's own home directory. The app only spawns the process and reads
/// its exit status: it never sees a Cloudflare token.
class TunnelCli {
  TunnelCli({
    required this.binary,
    this.spawner = hostCliSpawn,
    this.timeout = const Duration(minutes: 5),
  });

  /// The app-managed binary the CLI runs (the same file the tunnel child
  /// runs).
  final CloudflaredBinary binary;

  /// Spawns the CLI child (tests inject a fake).
  final CliSpawner spawner;

  /// How long one invocation may run (the login waits for the user's
  /// browser consent).
  final Duration timeout;

  /// Runs `cloudflared tunnel login`: cloudflared opens the browser on
  /// Cloudflare's consent page, waits for the callback, and stores the
  /// session in the user's own `~/.cloudflared/`.
  Future<CliRun> login() => _run(['tunnel', 'login']);

  /// Runs `cloudflared tunnel create <name>`: creates the tunnel in the
  /// account (the [login] session is required) and writes
  /// `~/.cloudflared/<uuid>.json`.
  Future<CliRun> createTunnel(String name) => _run(['tunnel', 'create', name]);

  Future<CliRun> _run(List<String> args) async {
    File binaryFile;
    try {
      binaryFile = await binary.ensure();
    } on CloudflaredBinaryError catch (e) {
      throw CloudflaredCliError(e.message);
    }
    final child = await spawner([binaryFile.path, ...args]);
    final stdout = child.stdout
        .transform(const SystemEncoding().decoder)
        .join();
    final stderr = child.stderr
        .transform(const SystemEncoding().decoder)
        .join();
    int code;
    try {
      code = await child.exitCode.timeout(timeout);
    } on TimeoutException {
      child.kill();
      throw const CloudflaredCliError(
        'the cloudflared command timed out: complete the Cloudflare flow '
        'in the browser, then try again',
      );
    }
    return CliRun(exitCode: code, stdout: await stdout, stderr: await stderr);
  }
}
