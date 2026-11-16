import 'dart:async';
import 'dart:convert';

import '../events/bridge_event.dart';
import '../events/event_hub.dart';
import '../events/opencode_event_types.dart';
import 'order_store.dart';

/// The bridge-internal listener that keeps the order store honest (issue
/// #292): when the bridge observes a session being deleted or closed, it
/// removes that session's position from the order store.
///
/// Why the event stream: a list read no longer prunes the order map (issue
/// #292) — a session invisible on one read (a stopped / waking orb, a
/// degraded pass, the boot window) must keep its pin. The only remaining way
/// an entry becomes stale is the session actually going away, so the cleanup
/// is event-driven, tapping the same unified stream the [TurnTracker] does
/// (the [EventHub] fans the single upstream subscription out to both). The
/// two events that name a session leaving are the service-side
/// [OpencodeEventType.sessionDeleted] (durable, the aggregate id names the
/// session) and the bridge-native [BridgeEventType.sessionClosed]
/// (`data.sessionID`, no durable seq).
///
/// A deletion the bridge never observes may leave an inert entry — the
/// accepted, bounded documented limit (issue #292).
class OrderStoreCleanup implements EventConnection {
  OrderStoreCleanup({required this.store});

  final SessionOrderStore store;
  final Completer<void> _done = Completer<void>();

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> write(String rawPayload) async {
    final sessionID = _sessionID(rawPayload);
    if (sessionID == null) return;
    await store.clear(sessionID);
  }

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  /// The session id to clean, or `null` when the payload is not one of the
  /// two deletion/closing events (or is malformed) — the listener ignores
  /// everything else and never throws. The session id is read exactly the way
  /// [TurnTracker] does: the durable aggregate id when the event carries one,
  /// otherwise the `data.sessionID` the bridge-native events carry.
  String? _sessionID(String rawPayload) {
    Object? decoded;
    try {
      decoded = jsonDecode(rawPayload);
    } catch (_) {
      return null; // A malformed payload is not an event.
    }
    if (decoded is! Map<String, Object?>) return null;
    final type = decoded['type'];
    if (type is! String) return null;
    if (type != OpencodeEventType.sessionDeleted &&
        type != BridgeEventType.sessionClosed) {
      return null; // Not a deletion/closing event.
    }
    final data = decoded['data'] is Map<String, Object?>
        ? decoded['data'] as Map<String, Object?>
        : const <String, Object?>{};
    String? sessionID;
    final durable = decoded['durable'];
    if (durable is Map<String, Object?>) {
      final id = durable['aggregateID'];
      if (id is String) sessionID = id;
    }
    if (sessionID == null && data['sessionID'] is String) {
      sessionID = data['sessionID'] as String;
    }
    return sessionID;
  }
}
