import 'dart:async';
import 'dart:io';

import 'package:opencodebridge/attach/attach_args.dart';
import 'package:opencodebridge/attach/attach_client.dart';
import 'package:opencodebridge/bridge/bridge_server.dart';

/// Runs the app binary in its headless attach-client mode (the terminal
/// window's process, spec §7): authenticates to the host bridge with the
/// window token, renders the session's ANSI stream as passthrough into this
/// terminal, forwards local keystrokes, reports the window's size, and
/// auto-reconnects with cursor resumption (a bridge restart is invisible).
///
/// Completes (and exits) when the window closes: the emulator kills the
/// child on window close, which closes [stdin]; that exit is the window's
/// lifecycle handle (`gnome-terminal --wait`).
Future<void> runHeadlessAttach(List<String> argv) async {
  late final AttachArgs args;
  try {
    args = AttachArgs.parse(argv);
  } on FormatException catch (error) {
    stderr.writeln('attach client: ${error.message}');
    exit(2);
  }
  final client = TerminalAttachClient(
    sessionId: args.sessionId,
    token: args.token,
    bridgeUri: Uri.parse(
      'ws://${BridgeServer.loopbackHost}:${BridgeServer.defaultPort}',
    ),
    connect: connectAttach,
    input: stdin,
    render: (List<int> bytes) {
      stdout.add(bytes);
    },
    size: args.size,
  );
  await client.run();
  await client.stop();
  exit(0);
}

/// The production [AttachTransport] factory: a `dart:io` WebSocket to the
/// bridge's attach endpoint (10), split into binary ANSI frames and text
/// control frames.
Future<AttachTransport> connectAttach(Uri uri) =>
    WebSocket.connect(uri.toString()).then(_WebSocketAttachTransport.new);

/// A `dart:io` [WebSocket] presented as an [AttachTransport].
class _WebSocketAttachTransport implements AttachTransport {
  _WebSocketAttachTransport(WebSocket ws) {
    _ws = ws;
    ws.listen(
      (dynamic event) {
        if (event is List<int>) {
          _data.add(event);
        } else if (event is String) {
          _control.add(event);
        }
      },
      onDone: _finish,
      onError: (Object error, StackTrace stackTrace) => _finish(),
    );
  }

  late final WebSocket _ws;

  final StreamController<List<int>> _data = StreamController<List<int>>();

  final StreamController<String> _control = StreamController<String>();

  final Completer<void> _done = Completer<void>();

  bool _closed = false;

  @override
  Stream<List<int>> get data => _data.stream;

  @override
  Stream<String> get control => _control.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void send(Object frame) {
    if (_closed) return;
    try {
      _ws.add(frame);
    } catch (_) {
      // The socket already went away; the reconnect loop takes over.
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    try {
      await _ws.close();
    } catch (_) {
      // The socket is already gone.
    }
  }

  void _finish() {
    if (!_data.isClosed) _data.close();
    if (!_control.isClosed) _control.close();
    if (!_done.isCompleted) _done.complete();
  }
}
