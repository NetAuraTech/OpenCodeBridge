import '../../model/session.dart';
import 'opencode_service.dart';
import 'reconcile.dart';
import 'session_store.dart';

/// The bridge's sessions backend (spec §5 endpoints 1 & 4, §6, §11): it owns
/// the [OpencodeService] seam, the [SessionStore] persistence, and the
/// in-process "live" fact, and composes them into the home-list rows.
///
/// - [list] merges the service session list, the persistence classification,
///   and the service's active list, newest first.
/// - [delete] performs the service `DELETE` and, in the same action, removes
///   the persistence record.
/// - [reconcile] is the startup orphan reconciliation.
class SessionsBackend {
  SessionsBackend({
    required this.service,
    required this.store,
    this.liveSessionIds = const {},
  });

  final OpencodeService service;
  final SessionStore store;

  /// In-process fact (spec §6/§11): the sessions whose attach child is alive
  /// in this bridge process. "Live is an in-process fact"; it is empty until
  /// the new-session ticket wires the terminal windows, after which those
  /// sessions classify as [SessionClassification.appLaunchedLive].
  final Set<String> liveSessionIds;

  /// Startup reconciliation (spec §11 write #3): drops persistence records
  /// whose session no longer exists on the service, rewriting only on change.
  Future<void> reconcile() async {
    final sessions = await service.listSessions();
    await reconcileOrphans(store, sessions.map((s) => s.id).toSet());
  }

  /// The merged home-list rows, newest first (spec §5 endpoint 1, §6).
  Future<List<Session>> list() async {
    final sessions = await service.listSessions();
    final names = await service.projectNames();
    final active = await service.activeSessionIds();
    final persisted = store.ids();

    final rows = <Session>[
      for (final s in sessions)
        Session(
          id: s.id,
          title: s.title,
          project: SessionProject(
            id: s.projectId,
            name: names[s.projectId] ?? s.projectId,
          ),
          created: s.created,
          location: s.location,
          active: active.contains(s.id),
          classification: persisted.contains(s.id)
              ? liveSessionIds.contains(s.id)
                    ? SessionClassification.appLaunchedLive
                    : SessionClassification.appLaunchedClosed
              : SessionClassification.external,
        ),
    ];
    rows.sort((a, b) => b.created.compareTo(a.created));
    return rows;
  }

  /// Delete (spec §5 endpoint 4, §11 write #2): the service deletion and the
  /// persistence-record removal happen in the same action. (Closing the window
  /// of a live app-launched session arrives with the new-session ticket.)
  Future<void> delete(String id) async {
    await service.deleteSession(id);
    if (store.remove(id)) {
      await store.save();
    }
  }
}
