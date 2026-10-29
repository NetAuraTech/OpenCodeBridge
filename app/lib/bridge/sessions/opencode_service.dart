/// The bridge's seam over the shared opencode service (ADR-0001: the app
/// never talks to the service directly; the bridge owns it and its
/// credentials). The sessions slice needs exactly four things of it, and this
/// is the pre-agreed seam the bridge depends on:
///
/// - every session, with its project id (the service's session list);
/// - the project list (display names + canonical directories) and the project
///   display names derived from it;
/// - the TUI-attached / agent-working set (the service's active list);
/// - creating a new session in a project;
/// - deletion of a session.
library;

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
}
