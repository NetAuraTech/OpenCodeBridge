import 'dart:io';

import 'terminal_models.dart';

/// The argv of one real terminal window hosting the attach client
/// (spec §7, ADR-0002: the bridge spawns the terminal emulator binary
/// directly, inside the user's graphical session).
///
/// Preferred: `gnome-terminal --wait` (native Wayland; the `--wait` child
/// is the window's lifecycle handle — it exits when the window closes).
/// Fallback: `xterm -e` (the window closes when the command exits). The
/// window is spawned at [size] (v1 worst case: a fixed default size,
/// spec §16).
TerminalWindowCommand buildTerminalWindowCommand({
  String? gnomeTerminal,
  String? xterm,
  required List<String> attachClientArgv,
  TerminalSize size = TerminalSize.defaultSize,
}) {
  final geometry = '${size.cols}x${size.rows}';
  if (gnomeTerminal != null) {
    return TerminalWindowCommand([
      gnomeTerminal,
      '--wait',
      '--geometry',
      geometry,
      '--',
      ...attachClientArgv,
    ]);
  }
  if (xterm != null) {
    return TerminalWindowCommand([
      xterm,
      '-geometry',
      geometry,
      '-e',
      ...attachClientArgv,
    ]);
  }
  throw const TerminalEmulatorMissing();
}

/// One window-spawn argv, as returned by [buildTerminalWindowCommand].
class TerminalWindowCommand {
  const TerminalWindowCommand(this.argv);

  /// argv[0] is the terminal emulator binary.
  final List<String> argv;

  @override
  String toString() => 'TerminalWindowCommand(${argv.join(' ')})';
}

/// No terminal emulator capable of hosting a window is on the host.
class TerminalEmulatorMissing implements Exception {
  const TerminalEmulatorMissing();

  @override
  String toString() =>
      'TerminalEmulatorMissing: no gnome-terminal or xterm on PATH';
}

/// One real terminal window hosting the attach client.
class TerminalWindow {
  const TerminalWindow(this._exited, this._kill);

  final Future<int> _exited;
  final Future<void> Function() _kill;

  /// Completes with the attach client's exit code once the window closed —
  /// the `--wait`/`-e` child exited (the user closed the window, or the
  /// attach client stopped).
  Future<int> get exited => _exited;

  /// Closes the window (the delete-on-live path, spec §5 endpoint 4): kills
  /// the spawned process and the attach client, whatever the emulator.
  Future<void> kill() => _kill();
}

/// Resolves a terminal emulator by name on the host, or `null` when it is
/// not on PATH.
typedef EmulatorResolver = String? Function(String name);

/// Launches one argv (argv[0] first), for [TerminalWindowSpawner].
typedef WindowLauncher = Future<Process> Function(List<String> argv);

/// Spawns the host terminal window hosting the attach client (spec §7).
///
/// The per-OS adapter of the process model (ADR-0002): Linux v1 resolves
/// `gnome-terminal`/`xterm` and launches the emulator directly; a future
/// host is a new resolver/launcher, not a core change.
class TerminalWindowSpawner {
  TerminalWindowSpawner({
    required EmulatorResolver emulators,
    WindowLauncher launch = _hostLaunch,
  }) {
    _emulators = emulators;
    _launch = launch;
  }

  late final EmulatorResolver _emulators;

  late final WindowLauncher _launch;

  /// The host spawner: emulators resolved from PATH.
  factory TerminalWindowSpawner.host() =>
      TerminalWindowSpawner(emulators: findHostEmulator);

  /// Opens the window hosting [attachClientArgv] (the attach client's full
  /// argv) at [size]. The window closes when the attach client exits;
  /// [TerminalWindow.exited] then completes.
  Future<TerminalWindow> spawn({
    required List<String> attachClientArgv,
    TerminalSize size = TerminalSize.defaultSize,
  }) async {
    final command = buildTerminalWindowCommand(
      gnomeTerminal: _emulators('gnome-terminal'),
      xterm: _emulators('xterm'),
      attachClientArgv: attachClientArgv,
      size: size,
    );
    final process = await _launch(command.argv);
    return TerminalWindow(
      process.exitCode,
      () => TerminalWindowSpawner._hostKill(process, attachClientArgv),
    );
  }

  /// Closes the window on the host: kills the spawned process, and — because
  /// the emulator may run the attach client under its own server (gnome
  /// terminal) rather than as a child — terminates the attach client by its
  /// full argv, which is unique per bridge startup (the window token).
  static Future<void> _hostKill(
    Process process,
    List<String> attachClientArgv,
  ) async {
    process.kill();
    if (Platform.isLinux) {
      try {
        await Process.run('pkill', ['-f', attachClientArgv.join(' ')]);
      } catch (_) {
        // No pkill, or the client already gone: best effort.
      }
    }
  }
}

/// Launches one argv with the emulator as argv[0] (the host default).
Future<Process> _hostLaunch(List<String> argv) =>
    Process.start(argv.first, argv.sublist(1));

/// Resolves a terminal emulator on this host's PATH, or `null` when it is
/// not found. [path] overrides `PATH` (tests).
String? findHostEmulator(String name, {String? path}) {
  final pathValue = path ?? Platform.environment['PATH'] ?? '';
  for (final dir in pathValue.split(':')) {
    if (dir.isEmpty) continue;
    try {
      final candidate = File('$dir/$name');
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
