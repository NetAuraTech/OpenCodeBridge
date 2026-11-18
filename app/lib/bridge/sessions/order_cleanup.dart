import 'dart:async';

import '../events/bridge_event.dart';
import '../events/event_frame.dart';
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
    final event = parseEventFrame(rawPayload);
    if (event == null) return; // A malformed payload is not an event.
    if (event.type != OpencodeEventType.sessionDeleted &&
        event.type != BridgeEventType.sessionClosed) {
      return; // Not a deletion/closing event.
    }
    final sessionID = event.sessionId;
    if (sessionID == null) return; // A deletion/closing event that names no
    // session is ignored (the envelope resolves the session id; the listener
    // never re-derives it).
    await store.clear(sessionID);
  }

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }
}
