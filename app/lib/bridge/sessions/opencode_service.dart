library;

import '../../model/command.dart';
import '../../model/message.dart';
import '../../model/permission.dart';
import '../../model/session_detail.dart';

/// The bridge's seam over the shared opencode service (ADR-0001: the app
/// never talks to the service directly; the bridge owns it and its
/// credentials). This is the pre-agreed seam the bridge depends on:
///
/// - every session, with its project id (the service's session list);
/// - the project list (display names + canonical directories) and the project
///   display names derived from it;
/// - the TUI-attached / agent-working set (the service's active list);
/// - creating a new session in a project;
/// - deletion of a session;
/// - the structured-view reads (detail, messages) and writes (prompt,
///   permission reply) of spec section 5 (endpoints 5–9).

/// One session as the shared opencode service reports it: the identity and
/// non-derivable facts the bridge composes a home-list row from (spec §5, §6).
class OpencodeSession {
  const OpencodeSession({
    required this.id,
    required this.title,
    required this.projectId,
    required this.created,
    required this.location,
  });

  final String id;
  final String title;

  /// The service's session `projectID`.
  final String projectId;

  /// Epoch millis, the service's session `time.created`.
  final int created;

  /// The working directory, the service's session `location.directory`.
  final String location;
}

/// One project as the shared opencode service reports it (`GET /api/project`):
/// the id the app picks, the display name, and the canonical working directory
/// a new session's PTY is created in.
class OpencodeProject {
  const OpencodeProject({
    required this.id,
    required this.name,
    required this.canonical,
  });

  /// The service's project id (what the app sends as `project`).
  final String id;

  /// Display name; the service's `name`, else the basename of [canonical].
  final String name;

  /// The canonical directory; a new session's PTY `cwd`.
  final String canonical;
}

/// A failure talking to the shared opencode service, carrying the service's
/// HTTP status so the bridge can map it (e.g. a 404 delete -> 404).
class OpencodeServiceError implements Exception {
  const OpencodeServiceError(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'OpencodeServiceError($statusCode: $message)';
}

abstract class OpencodeService {
  /// Every session on the shared service, all pages, newest first.
  Future<List<OpencodeSession>> listSessions();

  /// Project id -> display name, from the service's project list.
  Future<Map<String, String>> projectNames();

  /// The ids the service reports as active (TUI-attached, agent working).
  Future<Set<String>> activeSessionIds();

  /// The service's project list: id, display name, and canonical directory
  /// (`GET /api/project`).
  Future<List<OpencodeProject>> projects();

  /// Create a new session in [projectId]'s project (`POST /api/session` with
  /// the project's canonical directory as its `location.directory`). The
  /// session has no TUI attached yet; the caller opens its terminal window.
  Future<OpencodeSession> createSession(String projectId);

  /// Delete a session (and its child sessions) on the service.
  Future<void> deleteSession(String id);

  /// The session's detail: state plus costs and token usage (spec §5,
  /// endpoint 5).
  Future<SessionDetail> getDetail(String id);

  /// The session's history as structured-view messages, with the tools in
  /// flight (spec §5, endpoint 6). User and assistant turns only.
  Future<List<SessionMessage>> getMessages(String id);

  /// Send a prompt to the session (spec §5, endpoint 7). Input is enabled at
  /// any time; a mid-turn prompt is accepted with `delivery: steer` and the
  /// service runs turns sequentially.
  Future<void> prompt(String id, String text);

  /// The session's pending permission requests (spec §5, endpoint 8).
  Future<List<PermissionRequest>> pendingPermissions(String id);

  /// Reply to a pending permission request (spec §5, endpoint 9).
  Future<void> replyPermission(
    String id,
    String requestID,
    PermissionReply reply,
  );

  // The structured view's `/` command menu (issue #46): the service-backed
  // commands. Each is a thin mapping over a shared-service endpoint; the
  // service is the single source of truth, so the effect is reflected live in
  // any attached TUI. The "info" commands (export, diff, stats, usage, …)
  /// return the service's decoded JSON as a string for the view to display.

