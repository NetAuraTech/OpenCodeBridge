import 'dart:async';

/// The values of every `data:` field in a Server-Sent Events stream, in order.
///
/// Feed it the stream of decoded text chunks (any chunk size, any framing);
/// it yields one string per `data:` field — the field's value with the single
/// leading space the SSE spec strips, verbatim otherwise. Comment lines (a
/// leading `:`, e.g. the service's `: heartbeat`) and every other field
/// (`event:`, `id:`, ...) are dropped.
///
/// This is the shared seam the bridge's upstream subscription and the app's
/// event client both read an SSE stream through, so a frame is parsed the
/// same way on both ends of the tunnel.
Stream<String> sseDataLines(Stream<String> text) async* {
  final pending = StringBuffer();
  await for (final chunk in text) {
    final buffer = pending.toString() + chunk;
    pending.clear();
    final lines = buffer.split('\n');
    pending.write(lines.removeLast());
    for (final line in lines) {
      final value = _dataValue(_stripCr(line));
      if (value != null) yield value;
    }
  }
  final value = _dataValue(_stripCr(pending.toString()));
  pending.clear();
  if (value != null) yield value;
}

String _stripCr(String line) =>
    line.endsWith('\r') ? line.substring(0, line.length - 1) : line;

/// The value of a `data:` field, or `null` when [line] is not one.
String? _dataValue(String line) {
  if (!line.startsWith('data:')) return null;
  var value = line.substring('data:'.length);
  if (value.startsWith(' ')) value = value.substring(1);
  return value;
}
