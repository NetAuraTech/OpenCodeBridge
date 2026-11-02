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
  /// in [projectId]'s project.
  Future<Session> create(String projectId) async {
    final session = await service.createSession(projectId);
    final names = await service.projectNames();
    final active = await service.activeSessionIds();
    return _row(session, names, active);
  }

  /// Create a session at [directory] (issue #54's "New project"):
  /// [directory] is the working directory as-is, and the service auto-creates
  /// a project for a directory it has never seen. A [directory] missing on
  /// this host is a clear 404, not a service round-trip.
  Future<Session> createInDirectory(String directory) async {
    if (!Directory(directory).existsSync()) {
      throw const OpencodeServiceError(
        HttpStatus.notFound,
        'no such directory',
      );
    }
    final session = await service.createSessionInDirectory(directory);
    final names = await service.projectNames();
    final active = await service.activeSessionIds();
    return _row(session, names, active);
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

  Future<List<SessionMessage>> getMessages(String id) =>
      service.getMessages(id);

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
    );
  }
}