  /// The project's custom commands (the service's `GET /api/command`).
  Future<List<OpencodeCommand>> listCommands();

  /// Run one of the project's custom commands (the service's
  /// `POST /api/session/{id}/command`): [name] is the command name (no
  /// leading slash) and [text] the text typed after the command name.
  /// Runs with `delivery: steer`, so it queues mid-turn like a prompt.
  Future<void> runCommand(String id, String name, String text);

  /// The model registry (the service's `GET /api/model`).
  Future<List<ModelOption>> listModels();

  /// The session's current model (its detail's `model` ref), or `null` when
  /// the service reports none yet.
  Future<ModelRef?> currentModel(String id);

  /// Set the session's model (the service's `POST /api/session/{id}/model`).
  Future<void> setModel(String id, ModelRef model);

  /// The agent registry (the service's `GET /api/agent`).
  Future<List<AgentOption>> listAgents();

  /// Set the session's agent (the service's `POST /api/session/{id}/agent`).
  Future<void> setAgent(String id, String agentId);

  /// The skill registry (the service's `GET /api/skill`).
  Future<List<SkillOption>> listSkills();

  /// Activate a skill in the session (the service's
  /// `POST /api/experimental/session/{id}/skill`).
  Future<void> activateSkill(String id, String skillId);

  /// Compact the session's context (the service's
  /// `POST /api/session/{id}/compact`).
  Future<void> compact(String id);

  /// Undo the previous message: stage a revert at the session's last user
  /// message (the service's `POST /api/session/{id}/revert/stage`). A no-op
  /// when the session has no user message yet.
  Future<void> undo(String id);

  /// Redo: discard the staged revert (the service's
  /// `DELETE /api/session/{id}/revert`).
  Future<void> redo(String id);

  /// Fork the session (the service's `POST /api/session/{id}/fork`),
  /// returning the new session's id.
  Future<String> fork(String id);

  /// Rename the session (the service's `PATCH /api/session/{id}` with a
  /// `title`).
  Future<void> rename(String id, String title);

  /// The session's transcript (the service's
  /// `GET /api/experimental/session/{id}/export`), as decoded JSON.
  Future<String> exportSession(String id);

  /// Change the session's working directory (the service's
  /// `POST /api/session/{id}/move`).
  Future<void> move(String id, String directory);

  /// Ask a one-shot side question (the service's
  /// `POST /api/session/{id}/generate`), returning the generated text. Not
  /// added to the conversation.
  Future<String> generate(String id, String prompt);

  /// The session's file diffs (the service's `GET /api/session/{id}/diff`),
  /// as decoded JSON.
  Future<String> diff(String id);

  /// The session's usage statistics (the service's
  /// `GET /api/experimental/session/stats`), as decoded JSON.
  Future<String> stats(String id);

  /// Open a terminal for the session (the service's
  /// `POST /api/experimental/session/{id}/terminal`), as decoded JSON.
  Future<String> newTerminal(String id);

  /// The open session's project's worktrees (the service's
  /// `GET /api/worktree?projectID=…`), as decoded JSON. The project id is
  /// resolved from the session on the service.
  Future<String> worktrees(String sessionId);

  // Global (not tied to the open session).

  /// The account's usage limits (the service's
  /// `GET /api/experimental/usage/limits`), as decoded JSON.
  Future<String> usage();

  /// The MCP servers (the service's `GET /api/mcp`), as decoded JSON.
  Future<String> mcps();

  /// The integrations (the service's `GET /api/integration`), as decoded JSON.
  Future<String> integrations();

  /// Connect an integration via OAuth (the service's
  /// `POST /api/integration/{id}/connect/oauth`), as decoded JSON.
  Future<String> connectIntegration(String integrationId, String methodId);

  /// The service's info (the service's `GET /api/info`), as decoded JSON.
  Future<String> status();

  /// Pair a device (the service's `POST /api/pair`), as decoded JSON.
  Future<String> pair();

  /// Reload the service's configuration (the service's
  /// `POST /api/location/reload`).
  Future<void> reload();

  /// The plugins (the service's `GET /api/plugin`), as decoded JSON.
  Future<String> plugins();
}
