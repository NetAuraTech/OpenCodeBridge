import 'dart:async';

import 'package:opencodebridge/bridge/terminal/terminal_frames.dart';
import 'package:opencodebridge/bridge/terminal/terminal_models.dart';

/// The transport seam under one attach attempt: the WebSocket to the
/// bridge's terminal attach endpoint (10), split into its two frame kinds
/// (spec §7). The production implementation wraps a `dart:io` WebSocket.
abstract class AttachTransport {
  /// Raw ANSI output frames from the bridge (binary frames), in order: the
  /// replay, then live frames.
  Stream<List<int>> get data;

  /// Text control frames from the bridge; today the only one is
  /// `replay_complete` (parse with [parseReplayComplete]).
  Stream<String> get control;

  /// Completes when the transport closes (the bridge released the attach,
  /// e.g. on a bridge restart, or the connection broke): the signal to
  /// reconnect.
  Future<void> get done;

  /// Send a frame to the bridge: raw terminal input bytes (binary) or a
  /// control frame (text, e.g. a resize).
  void send(Object frame);

  /// Close this attach; the bridge releases its downstream reference.
  Future<void> close();
}

/// The headless attach client (spec §7): the terminal window's view of a
/// session's terminal, over the bridge's attach endpoint.
///
/// It renders the incoming ANSI stream as passthrough (the stream is already
/// rendered by the TUI in the service's PTY) and forwards local keystrokes
/// to the TUI. It reports the window's size once per attach as a resize
/// (spec §16) and auto-reconnects with a growing backoff, resuming from the
/// last `replay_complete` endOffset, so a bridge restart is invisible to the
/// window user (ADR-0002). It stops when [input] closes (the window closed);
/// [run] then completes.
///
/// [run] must be called once. [stop] may be called any time and is
/// idempotent.
class TerminalAttachClient {
  TerminalAttachClient({
    required String sessionId,
    required String token,
    required Uri bridgeUri,
    required Future<AttachTransport> Function(Uri uri) connect,
    required Stream<List<int>> input,
    required void Function(List<int> bytes) render,
    TerminalSize? size,
    this.initialBackoff = const Duration(milliseconds: 250),
    this.maxBackoff = const Duration(seconds: 10),
  }) {
    _sessionId = sessionId;
    _token = token;
    _bridgeUri = bridgeUri;
    _connect = connect;
    _input = input;
    _render = render;
    _size = size;
  }

  late final String _sessionId;

  late final String _token;

  late final Uri _bridgeUri;

  late final Future<AttachTransport> Function(Uri uri) _connect;

  late final Stream<List<int>> _input;

  late final void Function(List<int> bytes) _render;

  late final TerminalSize? _size;

  /// The first reconnect delay; doubled per attempt, capped at [maxBackoff].
  /// Reset on every successful connect, so a bridge that comes back is
  /// re-attached quickly.
  final Duration initialBackoff;

  /// The reconnect delay cap.
  final Duration maxBackoff;

  StreamSubscription<List<int>>? _inputSub;
  AttachTransport? _transport;
  bool _stopping = false;

  /// The resumption cursor: the last `replay_complete` endOffset seen, or 0
  /// on the first connect.
  int _resumeCursor = 0;

  Duration _backoff = const Duration();

  /// The reconnect delays applied so far (tests/observability).
  final List<Duration> backoffs = [];

  /// Whether [stop] has been requested (tests/observability).
  bool get isStopped => _stopping;

  /// Runs the client until it stops (see the class docs). Completes after
  /// the input closes and the current attach is released.
  Future<void> run() async {
    _backoff = initialBackoff;
    _inputSub = _input.listen((List<int> bytes) {
      final transport = _transport;
      if (transport != null) transport.send(bytes);
    }, onDone: () => stop());
    while (!_stopping) {
      try {
        final transport = await _connect(_attachUri());
        if (_stopping) {
          await transport.close();
          break;
        }
        _transport = transport;
        _backoff = initialBackoff;
        final size = _size;
        if (size != null) transport.send(encodeResize(size.cols, size.rows));
        await _pump(transport);
      } catch (_) {
        // The bridge is down or refused the attach; reconnect with backoff.
      } finally {
        _transport = null;
      }
      if (_stopping) break;
      backoffs.add(_backoff);
      await Future<void>.delayed(_backoff);
      _backoff = Duration(
        milliseconds: (_backoff.inMilliseconds * 2)
            .clamp(0, maxBackoff.inMilliseconds)
            .toInt(),
      );
    }
    final sub = _inputSub;
    _inputSub = null;
    if (sub != null) await sub.cancel();
  }

  /// Stops the client and closes the current attach. Idempotent.
  Future<void> stop() async {
    _stopping = true;
    final sub = _inputSub;
    _inputSub = null;
    if (sub != null) await sub.cancel();
    final transport = _transport;
    _transport = null;
    if (transport != null) await transport.close();
  }

  /// The attach uri for the current resumption cursor (endpoint 10, with
  /// the window token).
  Uri _attachUri() => _bridgeUri.replace(
    path: '/api/sessions/${Uri.encodeComponent(_sessionId)}/terminal',
    queryParameters: {'token': _token, 'cursor': '$_resumeCursor'},
  );

  /// Drives one attach: forwards output to the render sink and tracks the
  /// resumption cursor, until the transport closes.
  Future<void> _pump(AttachTransport transport) async {
    transport.data.listen(
      _render,
      onDone: () {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    transport.control.listen(
      (String frame) {
        final endOffset = parseReplayComplete(frame);
        if (endOffset != null) _resumeCursor = endOffset;
      },
      onDone: () {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    await transport.done;
  }
}
