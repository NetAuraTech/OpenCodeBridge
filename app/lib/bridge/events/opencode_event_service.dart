import 'dart:async';

/// One opencode event exactly as the shared service's `GET /api/event`
/// stream delivers it. The bridge re-emits [raw] verbatim, so [raw] is the
/// single source of truth for the wire bytes; the parsed fields exist so the
/// bridge and its tests can reason about the event without re-parsing.
class OpencodeEvent {
  const OpencodeEvent({
    required this.raw,
    required this.type,
    this.aggregateID,
    this.seq,
  });

  /// The verbatim JSON payload of the event's `data:` line (what the bridge
  /// writes back out as `data: <raw>`).
  final String raw;

  /// The event `type`, e.g. `session.execution.started`.
  final String type;

  /// The durable aggregate id (`durable.aggregateID`) — the session id — or
  /// `null` when the event carries no durable seq (e.g. `server.connected`).
  final String? aggregateID;

  /// The durable per-session sequence (`durable.seq`), or `null` when absent.
  final int? seq;
}

/// A failure talking to the shared opencode service's event stream, carrying
/// the service's HTTP status so the bridge can reason about it (a transport
/// failure is status 0).
class OpencodeEventServiceError implements Exception {
  const OpencodeEventServiceError(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'OpencodeEventServiceError($statusCode: $message)';
}

/// The bridge's seam over the shared opencode service's event stream
/// (ADR-0001: the app never talks to the service directly; the bridge holds
/// the single upstream subscription). The bridge holds **exactly one**
/// upstream `GET /api/event` subscription (the full type enum) and reads it
/// through [events].
///
/// The stream is self-healing: if the connection drops — including an
/// opencode service restart — the service re-subscribes and keeps emitting,
/// so the bridge survives the service restart without losing the stream.
abstract class OpencodeEventService {
  /// The single upstream event subscription. Emits [OpencodeEvent] until
  /// [close]; auto-reconnects across service restarts.
  Stream<OpencodeEvent> get events;

  /// Stop the subscription and release the upstream connection.
  Future<void> close();
}
