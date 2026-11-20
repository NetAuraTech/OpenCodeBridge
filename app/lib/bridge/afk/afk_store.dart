import 'dart:convert';
import 'dart:io';

import '../sessions/paths.dart';

/// The bridge's persisted AFK machine state (spec #376): the one app-owned
/// file the AFK system reads and writes, in the bridge's state area
/// `~/.config/opencodebridge/afk.json` (ADR-0002, the same app-owned-file
/// pattern as `tasks.json` and `session-order.json`).
///
/// Today it holds the AFK session id (the id the bridge created for the
/// armed agent, so a disarm/re-arm or a restart reuses it instead of
/// creating a duplicate). Later tickets grow it with the per-issue run state
/// (state, issue number, title, retry count, PR number/URL) under the same
/// key; the store is the one home for that machine state — the charter holds
/// standing rules, the wiki tribal knowledge, the tracker narrations the
/// per-run journal, and this store the machine state.
///
/// The on-disk form is a flat JSON object of string values. A missing file
/// reads empty; a corrupt or non-object file degrades to empty, never a throw.
class AfkStore {
  AfkStore({File? file}) : file = file ?? AfkStore.host();

  /// The app-owned AFK state file.
  final File file;

  /// The host path: `~/.config/opencodebridge/afk.json`.
  static File host() =>
      File('${homeDirectory()}/.config/opencodebridge/afk.json');

  /// The key under which the AFK session id is stored.
  static const String keySessionId = 'afk.sessionId';

  /// The whole map, re-read fresh from the file on every call (a restarted
  /// bridge, or a second instance, sees the latest).
  Map<String, String> load() {
    if (!file.existsSync()) return {};
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is String) entry.key as String: entry.value as String,
      };
    } catch (_) {
      return {};
    }
  }

  /// The stored AFK session id, or `null` when none is stored.
  String? sessionId() => load()[keySessionId];

  /// Store [sessionId] (the AFK session the bridge created). Other stored
  /// values are kept.
  Future<void> setSessionId(String? sessionId) async {
    final map = load();
    if (sessionId == null) {
      map.remove(keySessionId);
    } else {
      map[keySessionId] = sessionId;
    }
    await _write(map);
  }

  /// Persist [map] to the app-owned file (creating the parent directory when
  /// it is missing). An empty map removes the file: there is nothing to keep
  /// (no AFK fact yet) and the app-owned dir is left without cruft.
  Future<void> _write(Map<String, String> map) async {
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
