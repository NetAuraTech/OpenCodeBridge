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
/// three push events onto [NotifyService.send].
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
  PushDispatcher(this._service, {this.sessionLabel, this.afkSession});

  final NotifyService _service;

  /// Resolves a session id to its home-list title for the push body; the
  /// id itself is the fallback (a session the service no longer lists).
  final Future<String> Function(String sessionID)? sessionLabel;

  /// Resolves **a repo's** AFK session id (spec #376, T5; per repo by
  /// spec #407, T3) — the deep-link target of the terminal-failure push:
  /// the failure deep-links to the **failed run's repo's** AFK session
  /// (in-app) so the human reads that agent's `FAILED` narration in place.
  /// The closure receives the repo identity (the `afk.failed` event carries
  /// it) and answers the stored session id for that repo. `null` (no AFK
  /// session stored for the repo — not armed, or no shared opencode
  /// service) — the failure push is then not sent (there is nowhere to go).
  final Future<String?> Function(String repo)? afkSession;

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
      case BridgeEventType.afkPrOpen:
        await _afkPrOpen(event);
        break;
      case BridgeEventType.afkFailed:
        await _afkFailed(event);
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
    await _service.send(
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
    await _service.send(
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
      await _service.send(
        NotifyKind.dockerContainer,
        title: 'Container stopped',
        body: name,
        link: link,
      );
    } else {
      final exitCode = event.data['exitCode'];
      await _service.send(
        NotifyKind.dockerContainer,
        title: 'Container crashed',
        body: exitCode is int ? '$name (exit $exitCode)' : name,
        link: link,
      );
    }
  }

  /// An AFK run reached `pr-open` (spec #376, T5): one high-priority
  /// `afkRun` push — "look now", the human-review boundary. The deep-link is
  /// the PR's GitHub URL, opened in the **external browser** (the app opens
  /// an external deep link on tap, beside its in-app session/container links).
  /// No push without the issue's identity or a PR url (the deep-link *is*
  /// the PR).
  Future<void> _afkPrOpen(BridgeEvent event) async {
    final issue = _afkIssue(event);
    if (issue == null) return;
    final prUrl = event.data['prUrl'];
    if (prUrl is! String || prUrl.isEmpty) return;
    await _service.send(
      NotifyKind.afkRun,
      title: 'AFK run : PR ouverte',
      body: _afkBody(issue.$1, issue.$2),
      link: DeepLink.externalUri(prUrl).toString(),
      highPriority: true,
    );
  }

  /// An AFK run reached `failed` (spec #376, T5; the deep-link is per repo by
  /// spec #407, T3): one high-priority `afkRun` push — "look now", a human
  /// decision is wanted. The deep-link is the **failed run's repo's AFK
  /// session** (in-app), so the human reads that agent's `FAILED` narration
  /// in place. The repo identity comes from the event's data (spec #407: the
  /// `afk.failed` event is repo-scoped — emitted by the run service with the
  /// row's repo, T4); the resolver is handed that repo and answers the
  /// repo's stored AFK session id, read live at push time. No push without an
  /// AFK session to point at — the repo-less event (a repo the bridge has no
  /// stored session for) resolves to `null` ⇒ no push (there is nowhere for
  /// the human to go, spec #407: "no session for that repo ⇒ no push").
  Future<void> _afkFailed(BridgeEvent event) async {
    final issue = _afkIssue(event);
    if (issue == null) return;
    final resolver = afkSession;
    if (resolver == null) return;
    // The event's repo identity (spec #407, T4's repo-scoped events); a
    // repo-less event (an empty repo) names no repo, and the resolver
    // answers no session for it — `null` ⇒ no push.
    final repo = event.data['repo'];
    String? sessionId;
    try {
      sessionId = await resolver(repo is String && repo.isNotEmpty ? repo : '');
    } catch (_) {
      // The resolution is best-effort: a failure is not a push.
      return;
    }
    if (sessionId == null || sessionId.isEmpty) return;
    await _service.send(
      NotifyKind.afkRun,
      title: 'AFK run : échec',
      body: '${_afkBody(issue.$1, issue.$2)} — needs-triage',
      link: DeepLink.sessionUri(sessionId).toString(),
      highPriority: true,
    );
  }

  /// The AFK push's issue identity `(title, number)`, or `null` when the
  /// event names no issue (not a push): both must be present for the body's
  /// `"<title> · #<n>"` to be meaningful.
  (String title, int number)? _afkIssue(BridgeEvent event) {
    final title = event.data['title'];
    final number = event.data['issueNumber'];
    if (title is! String || title.isEmpty) return null;
    if (number is! int) return null;
    return (title, number);
  }

  /// The AFK push's body: `"<issue title> · #<n>"`.
  String _afkBody(String title, int number) => '$title · #$number';

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
