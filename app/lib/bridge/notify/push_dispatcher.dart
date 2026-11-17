import 'dart:async';

import '../../notify/deep_link.dart';
import '../events/bridge_event.dart';
import '../events/event_frame.dart';
import '../events/event_hub.dart';
import '../events/opencode_event_types.dart';
import '../sessions/cancel_dedup.dart';
import '../../notify/notify_kind.dart';
import 'notify_service.dart';

/// The bridge's push fan-out (issue #24), attached to the event hub as a
/// downstream [EventConnection] alongside the SSE connections: it maps the
/// three push events onto [NotifyService.publish].
///
/// Like an SSE connection it receives every payload the hub fans out
/// (verbatim `data:` strings) and stays attached for the hub's whole
/// lifetime; the per-kind toggle filtering happens in the [NotifyService],
/// so a device with every toggle off simply receives nothing.
///
/// The session identity is read from the shared event envelope's [BridgeEvent.
/// sessionId] (the one owner of the session-identity rule, issue #254): the
/// dispatcher decodes each frame with [parseEventFrame] and never re-derives
/// the session id by hand (issue #256, S2c).
class PushDispatcher implements EventConnection {
  PushDispatcher(this._service, {this.sessionLabel});

  final NotifyService _service;

  /// Resolves a session id to its home-list title for the push body; the
  /// id itself is the fallback (a session the service no longer lists).
  final Future<String> Function(String sessionID)? sessionLabel;

  final Completer<void> _done = Completer<void>();

  /// The cancel's follow-on dedup (issues #164, #258): the service settles
  /// a cancelled turn with its own terminal `session.execution.interrupted`,
  /// and this classifier says when that terminal is the follow-on of a
  /// cancel the dispatcher already announced as "Turn stopped" (suppress
  /// it) rather than a genuine interrupt.
  final CancelDedup _dedup = CancelDedup();

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> write(String rawPayload) async {
    final event = parseEventFrame(rawPayload);
    if (event == null) return;
    switch (event.type) {
      case BridgeEventType.dockerContainerStopped:
      case BridgeEventType.dockerContainerCrashed:
        await _docker(event);
        break;
      case BridgeEventType.turnCancelled:
        await _reportCancel(event);
        break;
      case OpencodeEventType.sessionExecutionStarted:
        // A fresh turn: a stale cancel marker (a terminal missed across a
        // restart) must not suppress this turn's later outcomes.
        final id = event.sessionId;
        if (id != null) _dedup.started(id);
        break;
      case OpencodeEventType.permissionAsked:
      case OpencodeEventType.sessionExecutionSucceeded:
      case OpencodeEventType.sessionExecutionFailed:
      case OpencodeEventType.sessionExecutionInterrupted:
        await _opencode(event);
        break;
      default:
      // The stream also carries every other opencode event (text
      // deltas, usage, ...): not a push event.
    }
  }

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  /// The bridge-native `session.turn.cancelled` (issue #164): the cancel is
  /// announced as "Turn stopped" — not reusing "Turn failed" or "Turn
  /// interrupted". The session is remembered so its service-settled terminal
  /// (`session.execution.interrupted`) is not re-announced as an interrupt.
  Future<void> _reportCancel(BridgeEvent event) async {
    final sessionId = event.sessionId;
    if (sessionId == null) return;
    _dedup.cancelled(sessionId);
    await _service.publish(
      NotifyKind.turnEnded,
      title: 'Turn stopped',
      body: await _label(sessionId),
      link: DeepLink.sessionUri(sessionId).toString(),
    );
  }

  Future<void> _opencode(BridgeEvent event) async {
    final sessionId = event.sessionId;
    if (sessionId == null) return;
    if (event.type == OpencodeEventType.sessionExecutionInterrupted &&
        _dedup.isCancelledFollowOn(sessionId)) {
      // The cancel already reported this turn's end as "Turn stopped": its
      // service terminal is the same stop, not a new outcome.
      return;
    }
    final title = switch (event.type) {
      OpencodeEventType.permissionAsked => 'Permission requested',
      OpencodeEventType.sessionExecutionSucceeded => 'Turn finished',
      OpencodeEventType.sessionExecutionFailed => 'Turn failed',
      _ => 'Turn interrupted',
    };
    final kind = event.type == OpencodeEventType.permissionAsked
        ? NotifyKind.permissionAsked
        : NotifyKind.turnEnded;
    await _service.publish(
      kind,
      title: title,
      body: await _label(sessionId),
      link: DeepLink.sessionUri(sessionId).toString(),
    );
  }

  Future<void> _docker(BridgeEvent event) async {
    final name = event.data['name'];
    if (name is! String || name.isEmpty) return;
    final link = DeepLink.containerUri(name).toString();
    if (event.type == BridgeEventType.dockerContainerStopped) {
      await _service.publish(
        NotifyKind.dockerContainer,
        title: 'Container stopped',
        body: name,
        link: link,
      );
    } else {
      final exitCode = event.data['exitCode'];
      await _service.publish(
        NotifyKind.dockerContainer,
        title: 'Container crashed',
        body: exitCode is int ? '$name (exit $exitCode)' : name,
        link: link,
      );
    }
  }

  Future<String> _label(String sessionId) async {
    final labeler = sessionLabel;
    if (labeler == null) return sessionId;
    try {
      return await labeler(sessionId);
    } catch (_) {
      // The service is unreachable: the id is a fine body fallback.
      return sessionId;
    }
  }
}
