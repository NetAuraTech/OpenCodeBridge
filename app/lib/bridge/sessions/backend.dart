import '../../model/command.dart';
import '../../model/message.dart';
import '../../model/permission.dart';
import '../../model/session.dart';
import '../../model/session_detail.dart';
import 'opencode_service.dart';
import 'reconcile.dart';
import 'session_store.dart';

/// The bridge's sessions backend (spec §5 endpoints 1 & 4, §6, §11): it owns
/// the [OpencodeService] seam, the [SessionStore] persistence, and the
/// in-process "live" fact, and composes them into the home-list rows.
///
/// - [list] merges the service session list, the persistence classification,
///   and the service's active list, newest first.
/// - [create] is the new-session flow's service + persistence half (spec §11
///   write #1); the window half is the [TerminalWindowManager]'s.
/// - [delete] performs the service `DELETE` and, in the same action, removes
///   the persistence record.
/// - [reconcile] is the startup orphan reconciliation.
class SessionsBackend {
  SessionsBackend({
    required this.service,
    required this.store,
    Set<String>? liveSessionIds,
  }) : liveSessionIds = liveSessionIds ?? <String>{};

  final OpencodeService service;
  final SessionStore store;

  /// In-process fact (spec §6/§11): the sessions whose attach child is alive
  /// in this bridge process. "Live is an in-process fact"; the window manager
  /// flips a session in/out of this set as its terminal window opens/closes,
  /// after which those sessions classify as [SessionClassification.appLaunchedLive].
  final Set<String> liveSessionIds;

  /// Startup reconciliation (spec §11 write #3): drops persistence records
  /// whose session no longer exists on the service, rewriting only on change.
  Future<void> reconcile() async {
    final sessions = await service.listSessions();
    await reconcileOrphans(store, sessions.map((s) => s.id).toSet());
  }

  /// The service's project list (spec §5 fill-in †): what the app's project
  /// picker offers and what [create] takes as its only parameter.
  Future<List<OpencodeProject>> projects() => service.projects();

  /// Create a session (spec §5 fill-in †, §11 write #1): the service
  /// `POST /api/session` in [projectId]'s project, then the persistence "add
  /// id" write — `store.add` + `store.save`, at launch.
  ///
  /// The in-process live fact is flipped by the window manager when the
  /// session's terminal window opens, so the returned row classifies
  /// [SessionClassification.appLaunchedClosed] until then.
  Future<Session> create(String projectId) async {
    final session = await service.createSession(projectId);
    store.add(session.id);
    await store.save();
    final names = await service.projectNames();
    final active = await service.activeSessionIds();
    return _row(session, names, active);
  }

  /// Whether [id] has a persistence record (it was app-launched by this
  /// bridge, spec §11).
  bool isAppLaunched(String id) => store.has(id);

  /// Whether the service still has [id] (the reopen guard: a session gone
  /// from the service has no terminal to open a window on).
  Future<bool> exists(String id) async {
    final sessions = await service.listSessions();
    for (final session in sessions) {
      if (session.id == id) return true;
    }
    return false;
  }

  /// The merged home-list rows, newest first (spec §5 endpoint 1, §6).
  Future<List<Session>> list() async {
    final sessions = await service.listSessions();
    final names = await service.projectNames();
    final active = await service.activeSessionIds();

    final rows = <Session>[for (final s in sessions) _row(s, names, active)];
    rows.sort((a, b) => b.created.compareTo(a.created));
    return rows;
  }

  /// Delete (spec §5 endpoint 4, §11 write #2): the service deletion and the
  /// persistence-record removal happen in the same action. (Closing the
  /// window of a live app-launched session first is the bridge server's
  /// action, over the window manager.)
  Future<void> delete(String id) async {
    await service.deleteSession(id);
    if (store.remove(id)) {
      await store.save();
    }
  }

  // The structured-view reads/writes (spec §5, endpoints 5–9) are pure
  // pass-throughs to the service seam: no persistence or live fact is
  // involved, so they are exposed directly.
  Future<SessionDetail> getDetail(String id) => service.getDetail(id);

  Future<List<SessionMessage>> getMessages(String id) =>
      service.getMessages(id);

  Future<void> prompt(String id, String text) => service.prompt(id, text);

  Future<List<PermissionRequest>> pendingPermissions(String id) =>
      service.pendingPermissions(id);

  Future<void> replyPermission(
    String id,
    String requestID,
    PermissionReply reply,
  ) => service.replyPermission(id, requestID, reply);

  // The structured view's `/` command menu (issue #46): the service-backed
  // commands, pure pass-throughs to the service seam (no persistence or live
  // fact involved, like endpoints 5–9).

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

  Future<String> newTerminal(String id) => service.newTerminal(id);

  Future<String> worktrees(String sessionId) => service.worktrees(sessionId);

  Future<String> usage() => service.usage();

  Future<String> mcps() => service.mcps();

  Future<String> integrations() => service.integrations();

  Future<String> connectIntegration(String integrationId, String methodId) =>
      service.connectIntegration(integrationId, methodId);

  Future<String> status() => service.status();

  Future<String> pair() => service.pair();

  Future<void> reload() => service.reload();

  Future<String> plugins() => service.plugins();

  /// One home-list row, from the service's session plus the persistence and
  /// live facts (spec §6 classification).
  Session _row(
    OpencodeSession s,
    Map<String, String> names,
    Set<String> active,
  ) {
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
      classification: store.has(s.id)
          ? liveSessionIds.contains(s.id)
                ? SessionClassification.appLaunchedLive
                : SessionClassification.appLaunchedClosed
          : SessionClassification.external,
    );
  }
}
