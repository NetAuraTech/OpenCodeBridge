/// The bridge's seam over the shared opencode service's persistent-PTY family
/// (ADR-0001: the app never talks to the service directly; the bridge owns
/// the PTYs it creates for app-launched sessions and never re-implements a
/// PTY, spec §7).
///
/// The terminal slice needs exactly these things of the service:
/// - create the session-bound PTY that hosts the TUI;
/// - resolve the session's running PTY;
/// - obtain a connect ticket and open the live attach (the single upstream
///   attach the bridge holds per session);
/// - resize the PTY (spec §16).
library;

import 'dart:async';

import 'terminal_models.dart';

/// A failure talking to the shared opencode service, carrying the service's
/// HTTP status so the bridge can map it (a 404 -> 404, a transport failure ->
/// status 0).
class OpencodeTerminalServiceError implements Exception {
  const OpencodeTerminalServiceError(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'OpencodeTerminalServiceError($statusCode: $message)';
}

/// One live attach the bridge holds to a PTY. The bridge is the *only*
/// upstream attach per PTY (the service enforces one), so this is the single
/// handle the attach proxy reads the screen from and drives the TUI through.
///
/// The attach speaks the service's *framed* input protocol (protocol 1): the
/// connection tracks the PTY size and rides it in every frame it sends, so a
/// [write] never resizes the PTY to a stale size and a [resize] takes effect
/// over the attach (with the attach open, the service rejects an HTTP resize).
abstract class TerminalConnection {
  /// Raw ANSI output from the PTY (the initial replay, then live frames), as
  /// bytes. The service's text control frames (`attached`, `replay_complete`,
  /// ...) are filtered out — the proxy has its own frame protocol.
  Stream<List<int>> get output;

  /// Completes once the upstream's initial replay has finished (its
  /// `replay_complete`), so a caller can be sure the current screen is
  /// buffered before snapshotting the ring. Completes (rather than hanging)
  /// if the connection closes first.
  Future<void> get initialReplayDone;

  /// Send raw input bytes to the TUI, framed with the current PTY size.
  Future<void> write(List<int> input);

  /// Resize the PTY to [cols] x [rows] over the attach and make that the size
  /// subsequent [write]s frame with.
  Future<void> resize(int cols, int rows);

  /// Close the upstream attach.
  Future<void> close();
}

/// The seam the attach proxy and the bridge server depend on. [OpencodeService]
/// (the sessions slice) is a sibling seam over the service's session list;
/// this one is over its persistent-PTY family.
abstract class OpencodeTerminalService {
  /// Create the session-bound persistent PTY running the TUI for [sessionId]
  /// (`opencode --session <id>`, working dir [cwd]). The service quirks the
  /// bridge handles: `env` is required at runtime (sent as `{}`), and `size`
  /// defaults to [TerminalSize.defaultSize] when omitted.
  Future<TerminalInfo> createTerminal(
    String sessionId, {
    required String cwd,
    TerminalSize? size,
    String? title,
  });

  /// Every PTY bound to [sessionId], running or exited.
  Future<List<TerminalInfo>> listTerminals(String sessionId);

  /// The session's running PTY, or an error when none is running.
  Future<TerminalInfo> runningTerminal(String sessionId);

  /// A short-lived ticket authorizing a [connect] of [ptyId].
  Future<TerminalTicket> connectToken(String ptyId);

  /// Open a live attach to [ptyId]. [ticket] is from [connectToken]; [cursor]
  /// is the service's replay start offset (0 = from the start of its ring);
  /// [size] is the PTY's current size — the attach frames every input with it
  /// (protocol 1) and starts resizes from it.
  Future<TerminalConnection> connect(
    String ptyId, {
    required String ticket,
    int cursor = 0,
    required TerminalSize size,
  });

  /// Resize the PTY to [size] (spec §16).
  Future<TerminalInfo> resize(String ptyId, TerminalSize size);

  /// Delete the PTY (the service answers 204).
  Future<void> delete(String ptyId);
}
