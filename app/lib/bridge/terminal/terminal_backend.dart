import 'dart:async';

import 'opencode_terminal_service.dart';
import 'terminal_attach_proxy.dart';
import 'terminal_models.dart';
import 'terminal_window_token.dart';

/// The bridge's per-bridge-startup terminal backend (spec §7, §10, §14).
///
/// Owns the shared opencode terminal service, the window token, and the
/// per-session attach proxies. The window token is generated fresh on every
/// bridge startup and never persisted; it authenticates the terminal window's
/// attach client to endpoint 10. The in-process local client (server mode)
/// attaches to a session's proxy directly and never passes through here, so it
/// needs no token.
class TerminalBackend {
  TerminalBackend({
    required OpencodeTerminalService service,
    required TerminalWindowToken token,
    required Future<String> Function(String sessionId) sessionCwd,
  }) {
    _service = service;
    _token = token;
    _sessionCwd = sessionCwd;
  }

  late final OpencodeTerminalService _service;

  late final TerminalWindowToken _token;

  /// Resolves a session's working directory (its PTY's `cwd`). The terminal
  /// slice does not know a session's location on its own; the bridge supplies
  /// this from the sessions slice.
  late final Future<String> Function(String sessionId) _sessionCwd;

  final Map<String, TerminalAttachProxy> _proxies = {};

  /// The window token, passed in the spawn command of each attach client.
  TerminalWindowToken get token => _token;

  /// Whether [presented] is this startup's window token.
  bool verifyToken(String? presented) => _token.verify(presented);

  /// The session's attach proxy, created on first use. One upstream attach per
  /// session, fanned out to any number of bridge-side attachers.
  TerminalAttachProxy proxyFor(String sessionId) {
    return _proxies.putIfAbsent(
      sessionId,
      () => TerminalAttachProxy(
        service: _service,
        pty: () => _resolvePty(sessionId),
      ),
    );
  }

  /// Resolve the session's running PTY, creating it in the session's own
  /// working directory when none is running (spec §7: the bridge owns the
  /// PTYs it creates for app-launched sessions).
  Future<TerminalInfo> _resolvePty(String sessionId) async {
    final terminals = await _service.listTerminals(sessionId);
    for (final terminal in terminals) {
      if (terminal.status == TerminalStatus.running) return terminal;
    }
    final cwd = await _sessionCwd(sessionId);
    return _service.createTerminal(sessionId, cwd: cwd);
  }

  /// Close every session's proxy, releasing the upstream attaches.
  Future<void> close() async {
    final futures = [for (final proxy in _proxies.values) proxy.close()];
    _proxies.clear();
    await Future.wait(futures);
  }
}
