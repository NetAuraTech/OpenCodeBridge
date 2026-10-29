import 'dart:async';

import 'opencode_terminal_service.dart';
import 'terminal_frames.dart';
import 'terminal_models.dart';

/// One downstream attacher (the app terminal view, or the terminal window's
/// attach client) connected to a session's terminal through the bridge.
///
/// The attacher reads an ordered [frames] stream and pushes raw input / resize
/// requests back. Closing the attacher releases its reference to the session's
/// upstream attach.
abstract class TerminalAttacher {
  /// The ordered output: replay bytes, a [TerminalReplayComplete] carrying the
  /// resumption cursor, then live [TerminalOutput] frames.
  Stream<TerminalFrame> get frames;

  /// Send raw input bytes to the TUI (protocol 0).
  Future<void> write(List<int> input);

  /// Request a resize of the PTY (spec §16).
  Future<void> resize(int cols, int rows);

  /// Stop this attacher and release its upstream reference.
  Future<void> close();
}

/// The bridge's per-session attach proxy (spec §7 endpoint 10).
///
/// The shared service enforces ONE attach per PTY, so the proxy is the single
/// upstream attach for a session's PTY and fans the screen out to any number
/// of bridge-side attachers (the app + the window's attach client). All
/// attachers see identical live output; input from any attacher reaches the
/// TUI; a resumption cursor is exposed so a re-connecting attacher resumes.
///
/// The proxy keeps a bounded in-memory ring of everything seen on the upstream
/// (its own offsets, independent of the service's) so a new attacher can be
/// replayed without a second upstream attach. When no attacher remains, the
/// upstream attach is released and the ring cleared; the next attacher
/// re-attaches from scratch (a bridge restart is UX-lossless, ADR-0002).
class TerminalAttachProxy {
  /// The default ring size: a terminal screen plus comfortable scrollback.
  static const int defaultRingCapacity = 1024 * 1024;

  TerminalAttachProxy({
    required OpencodeTerminalService service,
    required Future<TerminalInfo> Function() pty,
    int ringCapacity = defaultRingCapacity,
  }) {
    _service = service;
    _pty = pty;
    _ringCapacity = ringCapacity;
  }

  late final OpencodeTerminalService _service;

  /// Resolves the session's running PTY (creating it when needed). The proxy
  /// uses only the running PTY's id; creation (which needs the session's cwd)
  /// is the caller's concern.
  late final Future<TerminalInfo> Function() _pty;

  late final int _ringCapacity;

  TerminalConnection? _upstream;
  Future<void>? _ensureFuture;
  bool _closed = false;

  // The bounded ring of buffered output, in [startOffset, endOffset).
  final List<int> _ring = [];
  int _endOffset = 0;
  int get _startOffset => _endOffset - _ring.length;

  final Set<_Attacher> _live = {};

  /// The number of attachers currently attached (for tests/observability).
  int get attachers => _live.length;

  /// Whether the proxy has been closed.
  bool get isClosed => _closed;

  /// The current resumption cursor (one past the newest buffered byte).
  int get endOffset => _endOffset;

  /// Attach a downstream attacher, replaying from [cursor] (a bridge offset).
  /// A [cursor] outside the buffered range replays the current screen so a
  /// re-connecting attacher (e.g. across a bridge restart) always gets a
  /// renderable screen.
  Future<TerminalAttacher> attach({int cursor = 0}) async {
    if (_closed) throw StateError('proxy is closed');
    await _ensureUpstream();
    final attacher = _Attacher(this);

    final start = _startOffset;
    final end = _endOffset;
    final replayFrom = (cursor < start || cursor >= end) ? start : cursor;
    if (end > replayFrom) {
      attacher._push(
        TerminalOutput(_ring.sublist(replayFrom - start, end - start)),
      );
    }
    attacher._push(TerminalReplayComplete(end));
    _live.add(attacher);
    return attacher;
  }

