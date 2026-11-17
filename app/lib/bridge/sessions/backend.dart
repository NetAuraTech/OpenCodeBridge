import 'dart:io';

import '../../model/command.dart';
import '../../model/session.dart';
import '../../model/session_detail.dart';
import 'opencode_service.dart';
import 'order_store.dart';
import 'session_row.dart';

/// The bridge's sessions backend (spec §5 endpoints 1 & 4, §6): it owns the
/// [OpencodeService] seam and composes it into the home-list rows.
///
/// Its interface is its deep core only — every method composes. The raw
/// operations of the seam (the detail read, the messages, the prompt, the
/// command menu, …) are not re-exposed here: the HTTP routes and the orb task
/// service read them directly through the backend's [service].
///
/// - [list] merges the service session list and the service's active list,
///   pinned-first (issue #237: the pinned block position ascending, then the
///   unpinned newest-created).
/// - [create] / [createInDirectory] create the session on the service
///   (spec §5 fill-in †), applying the current/default model.
/// - [detailWithActive] folds the detail read with the service's live
///   Active fact.
/// - [setOrder] / [clearOrder] move the session's position in the bridge's
///   app-owned order store (issue #237, the home list's user-controlled
///   display order).
class SessionsBackend {
  SessionsBackend({required this.service, this.orderStore})
    : composer = SessionRowComposer.composerFor(service);

  final OpencodeService service;

  /// The single home-list row composition (W7b, issue #289): builds each row's
  /// five per-row flags (active, waiting, pinned, archived, canCancel) and
  /// holds each fact's degradation posture as a one-per-fact method.
  /// Constructed once over the backend's [service], so the list/create reads
  /// and the detail read all compose through the same instance.
  final SessionRowComposer composer;

  /// The bridge's order store (issue #237): the persisted `sessionID ->
  /// position` map behind the home list's pinned-first sort. `null` when the
  /// bridge has no order store wired (the list falls back to the plain
  /// newest-created order). Mutable: the bridge's start wires it into a
  /// caller-provided backend after construction.
  SessionOrderStore? orderStore;

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
    return composer.row(session, names, active);
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
    return composer.row(session, names, active);
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

  /// Whether the service still has [id] (the reopen guard): a composition of
  /// the service's session list (the read that already degrades per-session,
  /// not an identity probe the seam does not have).
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
  /// fact, derived from the order store (issue #237). The read keeps every
  /// stored position for every session it sees and the ones it does not see
  /// (issue #292: a session invisible on a read keeps its pin); the entry is
  /// cleaned when the bridge observes the session being deleted or closed,
  /// not on the read.
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
      for (final session in sessions) composer.waitingOf(session.id),
    ]);

    // The bridge-owned order map (issue #237), kept in full (issue #292: the
    // read no longer prunes the positions of sessions it does not see); a
    // store failure degrades the list to the unpinned order.
    final orderStore = this.orderStore;
    Map<String, num> positions = const {};
    if (orderStore != null) {
      try {
        positions = orderStore.load();
      } catch (_) {
        positions = const {};
      }
    }

    final rows = [
      for (var i = 0; i < sessions.length; i++)
        composer.row(
          sessions[i],
          names,
          active,
          waiting: waiting[i],
          pinned: SessionRowComposer.pinnedOf(positions, sessions[i].id),
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

  /// The detail endpoint's read (issue #124): the session's detail plus its
  /// live Active fact (the service's active list), which the structured
  /// view's live turn footer needs when the persisted history alone is
  /// ambiguous. The orb task watcher reads this one (issue #169): settling
  /// an outcome-less session needs the Active fact — a session idle and
  /// outcome-less has ended its turn, an active one is merely between steps.
  ///
  /// The active and canCancel facts are composed through the row composer
  /// (W7b, issue #289): [SessionRowComposer.detailWithActive] is the one place
  /// that detail's active + canCancel composition happens, over the same
  /// per-fact postures as the home-list rows.
  Future<SessionDetail> detailWithActive(String id) async {
    final detail = await service.getDetail(id);
    return composer.detailWithActive(detail, id);
  }
}
