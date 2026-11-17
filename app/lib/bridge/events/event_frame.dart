import 'dart:convert';

/// The durable position of an opencode event within its session aggregate.
/// [aggregateID] is the session id; [seq] increases by one per event for that
/// session, so a jump in [seq] means events were missed (a gap).
class Durable {
  const Durable({required this.aggregateID, required this.seq});

  /// The session aggregate the event belongs to (`durable.aggregateID`).
  final String aggregateID;

  /// The per-session sequence number (`durable.seq`).
  final int seq;
}

/// One event of the bridge's unified `GET /api/events` stream, decoded.
///
/// Both opencode events and bridge-native events (`session.closed`, `docker.*`)
/// arrive on the same stream in the same
/// `data: {id, created, type, data[, durable]}` envelope. Bridge-native events
/// (and opencode's own non-durable ones, e.g. `server.connected`) carry no
/// [durable], so they never participate in per-session seq gap detection.
///
/// The class lives in the bridge layer (not `client/`) because the bridge's
/// own event connections — the [TurnTracker] and the [PushDispatcher] —
/// consume it directly, and the bridge must not depend on the client
/// (ADR-0001). The client re-exports it, so the app-side public surface is
/// unchanged.
class BridgeEvent {
  const BridgeEvent({
    required this.id,
    required this.created,
    required this.type,
    required this.data,
    this.durable,
  });

  final String id;
  final int created;
  final String type;

  /// The event's payload (`data`), e.g. the session/step details.
  final Map<String, Object?> data;

  /// The durable position, or `null` when the event carries no seq.
  final Durable? durable;

  /// The session this event belongs to, resolved across every shape the
  /// stream carries: the durable aggregate id (every session-scoped opencode
  /// event carries one), else `data.sessionID` (the bridge-native events and
  /// opencode's non-durable ones, e.g. `permission.asked`), else the `form`'s
  /// nested session id (`form.created` nests its session under `data.form`),
  /// else `null` (a non-session event, e.g. `server.connected`).
  ///
  /// This is the one owner of the session-identity rule (issue #254, S2): the
  /// bridge-side consumers ([TurnTracker], [PushDispatcher]) and the client
  /// all read it from here instead of re-deriving it.
  String? get sessionId {
    final durable = this.durable;
    if (durable != null) return durable.aggregateID;
    final data = this.data;
    final id = data['sessionID'];
    if (id is String && id.isNotEmpty) return id;
    final form = data['form'];
    if (form is Map<String, Object?>) {
      final nested = form['sessionID'];
      if (nested is String && nested.isNotEmpty) return nested;
    }
    return null;
  }
}

/// Decode one verbatim `data:` payload into a [BridgeEvent], or `null` when it
/// is not a well-formed event frame (malformed JSON, not a JSON object, or a
/// non-String `type`).
///
/// This is the one wire-payload → envelope decode for the bridge-side event
/// connections (issue #256, S2c): the [TurnTracker] and [PushDispatcher] share
/// it instead of each carrying a private parse. It mirrors the client's
/// `parseBridgeEvent` decode exactly, so the two halves of the stream read the
/// same way.
///
/// Tolerances (a frame the consumers already accept):
/// - a missing `id`, `created`, or `data` defaults to `''`, `0`, and the empty
///   map respectively;
/// - a `durable` object that is missing `seq` (or whose `aggregateID` is not a
///   String) is dropped to `null` — the event then resolves its session id from
///   `data.sessionID` instead.
///
/// The `type` must be a String for the frame to be an event at all: a missing
/// or non-String `type` yields a frame with `type: ''`, which a consumer
/// treats as "not one of the known events" (its default/ignore arm).
BridgeEvent? parseEventFrame(String payload) {
  Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } catch (_) {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  final id = decoded['id'] is String ? decoded['id'] as String : '';
  final created = (decoded['created'] as num?)?.toInt() ?? 0;
  final type = decoded['type'] is String ? decoded['type'] as String : '';
  final data = decoded['data'] is Map<String, Object?>
      ? decoded['data'] as Map<String, Object?>
      : const <String, Object?>{};
  Durable? durable;
  final d = decoded['durable'];
  if (d is Map<String, Object?>) {
    final aggregateID = d['aggregateID'] is String
        ? d['aggregateID'] as String
        : null;
    final seq = (d['seq'] as num?)?.toInt();
    if (aggregateID != null && seq != null) {
      durable = Durable(aggregateID: aggregateID, seq: seq);
    }
  }
  return BridgeEvent(
    id: id,
    created: created,
    type: type,
    data: data,
    durable: durable,
  );
}
