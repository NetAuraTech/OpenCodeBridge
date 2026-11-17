import 'dart:async';

import 'bridge_event.dart';
import 'event_frame.dart';
import 'event_hub.dart';
import 'opencode_event_types.dart';

/// The bridge's per-session turn state, re-derived from the unified event
/// stream (issue #164): which sessions are running a turn right now, and —
/// while one is — the assistant message id that is in flight.
///
/// Why the event stream and not the service's active list: `/api/session/
/// active` lists TUI-attached sessions only (research, "Fact — GET
/// /api/session/active scope"), so it never reflects an API-driven session
/// the app is controlling. The bridge already holds the single upstream
/// subscription (the [EventHub] fans it out to the app), so it tracks the turn
/// off the same `session.execution.*` boundary events and the
/// `assistantMessageID` those events name. A turn opens on
/// `session.execution.started` and closes on any terminal
/// `session.execution.*` — or on the bridge's own `session.turn.cancelled`
/// (so a cancel reads the session idle again, with no feedback loop).
///
/// The session identity is read from the shared event envelope's [BridgeEvent.
/// sessionId] (the one owner of the session-identity rule, issue #254): the
/// tracker decodes each frame with [parseEventFrame] and never re-derives the
/// session id by hand (issue #256, S2c).
///
/// The session-lifecycle module ([SessionLifecycle], issue #251) reads this
/// when it carries out a stop: a running turn carries the in-flight message
/// id into the `session.turn.cancelled` event; an idle session is not
/// reported at all.
class TurnTracker implements EventConnection {
  final Completer<void> _done = Completer<void>();
  final Map<String, _Turn> _turns = {};

  @override
  Future<void> get done => _done.future;

  /// Whether [sessionID] is running a turn right now.
  bool isRunning(String sessionID) => _turns[sessionID]?.running ?? false;

  /// The assistant message id in flight for [sessionID]'s running turn, or
  /// `null` when the turn is idle or no message has been named yet.
  String? inFlightMessageID(String sessionID) => _turns[sessionID]?.messageID;

  @override
  Future<void> write(String rawPayload) async {
    final event = parseEventFrame(rawPayload);
    if (event == null) return;
    final sessionID = event.sessionId;
    if (sessionID == null) return;
    final turn = _turns.putIfAbsent(sessionID, _Turn.new);
    switch (event.type) {
      case OpencodeEventType.sessionExecutionStarted:
        // A fresh turn: running, no message named until the stream names one.
        turn.running = true;
        turn.messageID = null;
      case OpencodeEventType.sessionExecutionSucceeded:
      case OpencodeEventType.sessionExecutionFailed:
      case OpencodeEventType.sessionExecutionInterrupted:
      case BridgeEventType.turnCancelled:
        // The turn ended (a terminal outcome, or our own cancel event): the
        // in-flight message is no longer in flight.
        turn.running = false;
        turn.messageID = null;
      default:
        // A streaming event (a step, a text/reasoning delta, a tool) names
        // the in-flight assistant message while the turn runs: the last one
        // wins, so the cancel reports the message in flight.
        final messageID = event.data['assistantMessageID'];
        if (turn.running && messageID is String && messageID.isNotEmpty) {
          turn.messageID = messageID;
        }
    }
  }

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }
}

class _Turn {
  var running = false;
  String? messageID;
}
