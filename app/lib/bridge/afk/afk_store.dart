import 'dart:convert';
import 'dart:io';

import '../sessions/paths.dart';

/// A stored run row (spec #376, "The Ready gate and the feed", T2): one
/// issue the Ready-gate poller admitted to the AFK run store — state, issue
/// number, title. The poller's admissions are the rows, always state
/// `idle`; the run service (a later ticket) drives the row through the
/// per-issue state machine (`idle → dispatched → …`).
class AfkRun {
  const AfkRun({
    required this.issueNumber,
    required this.title,
    this.state = 'idle',
  });

  /// The admitted issue's number.
  final int issueNumber;

  /// The admitted issue's title.
  final String title;

  /// The row's state: `idle` from the poller's admission (the run service
  /// moves it later).
  final String state;

  @override
  bool operator ==(Object other) =>
      other is AfkRun &&
      other.issueNumber == issueNumber &&
      other.title == title &&
      other.state == state;

  @override
  int get hashCode => Object.hash(issueNumber, title, state);

  @override
  String toString() =>
      'AfkRun(issueNumber: $issueNumber, title: $title, state: $state)';
}

/// The bridge's persisted AFK machine state (spec #376): the one app-owned
/// file the AFK system reads and writes, in the bridge's state area
/// `~/.config/opencodebridge/afk.json` (ADR-0002, the same app-owned-file
/// pattern as `tasks.json` and `session-order.json`).
///
/// It holds the AFK session id (the id the bridge created for the armed
/// agent, so a disarm/re-arm or a restart reuses it instead of creating a
/// duplicate) and — since T2 — the per-issue run rows ([AfkRun]: the
/// poller's admissions — state, issue number, title). Later tickets grow it
/// with the remaining per-issue run state (retry count, PR number/URL); the
/// store is the one home for that machine state — the charter holds standing
/// rules, the wiki tribal knowledge, the tracker narrations the per-run
/// journal, and this store the machine state.
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

  /// The key of the run row for issue [issueNumber]: `afk.run.<issueNumber>`
  /// — the poller's admissions, stored as JSON strings in the flat map.
  static String keyRun(int issueNumber) => 'afk.run.$issueNumber';

  /// The stored run row for issue [issueNumber], or `null` when the issue is
  /// not recorded — not yet admitted, or its row is unreadable.
  AfkRun? runFor(int issueNumber) => _runFrom(load()[keyRun(issueNumber)]);

  /// Every stored run row, sorted by issue number.
  List<AfkRun> runs() {
    final rows = <AfkRun>[];
    for (final entry in load().entries) {
      if (!entry.key.startsWith('afk.run.')) continue;
      final run = _runFrom(entry.value);
      if (run != null) rows.add(run);
    }
    rows.sort((a, b) => a.issueNumber.compareTo(b.issueNumber));
    return List.unmodifiable(rows);
  }

  /// Record (or update) the run row for issue [issueNumber]: state
  /// [state] (`idle` — the poller's admission), the issue number, and the
  /// issue's [title]. Other stored values are kept.
  Future<void> addRun(
    int issueNumber,
    String title, {
    String state = 'idle',
  }) async {
    final map = load();
    map[keyRun(issueNumber)] = jsonEncode({
      'state': state,
      'issueNumber': issueNumber,
      'title': title,
    });
    await _write(map);
  }

  /// The run row decoded from a stored value ([runFor], [runs]), or `null`
  /// when the value is missing or does not decode to the row's fields (a
  /// corrupt row is unreadable, never a throw).
  static AfkRun? _runFrom(String? raw) {
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final number = decoded['issueNumber'];
      final title = decoded['title'];
      if (number is! int || title is! String) return null;
      final state = decoded['state'];
      return AfkRun(
        issueNumber: number,
        title: title,
        state: state is String ? state : 'idle',
      );
    } catch (_) {
      return null;
    }
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
