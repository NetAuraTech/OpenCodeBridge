import 'dart:async';
import 'dart:convert';

import '../../notify/deep_link.dart';
import '../events/bridge_event.dart';
import '../events/event_hub.dart';
import '../../notify/notify_kind.dart';
import 'notify_service.dart';

/// One event of the hub's stream, decoded to what the routing needs.
class _Event {
  const _Event({
    required this.type,
    required this.data,
    required this.sessionId,
  });

  /// The event `type` (the opencode type or a bridge-native one).
  final String type;

  /// The event's `data` object (the bridge-native `docker.*` payloads).
  final Map<String, Object?> data;

  /// The session id, from `durable.aggregateID` when the event carries a
  /// durable seq, otherwise from `data.sessionID` (every session-scoped
  /// opencode event includes it — `permission.asked` carries no durable
  /// seq), or `null` when the event carries no session.
  final String? sessionId;
}

/// The bridge's push fan-out (issue #24), attached to the event hub as a
/// downstream [EventConnection] alongside the SSE connections: it maps the
/// three push events onto [NotifyService.publish].
///
/// Like an SSE connection it receives every payload the hub fans out
/// (verbatim `data:` strings) and stays attached for the hub's whole
/// lifetime; the per-kind toggle filtering happens in the [NotifyService],
/// so a device with every toggle off simply receives nothing.
class PushDispatcher implements EventConnection {
  PushDispatcher(
    this._service, {
    this.sessionLabel,
  });

  final NotifyService _service;

  /// Resolves a session id to its home-list title for the push body; the
  /// id itself is the fallback (a session the service no longer lists).
  final Future<String> Function(String sessionID)? sessionLabel;

  final Completer<void> _done = Completer<void>();

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> write(String rawPayload) async {
    final event = _parse(rawPayload);
    if (event == null) return;
    switch (event.type) {
      case BridgeEventType.dockerContainerStopped:
      case BridgeEventType.dockerContainerCrashed:
        await _docker(event);
      case 'permission.asked':
      case 'session.execution.succeeded':
      case 'session.execution.failed':
      case 'session.execution.interrupted':
        await _opencode(event);
      default:
        // The stream also carries every other opencode event (text
        // deltas, usage, ...): not a push event.
    }
  }

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  Future<void> _opencode(_Event event) async {
    final sessionId = event.sessionId;
    if (sessionId == null) return;
    final title = switch (event.type) {
      'permission.asked' => 'Permission requested',
      'session.execution.succeeded' => 'Turn finished',
      'session.execution.failed' => 'Turn failed',
      _ => 'Turn interrupted',
    };
    final kind =
        event.type == 'permission.asked'
            ? NotifyKind.permissionAsked
            : NotifyKind.turnEnded;
    await _service.publish(
      kind,
      title: title,
      body: await _label(sessionId),
      link: DeepLink.sessionUri(sessionId).toString(),
    );
  }

  Future<void> _docker(_Event event) async {
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

  _Event? _parse(String rawPayload) {
    Object? decoded;
    try {
      decoded = jsonDecode(rawPayload);
    } catch (_) {
      return null; // A malformed payload is not an event.
    }
    if (decoded is! Map<String, Object?>) return null;
    final type = decoded['type'];
    if (type is! String) return null;
    final data = decoded['data'];
    final dataMap = data is Map<String, Object?> ? data : const <String, Object?>{};
    // The session id: the durable seq when the event carries one, otherwise
    // the `data.sessionID` that session-scoped opencode events include
    // (`permission.asked` carries no durable seq, so this is its only
    // session marker).
    String? sessionId;
    final durable = decoded['durable'];
    if (durable is Map<String, Object?>) {
      final id = durable['aggregateID'];
      if (id is String) sessionId = id;
    }
    if (sessionId == null && dataMap['sessionID'] is String) {
      sessionId = dataMap['sessionID'] as String;
    }
    return _Event(type: type, data: dataMap, sessionId: sessionId);
  }
}
