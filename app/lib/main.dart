import 'package:flutter/material.dart';

import 'app.dart';
import 'attach/attach_args.dart';
import 'attach/attach_io.dart';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == AttachArgs.flag) {
    // The terminal window's headless attach-client mode (spec §7): no UI,
    // just the session's terminal on this terminal.
    await runHeadlessAttach(args);
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OpenCodeBridgeApp());
}
