import 'dart:io';

import '../../model/command.dart';
import '../../model/message.dart';
import '../../model/permission.dart';
import '../../model/question.dart';
import '../../model/session.dart';
import '../../model/session_detail.dart';
import 'opencode_service.dart';
import 'order_store.dart';

/// The bridge's sessions backend (spec §5 endpoints 1 & 4, §6): it owns the
/// [OpencodeService] seam and composes it into the home-list rows.
///
/// - [list] merges the service session list and the service's active list,
///   pinned-first (issue #237: the pinned block position ascending, then the
///   unpinned newest-created).
/// - [create] creates the session on the service (spec §5 fill-in †).
/// - [delete] performs the service `DELETE`.
/// - [setOrder] / [clearOrder] move the session's position in the bridge's
///   app-owned order store (issue #237, the home list's user-controlled
///   display order).
class SessionsBackend {
  SessionsBackend({required this.service, this.orderStore});

  final OpencodeService service;

  /// The bridge's order store (issue #237): the persisted `sessionID ->
  /// position` map behind the home list's pinned-first sort. `null` when the
  /// bridge has no order store wired (the list falls back to the plain
  /// newest-created order). Mutable: the bridge's start wires it into a
  /// caller-provided backend after construction.
  SessionOrderStore? orderStore;

  /// The service's project list (spec §5 fill-in †): what the app's project
  /// picker offers and what [create] takes as its only parameter.
  Future<List<OpencodeProject>> projects() => service.projects();

  /// Create a session (spec §5 fill-in †): the service `POST /api/session`
  /// in [projectId]'s project. The bridge applies the current/default model
  /// (including its thinking level / variant) so the new session shows its
  /// model like one created directly in opencode. The agent is not passed —
  /// the service picks its default (a fresh session starts on the default
  /// agent, not the previous session's, which may be a restricted subagent).
  Future<Session> create(String projectId) async {
    final model = await _defaultModel();
    final session = await service.createSession(projectId, model: model);
    await _applyDefaultModel(session.id, model);
    final names = await service.projectNames();
    final active = await service.activeSessionIds();
    return _row(session, names, active);
  }

  /// Create a session at [directory] (issue #54's "New project"):
  /// [directory] is the working directory as-is, and the service auto-creates
  /// a project for a directory it has never seen. A [directory] missing on
  /// this host is a clear 404, not a service round-trip. The bridge applies
  /// the current/default model (including its thinking level / variant). The
  /// agent is not passed — the service picks its default, as in [create].
  Future<Session> createInDirectory(String directory) async {
    if (!Directory(directory).existsSync()) {
      throw const OpencodeServiceError(
        HttpStatus.notFound,
        'no such directory',
      );
    }
    final model = await _defaultModel();
    final session = await service.createSessionInDirectory(
      directory,
      model: model,
    );
    await _applyDefaultModel(session.id, model);
    final names = await service.projectNames();
    final active = await service.activeSessionIds();
    return _row(session, names, active);
  }

  /// The model (with its thinking level / variant) to apply to a new
  /// session: copied from the most recently created session that already has
  /// a model, which mirrors opencode's "current model" behavior. The agent
  /// is deliberately not carried over — it is a per-session explicit choice,
  /// and inheriting the previous session's (which may be a restricted
  /// subagent) is exactly what a fresh session in opencode does not do.
  /// Best-effort — a lookup failure yields no default rather than failing
  /// the create.
  Future<ModelRef?> _defaultModel() async {
    try {
      final sessions = await service.listSessions();
      sessions.sort((a, b) => b.created.compareTo(a.created));
      for (final candidate in sessions.take(8)) {
        try {
          final detail = await service.getDetail(candidate.id);
          if (detail.model != null) {
            return detail.model;
          }
        } catch (_) {
          // Try the next candidate.
        }
      }
    } catch (_) {
      // No default available; the session is still created.
    }
    return null;
  }

  /// Ensures [id] carries [model] (including its variant / thinking level)
  /// after creation. The model is passed on create and also set explicitly,
  /// so the session shows its model even when the service ignores the
  /// create-time model field. Best-effort — never fails the create.
  Future<void> _applyDefaultModel(String id, ModelRef? model) async {
    if (model == null) return;
    try {
      await service.setModel(id, model);
    } catch (_) {
      // The model was also passed on create; if neither stuck the session
      // still exists and the user can pick a model.
    }
  }

  /// Whether the service still has [id] (the reopen guard).
  Future<bool> exists(String id) async {
    final sessions = await service.listSessions();
    for (final session in sessions) {
      if (session.id == id) return true;
    }
    return false;
  }

