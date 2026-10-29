import 'dart:async';

import '../../attach/attach_args.dart';
import '../events/bridge_event.dart';
import 'terminal_models.dart';
import 'terminal_window.dart';

/// Emits one bridge-native event payload (the [EventHub].emit seam).
typedef BridgeEventEmitter = void Function(String payload);

/// The bridge's owner of the terminal windows (spec §7): one real terminal
/// window per app-launched session, each hosting the attach client for the
/// session (endpoint 10, authenticated with the per-bridge-startup window
/// token).
///
/// - [openFor] spawns the window and flips the session's in-process live
///   fact (spec §6/§11): the session classifies `app-launched-live`.
/// - A window exit (the user closed it) flips the fact back — an in-memory
///   transition, **no persistence write** (spec §11: window close is the
///   Closed-section transition) — and emits the bridge-native
///   `terminal.closed` event (spec §8).
/// - [closeFor] kills the window (the delete-on-live path: close window +
///   delete session in the same action, spec §5 endpoint 4).
class TerminalWindowManager {
  TerminalWindowManager({
    required this.liveSessionIds,
    required TerminalWindowSpawner spawner,
    required String terminalBinary,
    required String Function() windowToken,
    this.onEvent,
    this.size = TerminalSize.defaultSize,
  }) {
    _spawner = spawner;
    _terminalBinary = terminalBinary;
    _windowToken = windowToken;
  }

  /// The in-process live fact shared with the sessions backend (spec
  /// §6/§11); the manager flips a session in/out of it as its window
  /// opens/closes.
  final Set<String> liveSessionIds;

  /// The window size the attach client is spawned at (and reports to the
  /// PTY on connect, spec §16).
  final TerminalSize size;

  late final TerminalWindowSpawner _spawner;
  late final String _terminalBinary;
  late final String Function() _windowToken;

  /// Emits the bridge-native `terminal.closed` event; `null` in tests.
  final BridgeEventEmitter? onEvent;

  final Map<String, TerminalWindow> _windows = {};

  /// Whether the window for [sessionId] is currently open.
  bool isLive(String sessionId) => _windows.containsKey(sessionId);

  /// Opens the window hosting the attach client for [sessionId] (one window
  /// per session: an open window is kept, not duplicated), and flips the
  /// session live.
  Future<void> openFor(String sessionId) async {
    if (_windows.containsKey(sessionId)) return;
    final args = AttachArgs(
      sessionId: sessionId,
      token: _windowToken(),
      size: size,
    );
    final window = await _spawner.spawn(
      attachClientArgv: args.argvFor(_terminalBinary),
      size: size,
    );
    _windows[sessionId] = window;
    liveSessionIds.add(sessionId);
    unawaited(window.exited.then((_) => _onWindowExited(sessionId)));
  }

  /// Closes the window for [sessionId] (the delete-on-live path): kills the
  /// window and flips the session back to not-live. No `terminal.closed`
  /// event — the delete action emits `session.closed` instead.
  Future<void> closeFor(String sessionId) async {
    final window = _windows.remove(sessionId);
    if (window == null) return;
    liveSessionIds.remove(sessionId);
    await window.kill();
  }

  /// Closes every open window (bridge shutdown), without emitting
  /// `terminal.closed` (the bridge is going away, not a window closing under
  /// a live app).
  Future<void> close() async {
    final windows = Map.of(_windows);
    _windows.clear();
    liveSessionIds.removeAll(windows.keys);
    await Future.wait([for (final window in windows.values) window.kill()]);
  }

  void _onWindowExited(String sessionId) {
    final window = _windows.remove(sessionId);
    if (window == null) return; // Already closed via [closeFor]/[close].
    liveSessionIds.remove(sessionId);
    onEvent?.call(
      bridgeEvent(
        type: BridgeEventType.terminalClosed,
        data: {'sessionID': sessionId},
      ),
    );
  }
}
