import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../bridge/terminal/terminal_attach_proxy.dart';
import '../bridge/terminal/terminal_frames.dart';

/// The interactive view of one session's terminal (spec §12: the app
/// follows the terminal).
///
/// While it is showing, the app is attached in-process to the session's
/// PTY next to the terminal window's attach client (attach is
/// multi-attacher): live output is shared, the on-screen keyboard reaches
/// the TUI, and resizes are forwarded. Closing this view releases only
/// the app's attach; the terminal window keeps running.
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key, required this.title, required this.attach});

  /// The session's title, shown in the app bar.
  final String title;

  /// Opens the in-process attach for the session's PTY. Completing with an
  /// error shows the error state (e.g. the terminal could not be reached).
  final Future<TerminalAttacher> Function() attach;

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

  @override
  void initState() {
    super.initState();
    _connect();
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
    _frames?.cancel();
    _attacher?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _attaching
          ? const Center(child: CircularProgressIndicator())
          : error != null
          ? _ErrorView(message: error)
          : Padding(
              padding: const EdgeInsets.all(4),
              child: TerminalView(_terminal, autofocus: true),
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