  /// The home-list rows (spec §5 endpoint 1, §6), pinned-first (issue #237):
  /// the pinned block (a position set in the bridge's order store) in
  /// position ascending order, then the unpinned newest-created (the plain
  /// order's sort). Each row carries its waiting fact, re-evaluated per
  /// session from the service's pending states (issue #208), and its pinned
  /// fact, derived from the order store (issue #237). The store's map is
  /// pruned to the live session ids on the read (no orphan growth).
  /// A store failure degrades the read to the unpinned order — the list
  /// itself stays up, like the waiting fact's degraded-orb posture.
  Future<List<Session>> list() async {
    final sessions = await service.listSessions();
    final names = await service.projectNames();
    final active = await service.activeSessionIds();
    // Every session is evaluated — including ones the service no longer marks
    // active (during a block it may have dropped out of the active list while
    // the pending request still stands).
    final waiting = await Future.wait([
      for (final session in sessions) _waiting(session.id),
    ]);

    // The bridge-owned order map (issue #237), pruned to the live ids; a
    // store failure degrades the list to the unpinned order.
    final orderStore = this.orderStore;
    Map<String, num> positions = const {};
    if (orderStore != null) {
      try {
        positions = orderStore.load();
        await orderStore.prune({for (final s in sessions) s.id});
      } catch (_) {
        positions = const {};
      }
    }

    final rows = [
      for (var i = 0; i < sessions.length; i++)
        _row(
          sessions[i],
          names,
          active,
          waiting: waiting[i],
          pinned: positions.containsKey(sessions[i].id),
        ),
    ];
    rows.sort((a, b) => homeListOrder(a, b, (id) => positions[id]));
    return rows;
  }

  /// The home list's sort comparator (issue #237): the pinned rows first, in
  /// position ascending order (a position tie breaks by created descending,
  /// the unpinned order), then the unpinned rows in created descending order.
  /// [positionOf] answers a row's position (`null` = unpinned); it is the
  /// store's map lookup, injected so the comparator is unit-testable on its
  /// own.
  static int homeListOrder(
    Session a,
    Session b,
    num? Function(String id) positionOf,
  ) {
    final posA = positionOf(a.id);
    final posB = positionOf(b.id);
    if (posA != null && posB != null) {
      final byPosition = posA.compareTo(posB);
      if (byPosition != 0) return byPosition;
      return b.created.compareTo(a.created);
    }
    if (posA != null) return -1; // Pinned before unpinned.
    if (posB != null) return 1;
    return b.created.compareTo(a.created);
  }

  /// Set [id]'s position in the order store (issue #237): the session joins
  /// the home list's pinned block.
  Future<void> setOrder(String id, num position) =>
      orderStore!.set(id, position);

  /// Clear [id]'s position in the order store (issue #237): the session
  /// returns to the unpinned newest-created order.
  Future<void> clearOrder(String id) => orderStore!.clear(id);

