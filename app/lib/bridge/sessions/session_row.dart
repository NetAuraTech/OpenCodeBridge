import '../../model/session.dart';
import '../../model/session_detail.dart';
import 'opencode_service.dart';

/// One home-list row, the single composition of a session's per-row flags.
///
/// A home-list row's live flags answer across five independently-fetched
/// facts, each with its own deliberate, individually-tested degradation
/// posture:
///
/// - **active** — from the merged active set (the service's
///   [OpencodeService.activeSessionIds]). A host failure propagates (sinks the
///   whole list); a degraded orb contributes no active ids for this pass.
///   Postured as membership in that set.
/// - **waiting** — from a per-session pair of pending lookups
///   ([OpencodeService.pendingPermissions] / [OpencodeService.pendingQuestions]).
///   A failed lookup degrades **that session only** to `false`.
/// - **pinned** — from the bridge's order store (issue #237). A store failure
///   degrades to unpinned (`false`) — the store's map is the caller's to
///   degrade; this composer just reads membership.
/// - **archived** — carried by the row's service fact
///   ([OpencodeSession.archived]); it comes straight off the service session
///   row (issue #234).
/// - **canCancel** — the routed service's interrupt capability
///   ([OpencodeService.canCancelTurn], issue #165). A lookup failure reads as
///   capable (`true`).
///
/// W7b (issue #289): the row concept composes facts no single module fetched
/// together, so the composition used to be implicit and scattered — one
/// private `_row` in [SessionsBackend], a hand-built `Session` in the orb's
/// create, and the detail read folding `active` + `canCancel` on its own.
/// This module is the one place that composes the five per-row flags into a
/// [Session] row: each fact keeps its degradation posture, but the postures
/// are the composer's one-per-fact methods (exposed, one per fact, so each
/// caller uses the subset it needs and each posture is individually tested),
/// so a change to one flag's semantics touches one composition plus that
/// flag's posture — not four call sites. The change is "the number of
/// readers", not "the location": the postures stay where they are
/// semantically; only their composition gets a home here.
///
/// The import graph is one-way `orb/ → sessions/`, so [OrbService] can import
/// this composer without a cycle (this module imports only the shared seam
/// and the row model — never the orb side).
///
/// The composer is constructed with the seam it fetches the per-row facts
/// from: [SessionsBackend] passes the aggregate service, the orb's create
/// passes the orb's service (its row's facts come from that one service).
/// [composerFor] builds the per-caller instance.
class SessionRowComposer {
  /// The service seam the per-row facts are fetched from: the aggregate
  /// (host + orb) service for the backend's rows, the owning orb's service for
  /// the orb's create.
  final OpencodeService service;

  SessionRowComposer({required this.service});

  /// The per-caller composer instance: one per service seam, so a backend and
  /// the orb's create each hold their own.
  static SessionRowComposer composerFor(OpencodeService service) =>
      SessionRowComposer(service: service);

  /// One home-list row, from the service's session plus its project name,
  /// active set, and the per-row facts the caller supplies ([waiting] and
  /// [pinned]; [canCancel] is not a [Session] field — see [canCancelOf]).
  ///
  /// [orb], when supplied, is the row's orb attribution: the usual case is a
  /// host session, or a composite-listed orb session, whose [OpencodeSession]
  /// already carries [OpencodeSession.orb] (the composite stamps it). The
  /// orb's own create (issue #97) passes it explicitly, because it talks to
  /// the raw orb service — whose [OpencodeSession] carries no orb — and it is
  /// the caller that knows the session it just created lives on that orb.
  ///
  /// This is the single composition of the row's flags (W7b, issue #289): the
  /// backend's list/create and the orb's create all build their rows here.
  Session row(
    OpencodeSession s,
    Map<String, String> names,
    Set<String> activeSet, {
    bool waiting = false,
    bool pinned = false,
    String? orb,
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
      active: activeOf(activeSet, s.id),
      orb: orb ?? s.orb,
      waiting: waiting,
      pinned: pinned,
      archived: archivedOf(s),
    );
  }

  /// The detail read's composition of the row's **active** and **canCancel**
  /// facts (issues #124 / #165): the service's active-list membership and the
  /// routed service's interrupt capability, folded into the already-fetched
  /// [detail]. The detail read is where `canCancel` rides (the structured
  /// view's Stop button); the list and create reads do not carry it. W7b
  /// (issue #289): this is the one place that detail's active + canCancel
  /// composition happens, over the same per-fact postures as [row].
  Future<SessionDetail> detailWithActive(
    SessionDetail detail,
    String id,
  ) async {
    final activeSet = await service.activeSessionIds();
    final canCancel = await canCancelOf(id);
    return detail.copyWithActive(activeOf(activeSet, id), canCancel: canCancel);
  }

  // ------------------------------------------------------------------------
  // The per-fact degradation postures: one method per fact, so a change to
  // one fact's derivation or posture is a change to one method.

  /// The row's **active** fact (the service's active-list membership):
  /// `true` while [id] is in [activeSet]. The host-failure-propagates posture
  /// is a property of the upstream [OpencodeService.activeSessionIds] (a
  /// degraded orb contributes no ids for this pass; a host failure sinks the
  /// whole read), not of this membership test — so the composer only reads
  /// the set.
  static bool activeOf(Set<String> activeSet, String id) =>
      activeSet.contains(id);

  /// The row's **waiting** fact (issue #208): whether the service still holds
  /// a pending permission request for [id], or, when it holds none, a pending
  /// question form. The question lookup runs only when the permission lookup
  /// answered empty (a waiting session already has its answer). A failed
  /// lookup degrades this session only — its fact stays `false` and the rest
  /// of the list is intact, the same posture [CompositeOpencodeService] takes
  /// for a degraded orb's routes.
  Future<bool> waitingOf(String id) async {
    try {
      final permissions = await service.pendingPermissions(id);
      if (permissions.isNotEmpty) return true;
      return (await service.pendingQuestions(id)).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// The row's **pinned** fact (issue #237): `true` while [positions] holds a
  /// position for [id]. The store's failure → empty-map degradation is the
  /// caller's ([SessionsBackend.list]); the composer just reads the set, so a
  /// store that could not be read reads every row unpinned.
  static bool pinnedOf(Map<String, num> positions, String id) =>
      positions.containsKey(id);

  /// The row's **archived** fact (issue #234): carried straight off the
  /// service's session row.
  static bool archivedOf(OpencodeSession s) => s.archived;

  /// The routed service's interrupt capability for [id] (issue #165), read
  /// without cancelling (a probe would interrupt the live turn). A lookup
  /// failure reads as capable: a wrongly-offered Stop still lands a clean,
  /// reportable 502 and stays offered to retry. This fact rides the detail
  /// read (the structured view's Stop button), not the list or create rows.
  Future<bool> canCancelOf(String id) async {
    try {
      return await service.canCancelTurn(id);
    } catch (_) {
      // The capability is a display fact, not a failure of the read: assume
      // capable so a Stop is offered and, if truly unsupported, answers a
      // reportable 502 the user can retry from.
      return true;
    }
  }
}
