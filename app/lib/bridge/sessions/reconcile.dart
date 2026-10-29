import 'session_store.dart';

/// Orphan reconciliation (spec §11, write #3): at bridge startup, compare the
/// persistence records against the service's session list and drop any record
/// whose session no longer exists on the service. The list is the same one
/// that feeds the home screen (zero extra endpoint).
///
/// The file is rewritten **only if something was dropped**; otherwise the
/// store is left untouched. Returns the dropped ids (empty when nothing
/// changed) so a caller can report or emit a `session.closed` event once the
/// events ticket lands.
Future<List<String>> reconcileOrphans(
  SessionStore store,
  Set<String> serviceIds,
) async {
  final orphans = store.ids().where((id) => !serviceIds.contains(id)).toList();
  if (orphans.isEmpty) {
    return const [];
  }
  for (final id in orphans) {
    store.remove(id);
  }
  await store.save();
  return orphans;
}
