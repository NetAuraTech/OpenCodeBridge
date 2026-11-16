import 'dart:convert';
import 'dart:io';

import 'paths.dart';

/// The bridge's persisted `sessionID -> position` map (issue #237): the
/// user-controlled display order of the home list, kept in the app-owned file
/// `~/.config/opencodebridge/session-order.json` (ADR-0002, the same
/// app-owned-file pattern as the tunnel's config and the orb task service).
///
/// The map is a flat JSON object (`Map<String, num>`) on disk. It is keyed on
/// the session id — the one identity the composite host+orb list and the
/// move primitive both preserve — so a session moved host↔orb keeps its
/// place. Orphan entries (sessions that no longer exist) are cleaned when the
/// bridge observes the session being deleted or closed (issue #292, the
/// event-driven cleanup through [clear]) — a list read keeps every stored
/// position, even the ones of sessions it does not see.
class SessionOrderStore {
  SessionOrderStore({File? file}) : file = file ?? SessionOrderStore.host();

  /// The app-owned order file.
  final File file;

  /// The host path: `~/.config/opencodebridge/session-order.json`.
  static File host() =>
      File('${homeDirectory()}/.config/opencodebridge/session-order.json');

  /// The current map, re-read fresh from the file on every call (a restarted
  /// bridge, or a second instance, sees the latest). A missing file reads
  /// empty; a corrupt or non-object file degrades to empty, never a throw.
  Map<String, num> load() {
    if (!file.existsSync()) return {};
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is num) entry.key as String: entry.value as num,
      };
    } catch (_) {
      return {};
    }
  }

  /// Record [id]'s [position]. The other sessions' positions are kept.
  Future<void> set(String id, num position) async {
    final map = load();
    map[id] = position;
    await _write(map);
  }

  /// Remove [id]'s entry (the un-pin, and the observed-deletion cleanup,
  /// issue #292). A no-op when the session has no entry.
  Future<void> clear(String id) async {
    final map = load();
    if (map.remove(id) == null) return;
    await _write(map);
  }

  /// Persist [map] to the app-owned file (creating the parent directory when
  /// it is missing). An empty map removes the file: there is nothing to keep
  /// (no pinned session) and the app-owned dir is left without cruft.
  Future<void> _write(Map<String, num> map) async {
    if (map.isEmpty) {
      if (file.existsSync()) {
        await file.delete();
      }
      return;
    }
    final parent = file.parent;
    if (!parent.existsSync()) {
      await parent.create(recursive: true);
    }
    await file.writeAsString(jsonEncode(map));
  }
}