  /// Close every attacher and release the upstream attach.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final attacher in Set.of(_live)) {
      await attacher.close();
    }
    _live.clear();
    await _closeUpstream();
  }

  Future<void> _ensureUpstream() {
    final existing = _ensureFuture;
    if (existing != null) return existing;
    return _ensureFuture = _doEnsureUpstream();
  }

  Future<void> _doEnsureUpstream() async {
    try {
      if (_upstream != null) return;
      final terminal = await _pty();
      final ticket = await _service.connectToken(terminal.id);
      final connection = await _service.connect(
        terminal.id,
        ticket: ticket.ticket,
        cursor: 0,
        size: terminal.size,
      );
      _upstream = connection;
      connection.output.listen(
        _ingest,
        onDone: _onUpstreamDone,
        onError: (Object e, StackTrace s) => _onUpstreamDone(),
      );
      await connection.initialReplayDone;
    } catch (error) {
      _ensureFuture = null;
      _upstream = null;
      rethrow;
    }
  }

  void _ingest(List<int> bytes) {
    if (_closed || _upstream == null) return;
    _ring.addAll(bytes);
    _endOffset += bytes.length;
    final excess = _ring.length - _ringCapacity;
    if (excess > 0) _ring.removeRange(0, excess);
    final frame = TerminalOutput(List<int>.of(bytes));
    for (final attacher in Set.of(_live)) {
      attacher._push(frame);
    }
  }

  void _onUpstreamDone() {
    if (_upstream == null) return; // Already handled by a clean close.
    _upstream = null;
    _ensureFuture = null;
    _ring.clear();
    _endOffset = 0;
    for (final attacher in Set.of(_live)) {
      attacher._close();
    }
    _live.clear();
  }

  Future<void> _forwardInput(List<int> input) async {
    final connection = _upstream;
    if (connection == null) return; // PTY gone or not attached; input dropped.
    await connection.write(input);
  }

  Future<void> _forwardResize(int cols, int rows) async {
    final connection = _upstream;
    if (connection == null) return; // PTY gone or not attached; resize dropped.
    await connection.resize(cols, rows);
  }

  Future<void> _detach(_Attacher attacher) async {
    if (!_live.remove(attacher)) return;
    await attacher._close();
    if (_live.isEmpty && !_closed) await _closeUpstream();
  }

  Future<void> _closeUpstream() async {
    final connection = _upstream;
    _upstream = null;
    _ensureFuture = null;
    _ring.clear();
    _endOffset = 0;
    if (connection != null) {
      try {
        await connection.close();
      } catch (_) {
        // The socket is already gone; closing is idempotent.
      }
    }
  }
}

/// The concrete downstream attacher handed out by [TerminalAttachProxy].
///
/// Every frame (the replay, then live) is buffered until [frames] is listened
/// to, so a consumer that subscribes after [TerminalAttachProxy.attach]
/// returns still receives the full replay. Closing is total: a subscribed
/// stream is closed, an unlistened one is merely marked done, so a late
/// [frames] read flushes the buffered replay and then ends. Either way
/// [close] completes, so the proxy never hangs releasing the upstream.
class _Attacher implements TerminalAttacher {
  _Attacher(this._proxy);

  final TerminalAttachProxy _proxy;

  final List<TerminalFrame> _buffered = [];
  StreamController<TerminalFrame>? _controller;
  bool _subscribed = false;
  bool _closed = false;

  @override
  Stream<TerminalFrame> get frames {
    if (_subscribed) {
      throw StateError('an attacher frame stream can be listened to once');
    }
    _subscribed = true;
    final controller = StreamController<TerminalFrame>();
    _controller = controller;
    for (final frame in List.of(_buffered)) {
      controller.add(frame);
    }
    _buffered.clear();
    if (_closed) controller.close();
    return controller.stream;
  }

  @override
  Future<void> write(List<int> input) => _proxy._forwardInput(input);

  @override
  Future<void> resize(int cols, int rows) => _proxy._forwardResize(cols, rows);

  @override
  Future<void> close() async {
    await _proxy._detach(this);
  }

  void _push(TerminalFrame frame) {
    if (_closed) return;
    final controller = _controller;
    if (_subscribed && controller != null) {
      controller.add(frame);
    } else {
      _buffered.add(frame);
    }
  }

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }
}
