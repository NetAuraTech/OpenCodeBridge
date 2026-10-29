import 'package:opencodebridge/bridge/terminal/terminal_models.dart';

/// The argv contract of the app binary's headless attach-client mode
/// (spec §7): the terminal window is spawned by the bridge running the app
/// binary with [flag], a session id, and the per-bridge-startup window token.
///
/// The convention is shared by the side that builds the argv (the window
/// spawner's caller) and the side that parses it ([main]'s dispatch).
class AttachArgs {
  const AttachArgs({required this.sessionId, required this.token, this.size});

  /// The argv[0] flag that marks a headless attach-client invocation.
  static const String flag = '--attach-terminal';

  /// The session whose terminal is attached.
  final String sessionId;

  /// The per-bridge-startup window token (spec §10, §14), authenticated to
  /// the bridge on the attach WebSocket.
  final String token;

  /// The real terminal size the window was spawned at, reported to the PTY as
  /// a resize on connect (spec §16); `null` when the size is unknown (the
  /// PTY then keeps its default size).
  final TerminalSize? size;

  /// The attach argv (without the binary).
  List<String> toArgv() {
    final size = this.size;
    return [
      flag,
      '--session',
      sessionId,
      '--token',
      token,
      if (size != null) '--size',
      if (size != null) '${size.cols}x${size.rows}',
    ];
  }

  /// The full argv the window spawner runs: [binary] (the app binary) plus
  /// the attach argv.
  List<String> argvFor(String binary) => [binary, ...toArgv()];

  /// Parses an attach argv produced by [toArgv].
  static AttachArgs parse(List<String> argv) {
    if (argv.isEmpty || argv.first != flag) {
      throw const FormatException('not an attach-client argv');
    }
    String? sessionId;
    String? token;
    TerminalSize? size;
    final rest = argv.sublist(1);
    for (var i = 0; i < rest.length; i++) {
      final arg = rest[i];
      String value() {
        if (i + 1 >= rest.length) {
          throw FormatException('$arg takes a value');
        }
        i++;
        return rest[i];
      }

      switch (arg) {
        case '--session':
          sessionId = value();
        case '--token':
          token = value();
        case '--size':
          final match = RegExp(r'^(\d+)x(\d+)$').firstMatch(value());
          if (match == null) {
            throw const FormatException('--size must be <cols>x<rows>');
          }
          size = TerminalSize(
            cols: int.parse(match.group(1)!),
            rows: int.parse(match.group(2)!),
          );
        default:
          throw FormatException('unknown attach argument $arg');
      }
    }
    if (sessionId == null || token == null) {
      throw const FormatException('--session and --token are required');
    }
    return AttachArgs(sessionId: sessionId, token: token, size: size);
  }

  @override
  bool operator ==(Object other) =>
      other is AttachArgs &&
      other.sessionId == sessionId &&
      other.token == token &&
      other.size == size;

  @override
  int get hashCode => Object.hash(sessionId, token, size);
}
