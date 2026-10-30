import 'dart:convert';
import 'dart:math';

/// The event types the bridge itself produces, multiplexed onto the unified
/// `GET /api/events` stream (spec §8). They are not opencode events: they carry
/// no durable seq (so they never collide with the per-session durable `seq`
/// gap detection) and are applied by the app as side-effects keyed on `type`.
abstract class BridgeEventType {
  /// A session was deleted (the app-initiated `DELETE`), so every connected
  /// app drops it from its list.
  static const String sessionClosed = 'session.closed';

  /// A session's attach child exited (its window closed) -> the session is
  /// Closed. (Wired as the window flow lands.)
  static const String terminalClosed = 'terminal.closed';

  /// A container transitioned to stopped (clean). (Wired as Docker lands.)
  static const String dockerContainerStopped = 'docker.container.stopped';

  /// A container exited abnormally (non-zero exit). (Wired as Docker lands.)
  static const String dockerContainerCrashed = 'docker.container.crashed';

  /// The local llama.cpp server's live throughput, from its `/stream` SSE
  /// (the bridge's [LlamaSpeedFeed]). `data` carries `prefill` and `decode`
  /// (each a tok/s number or `null`); at most one is set at a time.
  static const String llamaSpeed = 'llama.speed';
}

/// Build the wire payload for a bridge-native event: the same `data:` envelope
/// shape as an opencode event (`{id, created, type, data}`) but with **no**
/// `durable` field. The returned string is what [EventHub.emit] fans out, so it
/// is written to the stream verbatim as `data: <payload>`.
String bridgeEvent({
  required String type,
  required Map<String, Object?> data,
  String? id,
  int? created,
  Random? random,
}) {
  final payload = <String, Object?>{
    'id': id ?? _eventId(random ?? _random),
    'created': created ?? DateTime.now().millisecondsSinceEpoch,
    'type': type,
    'data': data,
  };
  return jsonEncode(payload);
}

final Random _random = Random();

String _eventId(Random random) =>
    'evt_${random.nextInt(1 << 32).toRadixString(32)}';
