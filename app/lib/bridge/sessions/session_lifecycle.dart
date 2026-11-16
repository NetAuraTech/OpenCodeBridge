import '../events/bridge_event.dart';
import '../events/turn_tracker.dart';

/// The bridge's session-lifecycle module (issue #251, C1 of the turn-outcome
/// series): it owns the **outcome decisions** of a session's per-session
/// lifecycle commands — the decision the route used to make inline.
///
/// C1 moves the *cancel* outcome here. The module composes the three pieces
/// the cancel route used to own:
///
/// - the turn-tracker read (is the session running a turn, and which message
///   is in flight — the [TurnTracker] state re-derived from the event stream);
/// - the service cancel (the interrupt);
/// - the bridge-native `session.turn.cancelled` emission.
///
/// …and returns a typed [CancelOutcome] decision. The route stops deciding: it
/// calls [cancel], translates the decision/errors into a status code, and
/// answers. No turn-tracker snapshot, no event emit, lives in the route.
///
/// The seam is designed for the series (C2, issue #252, will move the *delete*
/// and *order* outcomes here the same way): each outcome is a method that
/// composes its collaborators and returns a small typed outcome, the route
/// translating the outcome to a status code. New outcomes land beside [cancel]
/// by adding a method and its collaborators, without redesigning C1.
class SessionLifecycle {
  SessionLifecycle({required this.serviceCancel, this.turnTracker, this.emit});

  /// The service cancel (the interrupt): the operation the route used to call
  /// directly (`sessions.cancel`). A refusal (e.g. the typed
  /// `CancelUnsupportedError`) propagates unchanged — no outcome is reported
  /// and the turn is left running for the retry.
  final Future<void> Function(String id) serviceCancel;

  /// The bridge's per-session turn state (issue #164), or `null` without an
  /// event hub. Without it the module cannot tell a running turn from an idle
  /// session, so a cancel never reports a running turn (it still cancels).
  final TurnTracker? turnTracker;

  /// Fan a verbatim `data:` payload out to every watcher (the event hub's
  /// `emit`), or `null` without a hub (a cancel then performs the service
  /// cancel but reports nothing to the stream).
  final void Function(String rawPayload)? emit;

  /// Cancel [id]'s running turn (issue #158) and decide its outcome.
  ///
  /// The in-flight state is snapshotted **before** the interrupt: the service
  /// settles a cancelled turn with its own terminal, which flows back through
  /// the event stream and clears the tracker — so whether to report the cancel
  /// (and which message was in flight) must be decided before that. A *running*
  /// turn reports `session.turn.cancelled` carrying the in-flight message id
  /// (when there is one); a *non-running* turn emits no cancel-outcome event.
  /// A service refusal propagates unchanged and reports nothing.
  Future<CancelOutcome> cancel(String id) async {
    final tracker = turnTracker;
    final wasRunning = tracker != null && tracker.isRunning(id);
    final inFlight = tracker?.inFlightMessageID(id);

    // The service cancel (the route's old pass-through). A refusal propagates
    // before any outcome is reported — the turn is left running for the retry.
    await serviceCancel(id);

    if (wasRunning) {
      // Bridge-native `session.turn.cancelled` (issue #164): the outcome of the
      // cancel is reported to every watcher, not only the panel that asked.
      // The in-flight message id, when there is one, rides along.
      final data = <String, Object?>{'sessionID': id};
      if (inFlight != null) data['messageID'] = inFlight;
      emit?.call(bridgeEvent(type: BridgeEventType.turnCancelled, data: data));
      return CancelOutcome(reported: true, messageID: inFlight);
    }
    // An idle session's cancel is a no-op outcome: nothing is emitted.
    return const CancelOutcome(reported: false);
  }
}

/// The cancel's typed decision (issue #251): what the module decided to report
/// about the cancel, for the route to translate into a status code.
///
/// - [reported] is `true` only when the session was running a turn and the
///   module emitted `session.turn.cancelled` (the route answers 204 either way;
///   the decision is about the *event*, not the status).
/// - [messageID] is the in-flight assistant message id carried on the event,
///   or `null` when the turn was running but no message had been named yet.
///
/// The pattern generalizes to the series' other lifecycle outcomes (C2's
/// delete and order), each with its own small outcome type.
class CancelOutcome {
  const CancelOutcome({required this.reported, this.messageID});

  /// `true` when a running turn was reported (a `session.turn.cancelled`
  /// event was emitted), `false` when the cancel reported nothing (an idle
  /// session).
  final bool reported;

  /// The in-flight assistant message id carried on the reported event, or
  /// `null` when there was none (an idle cancel, or a running turn with no
  /// message named yet).
  final String? messageID;
}