  /// The row's waiting fact (issue #208): whether the service still holds a
  /// pending permission request for [id], or, when it holds none, a pending
  /// question form. The question lookup runs only when the permission lookup
  /// answered empty (a waiting session already has its answer). A failed
  /// lookup degrades this session only — its fact stays false and the rest of
  /// the list is intact, the same posture [CompositeOpencodeService] takes
  /// for a degraded orb's routes.
  Future<bool> _waiting(String id) async {
    try {
      final permissions = await service.pendingPermissions(id);
      if (permissions.isNotEmpty) return true;
      return (await service.pendingQuestions(id)).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Delete (spec §5 endpoint 4): the service `DELETE`.
  Future<void> delete(String id) => service.deleteSession(id);

  // The structured-view reads/writes (spec §5, endpoints 5–9) are pure
  // pass-throughs to the service seam, so they are exposed directly.
  Future<SessionDetail> getDetail(String id) => service.getDetail(id);

  /// The detail endpoint's read (issue #124): the session's detail plus its
  /// live Active fact (the service's active list), which the structured
  /// view's live turn footer needs when the persisted history alone is
  /// ambiguous. Kept off [getDetail] proper: the structured view's plain
  /// detail read stays a single round-trip. The orb task watcher reads this
  /// one (issue #169): settling an outcome-less session needs the Active
  /// fact — a session idle and outcome-less has ended its turn, an active
  /// one is merely between steps.
  Future<SessionDetail> detailWithActive(String id) async {
    final detail = await service.getDetail(id);
    final active = await service.activeSessionIds();
    // The cancel capability (issue #165): whether the routed service (host
    // or the owning orb) can interrupt the turn. It rides the same detail
    // read as [active], so the structured view learns it with the open. A
    // lookup failure reads as capable: a wrongly-offered Stop still lands a
    // clean, reportable 502 and stays offered to retry.
    final canCancel = await _canCancel(id);
    return detail.copyWithActive(active.contains(id), canCancel: canCancel);
  }

  /// The routed service's interrupt capability for [id] (issue #165), read
  /// without cancelling (a probe would interrupt the live turn).
  Future<bool> _canCancel(String id) async {
    try {
      return await service.canCancelTurn(id);
    } catch (_) {
      // The capability is a display fact, not a failure of the read: assume
      // capable so a Stop is offered and, if truly unsupported, answers a
      // reportable 502 the user can retry from.
      return true;
    }
  }

  Future<List<SessionMessage>> getMessages(String id) =>
      service.getMessages(id);

  Future<MessagePage> getMessagesPage(
    String id, {
    int limit = 50,
    String? cursor,
  }) => service.getMessagesPage(id, limit: limit, cursor: cursor);

  Future<void> prompt(
    String id,
    String text, {
    List<Map<String, Object?>>? files,
    List<Map<String, Object?>>? skills,
  }) => service.prompt(id, text, files: files, skills: skills);

  Future<List<PermissionRequest>> pendingPermissions(String id) =>
      service.pendingPermissions(id);

  Future<void> replyPermission(
    String id,
    String requestID,
    PermissionReply reply,
  ) => service.replyPermission(id, requestID, reply);

  // The structured view's question forms (issue #50): pure pass-throughs to
  // the service seam, like endpoints 5–9.
  Future<List<QuestionForm>> pendingQuestions(String id) =>
      service.pendingQuestions(id);

  Future<void> answerQuestion(
    String id,
    String formID,
    List<List<String>> answers,
  ) => service.answerQuestion(id, formID, answers);

  Future<void> dismissQuestion(String id, String formID) =>
      service.dismissQuestion(id, formID);

  // The structured view's `/` command menu (issue #46): the service-backed
  // commands, pure pass-throughs to the service seam (like endpoints 5–9).

  Future<List<OpencodeCommand>> listCommands() => service.listCommands();

  Future<void> runCommand(String id, String name, String text) =>
      service.runCommand(id, name, text);

  Future<List<ModelOption>> listModels() => service.listModels();

  Future<ModelRef?> currentModel(String id) => service.currentModel(id);

  Future<void> setModel(String id, ModelRef model) =>
      service.setModel(id, model);

  Future<List<AgentOption>> listAgents() => service.listAgents();

  Future<void> setAgent(String id, String agentId) =>
      service.setAgent(id, agentId);

  Future<List<SkillOption>> listSkills() => service.listSkills();

  Future<void> activateSkill(String id, String skillId) =>
      service.activateSkill(id, skillId);

  Future<void> compact(String id) => service.compact(id);

  /// Cancel the session's running turn (issue #158): a pass-through to the
  /// service's interrupt.
  Future<void> cancel(String id) => service.cancelTurn(id);

  Future<void> undo(String id) => service.undo(id);

  Future<void> redo(String id) => service.redo(id);

  Future<String> fork(String id) => service.fork(id);

  Future<void> rename(String id, String title) => service.rename(id, title);

  Future<String> exportSession(String id) => service.exportSession(id);

  Future<void> move(String id, String directory) => service.move(id, directory);

  Future<String> generate(String id, String prompt) =>
      service.generate(id, prompt);

  Future<String> diff(String id) => service.diff(id);

  Future<String> stats(String id) => service.stats(id);

  Future<String> worktrees(String sessionId) => service.worktrees(sessionId);

  Future<List<String>> findFiles(String id, String query) =>
      service.findFiles(id, query);

  Future<String> usage() => service.usage();

  Future<String> mcps() => service.mcps();

  Future<String> integrations() => service.integrations();

  Future<String> connectIntegration(String integrationId, String methodId) =>
      service.connectIntegration(integrationId, methodId);

  Future<String> status() => service.status();

  Future<String> pair() => service.pair();

  Future<void> reload() => service.reload();

  Future<String> plugins() => service.plugins();

  /// One home-list row, from the service's session plus its project name,
  /// active fact, waiting fact (issue #208), and pinned fact (issue #237).
  Session _row(
    OpencodeSession s,
    Map<String, String> names,
    Set<String> active, {
    bool waiting = false,
    bool pinned = false,
  }) {
    return Session(
      id: s.id,
      title: s.title,
      project: SessionProject(
        id: s.projectId,
        name: names[s.projectId] ?? s.projectId,
      ),
      created: s.created,
      location: s.location,
      active: active.contains(s.id),
      orb: s.orb,
      waiting: waiting,
      pinned: pinned,
    );
  }
}
