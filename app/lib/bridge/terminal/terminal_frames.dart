/// The attach frame protocol (spec §7). The bridge's attach proxy talks to
/// its downstream attachers (the app terminal view and the terminal
/// window's attach client) over a small frame protocol carried on the attach
/// WebSocket (endpoint 10).
///
/// - **Proxy → downstream (output):** [TerminalOutput] frames carry raw ANSI
///   bytes (the replay, then the live stream); a [TerminalReplayComplete]
///   frame carries the resumption cursor ([endOffset]) once the replay is
///   done.
/// - **Downstream → proxy (input):** raw terminal input is forwarded as raw
///   frames (binary, or text). A *control* frame is a text frame that decodes
///   to a JSON object with a `type` field; today the only control is a
///   resize. Every other frame is raw input to the TUI (protocol 0).
library;

import 'dart:convert';

/// A frame the attach proxy emits to a downstream attacher, in order.
sealed class TerminalFrame {
  const TerminalFrame();
}

/// Raw ANSI output from the PTY: part of the replay or a live frame.
class TerminalOutput extends TerminalFrame {
  const TerminalOutput(this.bytes);

  /// The raw bytes to render (the stream is already rendered by the TUI in
  /// the service's PTY, so this is passthrough).
  final List<int> bytes;

  @override
  String toString() => 'TerminalOutput(${bytes.length} bytes)';
}

/// The replay is complete; [endOffset] is the resumption cursor a re-connecting
/// attacher passes back as its `cursor` (spec §7, §16).
class TerminalReplayComplete extends TerminalFrame {
  const TerminalReplayComplete(this.endOffset);

  final int endOffset;

  @override
  String toString() => 'TerminalReplayComplete($endOffset)';
}

/// A resize request, sent by an attacher whose terminal size is known (the
/// window's attach client). The proxy forwards it to the PTY (spec §16).
class ResizeControl {
  const ResizeControl({required this.cols, required this.rows});

  final int cols;
  final int rows;

  @override
  String toString() => 'ResizeControl(${cols}x$rows)';
}

/// Wire helpers for the frames (shared by the proxy and the attach client).
/// Kept as plain strings so the transport stays a dumb byte pipe.

/// Encodes a resize control frame.
String encodeResize(int cols, int rows) =>
    '{"type":"resize","cols":$cols,"rows":$rows}';

/// Encodes a replay-complete frame carrying the resumption cursor.
String encodeReplayComplete(int endOffset) =>
    '{"type":"replay_complete","endOffset":$endOffset}';

/// Parses a resize control out of a downstream text frame, or `null` when
/// [frame] is not a resize (i.e. it is raw terminal input).
ResizeControl? parseResize(String frame) {
  final map = _controlObject(frame);
  if (map == null || map['type'] != 'resize') return null;
  final cols = (map['cols'] as num?)?.toInt();
  final rows = (map['rows'] as num?)?.toInt();
  if (cols == null || rows == null || cols <= 0 || rows <= 0) return null;
  return ResizeControl(cols: cols, rows: rows);
}

/// Parses the resumption cursor out of a replay-complete frame, or `null`
/// when [frame] is not a replay-complete frame.
int? parseReplayComplete(String frame) {
  final map = _controlObject(frame);
  if (map == null || map['type'] != 'replay_complete') return null;
  return (map['endOffset'] as num?)?.toInt();
}

/// Decodes [frame] into a control object (a JSON object) when it is one,
/// else `null`. A frame that is not valid JSON object is raw input.
Map<String, Object?>? _controlObject(String frame) {
  final trimmed = frame.trim();
  if (trimmed.isEmpty || trimmed[0] != '{') return null;
  try {
    final decoded = jsonDecode(trimmed);
    return decoded is Map<String, Object?> ? decoded : null;
  } catch (_) {
    return null;
  }
}
