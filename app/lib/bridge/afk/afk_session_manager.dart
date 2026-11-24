import 'dart:io';

import 'afk_rules.dart' as afk_rules;
import 'afk_settings.dart';
import '../sessions/opencode_service.dart';

/// The bridge's owner of the AFK session (spec #376, "The AFK agent"; spec
/// #420: the resident session runs the **default agent**).
///
/// **Arming** creates the AFK session: in the main checkout's directory, with
/// the model pinned from the `afkModel` setting (omitted when empty — the
/// service's default), **no agent override** (the session runs the default
/// agent, like any interactive session), and the **human-boundary denials**
/// ([afk_rules.humanBoundaryDenials]) applied to the session at creation as
/// per-session permissions (the enforcement; the rules' words ride the feed —
/// [afk_rules.standingRules] prefixes every feed). The session is visible in
/// the session list (never archived). Its session id is stored by the bridge.
/// **Disarming** never destroys the session — it only stops the system from
/// admitting work (the session outlives a disarm), and re-arming **reuses**
/// the existing session rather than creating a duplicate.
///
/// The module rides the composite session service seam ([OpencodeService]):
/// create and probe are the only operations it needs, and that seam is the
/// one already faked in the bridge's session tests. The "main checkout"
/// directory is a provider resolved at creation time (the bridge's backend
/// may not have resolved at bridge startup — arming happens later, when the
/// user toggles, by which point the directory is known).
class AfkSessionManager {
  AfkSessionManager({
    required this.sessions,
    required this.directory,
    String? initialSessionId,
  }) : _id = initialSessionId;

  /// The session service seam (the composite over the host service and the
  /// running orbs). Creation is host-only on the composite, so the AFK
  /// session always lands on the host.
  final OpencodeService sessions;

  /// Resolves the main checkout's directory — the AFK session's working
  /// directory — at creation time.
  final Future<String> Function() directory;

  /// The stored AFK session id (the id the bridge created for the armed
  /// agent), or `null` when none is armed yet. Seeded with [initialSessionId]
  /// (the id persisted in the bridge's store) so a re-arm reuses it; updated
  /// to the new id when [ensureSession] creates a session.
  String? _id;

  /// The current AFK session id, or `null` when none is armed yet.
  String? get sessionId => _id;

  /// Ensure the AFK session exists and return its id.
  ///
  /// Reuses the stored id when the service still has it (a disarm that the
  /// session outlived, or a re-arm); otherwise creates it in the resolved
  /// main checkout with the model pinned from [model] (`null`/empty =
  /// inherit) and **no agent override** (the session runs the default agent —
  /// spec #420; its standing rules ride the feed, [afk_rules.standingRules]),
  /// and the **human-boundary denials** applied to the session at creation as
  /// per-session permissions ([afk_rules.humanBoundaryDenials] — the
  /// enforcement; the rules' words ride the feed). Returns the new id.
  ///
  /// The model is read at creation time, so a changed `afkModel` setting is
  /// effective from the next session creation without a restart.
  Future<String> ensureSession({String? model}) async {
    final existing = _id;
    if (existing != null && await _exists(existing)) {
      return existing;
    }
    final directory = await this.directory();
    final session = await sessions.createSessionInDirectory(
      directory,
      model: parseAfkModel(model ?? ''),
      permissions: afk_rules.humanBoundaryDenials,
    );
    _id = session.id;
    return session.id;
  }

  /// Whether the service still has [id] (the light identity read): `false`
  /// on a 404, propagated otherwise.
  Future<bool> _exists(String id) async {
    try {
      await sessions.probe(id);
      return true;
    } on OpencodeServiceError catch (e) {
      if (e.statusCode == HttpStatus.notFound) return false;
      rethrow;
    }
  }
}
