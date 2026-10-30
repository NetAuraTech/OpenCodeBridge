import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../bridge/terminal/terminal_attach_proxy.dart';
import '../bridge/terminal/terminal_frames.dart';
import '../client/events_client.dart';
import '../client/sessions_client.dart';
import '../model/permission.dart';
import 'permission_banner.dart';

/// The interactive view of one session's terminal (spec §12: the app
/// follows the terminal).
///
/// While it is showing, the app is attached in-process to the session's
/// PTY next to the terminal window's attach client (attach is
/// multi-attacher): live output is shared, the on-screen keyboard reaches
/// the TUI, and resizes are forwarded. Closing this view releases only
/// the app's attach; the terminal window keeps running.
///
/// When [sessionId] and [client] are provided, the session's pending
/// permission requests show as the approve/deny banner (spec §6:
/// "Permissions (both views)"), kept live on `permission.asked` /
/// `permission.replied` (§8).
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    super.key,
    required this.title,
    required this.attach,
    this.sessionId,
    this.client,
    this.events,
  });

  /// The session's title, shown in the app bar.
  final String title;

  /// Opens the in-process attach for the session's PTY. Completing with an
  /// error shows the error state (e.g. the terminal could not be reached).
  final Future<TerminalAttacher> Function() attach;

  /// The session id for the permission banner; the banner is shown only
  /// when both this and [client] are provided.
  final String? sessionId;

  /// The bridge's sessions API client (endpoints 8 and 9) for the banner.
  final SessionsClient? client;

  /// Every event off the bridge's unified stream (spec §8), or `null` for
  /// initial-state-only banner rendering.
  final Stream<BridgeEvent>? events;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  late final Terminal _terminal = Terminal(
    onOutput: _onOutput,
    onResize: _onResize,
  );

  TerminalAttacher? _attacher;
  StreamSubscription<TerminalFrame>? _frames;

  /// True until [widget.attach] settles.
  bool _attaching = true;

  /// The attach failure, if any.
  String? _error;

  /// The pending permission requests (endpoint 8), banner enabled only.
  List<PermissionRequest> _pending = const [];

  /// The request whose reply (endpoint 9) is in flight.
  String? _replyBusyId;

  StreamSubscription<BridgeEvent>? _events;

  @override
  void initState() {
    super.initState();
    _connect();
    final session = widget.sessionId;
    final client = widget.client;
    if (session == null || client == null) return;
    _loadPermissions(client, session);
    final stream = widget.events;
    if (stream != null) {
      _events = stream.listen((event) {
        final forSession =
            event.durable?.aggregateID == session ||
            event.data['sessionID'] == session;
        if (!forSession) return;
        if (event.type == 'permission.asked' ||
            event.type == 'permission.replied') {
          _loadPermissions(client, session);
        }
      });
    }
  }

  /// Re-fetches the pending permission requests (endpoint 8): the initial
  /// state of the banner and the `permission.*` live refresh.
  Future<void> _loadPermissions(SessionsClient client, String session) async {
    try {
      final pending = await client.getPermissions(session);
      if (!mounted) return;
      setState(() => _pending = pending);
    } on SessionsClientError {
      // A transient failure keeps the last pending list on screen.
    }
  }

  /// Applies the decision (endpoint 9) and re-fetches the pending list.
  Future<void> _reply(PermissionRequest request, PermissionReply reply) async {
    final client = widget.client;
    final session = widget.sessionId;
    if (client == null || session == null || _replyBusyId != null) return;
    setState(() => _replyBusyId = request.id);
    try {
      await client.replyPermission(session, request.id, reply);
      await _loadPermissions(client, session);
    } on SessionsClientError {
      // The request stays pending on screen; the user can retry.
    } finally {
      if (mounted) setState(() => _replyBusyId = null);
    }
  }

  Future<void> _connect() async {
    try {
      final attacher = await widget.attach();
      if (!mounted) {
        // The view went away while attaching: release the attach.
        await attacher.close();
        return;
      }
      _attacher = attacher;
      _frames = attacher.frames.listen(_onFrame);
      setState(() {
        _attaching = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _attaching = false;
        _error = '$error';
      });
    }
  }

  void _onFrame(TerminalFrame frame) {
    if (frame is TerminalOutput) {
      _terminal.write(utf8.decode(frame.bytes));
    }
    // TerminalReplayComplete: the replay is done; the live output continues
    // on the same stream, so there is nothing to do here.
  }

  void _onOutput(String data) {
    final attacher = _attacher;
    if (attacher != null) attacher.write(utf8.encode(data));
  }

  void _onResize(int cols, int rows, int pixelWidth, int pixelHeight) {
    final attacher = _attacher;
    if (attacher != null) attacher.resize(cols, rows);
  }

  @override
  void dispose() {
    _events?.cancel();
    _frames?.cancel();
    _attacher?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    Widget terminalBody;
    if (_attaching) {
      terminalBody = const Center(child: CircularProgressIndicator());
    } else if (error != null) {
      terminalBody = _ErrorView(message: error);
    } else {
      terminalBody = Padding(
        padding: const EdgeInsets.all(4),
        child: TerminalView(_terminal, autofocus: true),
      );
    }
    final client = widget.client;
    final session = widget.sessionId;
    if (client == null || session == null) {
      // Banner disabled: the body is exactly the terminal, as before.
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: terminalBody,
      );
    }
    // Banner enabled: the terminal fills the space above the banner; the
    // banner renders nothing while no request is pending.
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Expanded(child: terminalBody),
          PermissionBanner(
            pending: _pending,
            onReply: _reply,
            replyBusyId: _replyBusyId,
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        'Could not attach to the terminal.\n$message',
        textAlign: TextAlign.center,
      ),
    ),
  );
}
