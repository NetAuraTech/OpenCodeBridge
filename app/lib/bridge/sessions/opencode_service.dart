library;

import '../../model/command.dart';
import '../../model/message.dart';
import '../../model/permission.dart';
import '../../model/question.dart';
import '../../model/session_detail.dart';

/// The bridge's seam over the shared opencode service (ADR-0001: the app
/// never talks to the service directly; the bridge owns it and its
/// credentials). This is the pre-agreed seam the bridge depends on:
///
/// - every session, with its project id (the service's session list);
/// - the project list (display names + canonical directories) and the project
///   display names derived from it;
/// - the TUI-attached / agent-working set (the service's active list);
/// - creating a new session in a project or at a bare directory;
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
    this.orb,
    this.archived = false,
  });

  final String id;
  final String title;

  /// The service's session `projectID`.
  final String projectId;

  /// Epoch millis, the service's session `time.created`.
  final int created;

  /// The working directory, the service's session `location.directory`.
  final String location;

  /// The orb id when this session lives on a running orb (stamped by the
  /// aggregate), else `null` (host sessions).
  final String? orb;

  /// True when the service reports the session archived (issue #234): its
  /// `time.archived` is set (a number) — absent or `null` when not. The seam
  /// stays faithful ([OpencodeService.listSessions] still returns archived
  /// rows); the app filters its own home-list surface from this fact (issue
  /// #235).
  final bool archived;
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

/// The typed refusal of a cancel the implementation cannot carry out
/// because its service has no interrupt route (issue #160): the capability
/// is the observable probe result, and a service without the route answers
/// this instead of a bare `UnimplementedError` the bridge could not map.
///
/// It carries the service-failure status (502), so the bridge's existing
/// `_serviceError` mapping answers 502 `opencode_unreachable` unchanged —
/// never 500, and deliberately not a new 501: the condition is transient (a
/// service restart may upgrade the route in), which is why the transport
/// re-probes after it rather than caching it.
class CancelUnsupportedError extends OpencodeServiceError {
  const CancelUnsupportedError(String message) : super(502, message);

  @override
  String toString() => 'CancelUnsupportedError($message)';
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
  /// session has no TUI attached yet. [model] and [agent], when provided, are
  /// applied to the new session (opencode's create accepts them); the bridge
  /// passes the current/default model so the session shows its model and
  /// thinking level (variant) like a session created directly in opencode.
  /// [permissions], when provided, are the session's **per-session
  /// permission rules** (`Permission.Rule`-shaped maps: `{action, resource,
  /// effect}`) applied at creation — the service's create body carries them,
  /// and [sessionPermissions] reads them back.
  Future<OpencodeSession> createSession(
    String projectId, {
    ModelRef? model,
    String? agent,
    List<Map<String, Object?>>? permissions,
  });

  /// Create a new session whose working directory is [directory] as-is
  /// (`POST /api/session` with [directory] as its `location.directory`): the
  /// service auto-creates a project for a directory it has never seen and
  /// reuses the existing project for one it has. The session has no TUI
  /// attached yet. [model] and [agent], when provided, are applied to the new
  /// session. [permissions], when provided, are the session's **per-session
  /// permission rules** applied at creation — the enforcement rides the
  /// create call (the AFK resident session's human-boundary denials, spec
  /// #420), and [sessionPermissions] reads them back.
  Future<OpencodeSession> createSessionInDirectory(
    String directory, {
    ModelRef? model,
    String? agent,
    List<Map<String, Object?>>? permissions,
  });

  /// The session's **per-session permission rules** as the service reports
  /// them (the `Session.Info.permissions` of the service's
  /// `GET /api/session/{id}` — the same `Permission.Ruleset` the create call
  /// accepts: an array of `{action, resource, effect}` rules), so the
  /// enforcement fact is observable without a live service (the AFK resident
  /// session's human-boundary denials, spec #420). An absent or `null`
  /// field answers an empty list.
  ///
  /// The default throws [UnimplementedError] (mirroring how the seam gives
  /// its light reads defaults — an implementation without the read, such as
  /// the tests' `noSuchMethod`-based fakes, keeps compiling and overrides
  /// only when a test needs the fact; the HTTP layer overrides it).
  Future<List<Map<String, Object?>>> sessionPermissions(String id) async {
    throw UnimplementedError(
      'this service has no per-session permissions read',
    );
  }

  /// Delete a session (and its child sessions) on the service.
  Future<void> deleteSession(String id);

  /// Archive or unarchive the session (issue #234): the service's
  /// `PATCH /api/session/{id}` with the single-verb `{"archived": bool}` body
  /// (one call each way; `204`). The service is the single source of truth
  /// for the archived fact, so the effect is reflected in the home list on
  /// the next refresh (and live through the `session.archived` /
  /// `session.unarchived` events the event hub already re-emits).
  Future<void> archive(String id, bool archived);

  /// The session's detail: state plus costs and token usage (spec §5,
  /// endpoint 5).
  Future<SessionDetail> getDetail(String id);

  /// Whether the service still has [id] — the light identity read (issue
  /// #272): the same identity the detail read answers, without composing
  /// the detail (the costs, the token usage, the model's context limit).
  /// One request (O(1), a single `GET /api/session/{id}`) — the pin write's
  /// existence check no longer walks the paginated session list. An id
  /// absent from the service answers [OpencodeServiceError](404), like
  /// [getDetail]; every other status propagates.
  ///
  /// The default answers from [getDetail] and exposes only the identity the
  /// detail carries (an implementation without a lighter read may inherit
  /// it; one with a lighter read overrides — the [OpencodeHttpService]
  /// reads the session's data without composing the detail).
  Future<OpencodeSession> probe(String id) async {
    final detail = await getDetail(id);
    return OpencodeSession(
      id: detail.id,
      title: detail.title,
      projectId: '',
      created: 0,
      location: detail.location,
    );
  }

