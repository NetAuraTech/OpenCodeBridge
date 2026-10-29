import 'dart:convert';
import 'dart:io';

import 'paths.dart';

/// The bridge's persistence of which sessions it launched (spec §11).
///
/// The only non-derivable fact is the app-launched classification (project,
/// created-at and title are always derivable from the service's session list),
/// so the file stores **ids only**:
///
/// ```json
/// { "version": 1, "sessions": { "ses_…": {} } }
/// ```
///
/// keyed by session id, schema v1, written atomically (temp file + rename).
/// It lives under `~/.config/opencodebridge/` (next to the tunnel config);
/// installers never touch `~/.config`, so the records survive any app update.
class SessionStore {
  SessionStore._(this._dir, this._ids);

  /// The on-disk file name.
  static const String fileName = 'sessions.json';

  /// The schema version this store reads and writes.
  static const int schemaVersion = 1;

  final Directory _dir;
  final Set<String> _ids;

  /// Loads the store from [dir], defaulting to `~/.config/opencodebridge`.
  ///
  /// A missing file (first run) or an unreadable/malformed one yields an empty
  /// store: a persistence hiccup must never take the bridge down, and the file
  /// is rewritten atomically so a torn write is not expected.
  static Future<SessionStore> load({Directory? dir}) async {
    final target = dir ?? defaultDirectory();
    final ids = <String>{};
    try {
      final file = File('${target.path}/$fileName');
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString());
        if (raw is Map<String, Object?> && raw['version'] == schemaVersion) {
          final sessions = raw['sessions'];
          if (sessions is Map<String, Object?>) {
            ids.addAll(sessions.keys);
          }
        }
      }
    } catch (_) {
      // Corrupt or unreadable: start empty rather than crash the bridge.
    }
    return SessionStore._(target, ids);
  }

  /// The default config directory, `~/.config/opencodebridge`.
  static Directory defaultDirectory() =>
      Directory('${homeDirectory()}/.config/opencodebridge');

  /// The session ids currently recorded.
  Set<String> ids() => Set<String>.unmodifiable(_ids);

  bool has(String id) => _ids.contains(id);

  /// Records [id] as app-launched. (The "add id" write — spec §11 write #1 —
  /// happens from the new-session ticket; the store itself stays dumb.)
  void add(String id) {
    _ids.add(id);
  }

  /// Removes [id]; returns whether it was present. (Spec §11 write #2: the
  /// delete action removes the record in the same action as the `DELETE`.)
  bool remove(String id) => _ids.remove(id);

  /// Persists the current set atomically (temp file + rename), creating the
  /// directory if needed.
  Future<void> save() async {
    await _dir.create(recursive: true);
    final sessions = <String, Object?>{
      for (final id in _ids) id: <String, Object?>{},
    };
    final payload = <String, Object?>{
      'version': schemaVersion,
      'sessions': sessions,
    };
    final file = File('${_dir.path}/$fileName');
    final temp = File(
      '${_dir.path}/.$fileName.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    final encoded = const JsonEncoder.withIndent('  ').convert(payload);
    await temp.writeAsString('$encoded\n', flush: true);
    await temp.rename(file.path);
  }
}
