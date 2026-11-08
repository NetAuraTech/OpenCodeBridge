import 'dart:io';

import '../../model/command.dart';
import '../../model/message.dart';
import '../../model/permission.dart';
import '../../model/question.dart';
import '../../model/session.dart';
import '../../model/session_detail.dart';
import 'opencode_service.dart';

/// The bridge's sessions backend (spec §5 endpoints 1 & 4, §6): it owns the
/// [OpencodeService] seam and composes it into the home-list rows.
///
/// - [list] merges the service session list and the service's active list,
///   newest first.
/// - [create] creates the session on the service (spec §5 fill-in †).
/// - [delete] performs the service `DELETE`.
class SessionsBackend {
  SessionsBackend({required this.service});

  final OpencodeService service;

  /// The service's project list (spec §5 fill-in †): what the app's project
  /// picker offers and what [create] takes as its only parameter.
  Future<List<OpencodeProject>> projects() => service.projects();

  /// Create a session (spec §5 fill-in †): the service `POST /api/session`
  /// in [projectId]'s project. The bridge applies the current/default model
  /// (including its thinking level / variant) so the new session shows its
  /// model like one created directly in opencode.
  Future<Session> create(String projectId) async {
    final defaults = await _defaultModelAndAgent();
    final session = await service.createSession(
      projectId,
      model: defaults.model,
      agent: defaults.agent,
    );
    await _applyDefaultModel(session.id, defaults.model);
    final names = await service.projectNames();
    final active = await service.activeSessionIds();
    return _row(session, names, active);
  }

  /// Create a session at [directory] (issue #54's "New project"):
  /// [directory] is the working directory as-is, and the service auto-creates
  /// a project for a directory it has never seen. A [directory] missing on
  /// this host is a clear 404, not a service round-trip. The bridge applies
  /// the current/default model (including its thinking level / variant).
  Future<Session> createInDirectory(String directory) async {
    if (!Directory(directory).existsSync()) {
      throw const OpencodeServiceError(
        HttpStatus.notFound,
        'no such directory',
      );
    }
    final defaults = await _defaultModelAndAgent();
    final session = await service.createSessionInDirectory(
      directory,
      model: defaults.model,
      agent: defaults.agent,
    );
    await _applyDefaultModel(session.id, defaults.model);
    final names = await service.projectNames();
    final active = await service.activeSessionIds();
    return _row(session, names, active);
  }

  /// The model (with its thinking level / variant) and agent to apply to a
  /// new session: copied from the most recently created session that already
  /// has a model, which mirrors opencode's "current model" behavior. Best-
  /// effort — a lookup failure yields no defaults rather than failing the
  /// create.
  Future<({ModelRef? model, String? agent})> _defaultModelAndAgent() async {
    try {
      final sessions = await service.listSessions();
      sessions.sort((a, b) => b.created.compareTo(a.created));
      for (final candidate in sessions.take(8)) {
        try {
          final detail = await service.getDetail(candidate.id);
          if (detail.model != null) {
            return (model: detail.model, agent: detail.agent);
          }
        } catch (_) {
          // Try the next candidate.
        }
      }
    } catch (_) {
      // No defaults available; the session is still created.
    }
    return (model: null, agent: null);
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

  /// The home-list rows, newest first (spec §5 endpoint 1, §6).
  Future<List<Session>> list() async {
    final sessions = await service.listSessions();
    final names = await service.projectNames();
    final active = await service.activeSessionIds();

    final rows = <Session>[for (final s in sessions) _row(s, names, active)];
    rows.sort((a, b) => b.created.compareTo(a.created));
    return rows;
  }

  /// Delete (spec §5 endpoint 4): the service `DELETE`.
  Future<void> delete(String id) => service.deleteSession(id);

  // The structured-view reads/writes (spec §5, endpoints 5–9) are pure
  // pass-throughs to the service seam, so they are exposed directly.
  Future<SessionDetail> getDetail(String id) => service.getDetail(id);

  /// The detail endpoint's read (issue #124): the session's detail plus its
  /// live Active fact (the service's active list), which the structured
  /// view's live turn footer needs when the persisted history alone is
  /// ambiguous. Kept off [getDetail] proper: the orb task watcher polls that
  /// one, and it needs no active-list round-trip.
  Future<SessionDetail> detailWithActive(String id) async {
    final detail = await service.getDetail(id);
    final active = await service.activeSessionIds();
    return detail.copyWithActive(active.contains(id));
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

  /// One home-list row, from the service's session plus its project name and
  /// active fact (spec §6).
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
      orb: s.orb,
    );
  }
}