  /// The session's history as structured-view messages, with the tools in
  /// flight (spec §5, endpoint 6). User and assistant turns only.
  Future<List<SessionMessage>> getMessages(String id);

  /// One page of the session's history, oldest-first within the page, with
  /// the cursor to the next (older) page (issue #124). The service paginates
  /// the history newest-first, so the first fetch (no [cursor]) is the newest
  /// page of at most [limit] messages.
  Future<MessagePage> getMessagesPage(
    String id, {
    int limit = 50,
    String? cursor,
  });

  /// Send a prompt to the session (spec §5, endpoint 7). Input is enabled at
  /// any time; a mid-turn prompt is accepted with `delivery: steer` and the
  /// service runs turns sequentially. [files] and [skills] are the optional
  /// attachment arrays the service's `PromptInput` accepts (the TUI's `@`
  /// file/skill mentions): the service resolves them (reads the file
  /// content, prepares the skill text), so they ride the same request
  /// as-is; omitted or empty sends the text only.
  Future<void> prompt(
    String id,
    String text, {
    List<Map<String, Object?>>? files,
    List<Map<String, Object?>>? skills,
  });

  /// The session's idle-wait (the service's
  /// `POST /api/experimental/session/{id}/wait` — "wait for a session agent
  /// loop to become idle"): a **long-poll**, `204` at idle / `503` running —
  /// the service holds the request while a turn runs, so the client bounds
  /// the hold with its own [timeout] (the research note on the opencode v2
  /// service API, ticket #360: at idle it returns 204 promptly; while a turn
  /// runs it holds).
  ///
  /// Completes with `true` when the session's agent loop is idle (the turn
  /// is over) and `false` when the wait timed out while the session was
  /// still running — the caller treats a timeout exactly like a 503 and
  /// asks again later.
  ///
  /// The default answers from a **single active-set probe** (an
  /// implementation without the wait route degrades to the non-blocking
  /// check — it answers idle only when the session is not active *now*; the
  /// caller re-asks on its next pass): fakes and the tests inherit it.
  Future<bool> waitIdle(
    String id, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final active = await activeSessionIds();
    return !active.contains(id);
  }

  /// The session's pending permission requests (spec §5, endpoint 8).
  Future<List<PermissionRequest>> pendingPermissions(String id);

  /// Reply to a pending permission request (spec §5, endpoint 9).
  Future<void> replyPermission(
    String id,
    String requestID,
    PermissionReply reply,
  );

  // The structured-view question forms (issue #50): the opencode agent's
  // `question` tool surfaces its questions as service forms with
  // `metadata.kind == "question"`. The bridge filters those forms and hides
  // the service's internal `q0`/`q1` field keys, so the app answers per
  // question in the form's order.

  /// The session's pending question forms (its `GET /api/session/{id}/form`
  /// filtered to `metadata.kind == "question"`), each with its questions in
  /// the form's field order.
  Future<List<QuestionForm>> pendingQuestions(String id);

  /// Submit the answers to a pending question form [formID]. [answers] has one
  /// entry per question, in the form's field order: each entry is the list of
  /// selected option labels (or the typed text for a free-text question). The
  /// bridge re-fetches the form to recover the field order/types and rebuilds
  /// the service's `q0`/`q1` `answer` record (the keys are never exposed to
  /// the app).
  Future<void> answerQuestion(
    String id,
    String formID,
    List<List<String>> answers,
  );

  /// Dismiss a pending question form [formID] (the agent continues without an
  /// answer): the service's `DELETE /api/session/{id}/form/{formID}`.
  Future<void> dismissQuestion(String id, String formID);

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

  /// Cancel the session's running turn (the service's
  /// `POST /api/session/{id}/interrupt`): the turn stops and no further
  /// output streams. An idle session accepts it harmlessly.
  ///
  /// The default refuses with the typed [CancelUnsupportedError] (issue
  /// #160): an implementation without an interrupt path inherits a refusal
  /// the bridge maps to 502 `opencode_unreachable`, never a bare
  /// `UnimplementedError` that would reach the bridge unmapped (a 500).
  Future<void> cancelTurn(String id) async {
    throw const CancelUnsupportedError('this service has no interrupt route');
  }

  /// Whether the service can cancel [id]'s turn (issue #165's capability
  /// check, ticket #2): the single check the structured view uses to decide
  /// whether to offer Stop on an Active turn.
  ///
  /// This is a **read** — it must answer without the side effect of actually
  /// cancelling the live turn (opencode has no non-destructive "does the
  /// interrupt route exist" query, so probing it would mean cancelling). The
  /// default assumes capable (`true`): a wrongly-offered Stop still lands a
  /// clean, reportable 502 and stays offered to retry, whereas assuming
  /// incapable would hide Stop from every service on a first open. A
  /// service that has actually proven itself unable (a remembered probe)
  /// overrides this to `false`.
  Future<bool> canCancelTurn(String id) async => true;

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

  /// The open session's project's worktrees (the service's
  /// `GET /api/worktree?projectID=…`), as decoded JSON. The project id is
  /// resolved from the session on the service.
  Future<String> worktrees(String sessionId);

  /// The files the session's working directory offers for the `@` mention
  /// menu (issue #58): the service's `GET /api/fs/find` over the session's
  /// working directory, re-queried per typed token (server-side fuzzy rank,
  /// the TUI behavior). Returns the matched file paths relative to the
  /// session's working directory.
  Future<List<String>> findFiles(String id, String query);

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
