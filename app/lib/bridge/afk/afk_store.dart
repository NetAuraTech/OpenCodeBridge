import 'dart:convert';
import 'dart:io';

import '../sessions/paths.dart';

/// A stored run row (spec #376): one issue the Ready-gate poller admitted
/// to the AFK run store, and the machine state the run service (T3) drives
/// it through the per-issue state machine (`idle → dispatched → pr-open →
/// done`, plus the terminal `failed`).
///
/// The row is the run's one durable record: the admission (issue number,
/// title, state), the retry (the count, the backoff deadline), the PR (the
/// number and URL the bridge recorded on the `pr-open` transition, and
/// whether it closed unmerged), and the last terminal narration it
/// processed (the comment's id — a narration is acted on exactly once).
class AfkRun {
  const AfkRun({
    required this.issueNumber,
    required this.title,
    this.state = 'idle',
    this.retryCount = 0,
    this.prNumber,
    this.prUrl,
    this.closedUnmerged = false,
    this.retryAt,
    this.narrationId,
    this.lastFailureReason,
    this.handbackLanded = false,
  });

  /// The admitted issue's number.
  final int issueNumber;

  /// The admitted issue's title.
  final String title;

  /// The row's state (`idle` from the poller's admission; the run service
  /// moves it through the state machine).
  final String state;

  /// The retries the run service has already sent (the re-feeds after a
  /// `FAILED` narration). Reset to zero by the deliberate retry (the human
  /// re-adding `ready-for-agent` to a `failed` issue).
  final int retryCount;

  /// The PR's number, recorded when the bridge confirmed the PR open on the
  /// `pr-open` transition (spec #376: "the bridge confirms the PR is open
  /// and records its number").
  final int? prNumber;

  /// The PR's URL, recorded with [prNumber].
  final String? prUrl;

  /// Whether the run reached `done` with its PR closed unmerged (the PR's
  /// fate is a human decision, not a system error — recorded, spec #376).
  final bool closedUnmerged;

  /// The epoch millis at which the run's retry re-feed is due (the backoff
  /// deadline the run service schedules after a `FAILED` narration: 5 min
  /// after the 1st retry, 10 min after the 2nd). `null` when no retry is
  /// pending.
  final int? retryAt;

  /// The id of the last terminal narration (`PR opened` / `FAILED`) the
  /// run service processed for this row — a narration is acted on exactly
  /// once (a retry re-reads the issue while the old narration is still the
  /// last comment; the id is what keeps it from being re-processed).
  final String? narrationId;

  /// The last failure's reason, as the run service recorded it when the
  /// run's failure was routed to the retry/terminal path (spec #376, T6):
  /// a `FAILED` narration's reason, or the lost-run reason (the run was
  /// detected lost at a startup reconciliation — no liveness, no terminal
  /// narration, no PR). `null` when the run has not failed yet (a fresh
  /// dispatch, or a run at its PR). The fresh-agent handoff's bootstrap
  /// feed lists it so a recreated agent sees why a run is retrying.
  final String? lastFailureReason;

  /// Whether the terminal failure's hand-back (the `needs-triage` label
  /// **and** the comment) has fully landed (spec #376, review fixup): the
  /// run service posts the label and the comment, and records the
  /// hand-back's durability here, so a partial failure (the label landed, the comment
  /// write failed) is retried on the next pass — the label alone never
  /// short-circuits the missing comment. A row written before this field
  /// existed reads back `false` (a tolerant decode: the hand-back is
  /// re-checked and re-attempted).
  final bool handbackLanded;

  @override
  bool operator ==(Object other) =>
      other is AfkRun &&
      other.issueNumber == issueNumber &&
      other.title == title &&
      other.state == state &&
      other.retryCount == retryCount &&
      other.prNumber == prNumber &&
      other.prUrl == prUrl &&
      other.closedUnmerged == closedUnmerged &&
      other.retryAt == retryAt &&
      other.narrationId == narrationId &&
      other.lastFailureReason == lastFailureReason &&
      other.handbackLanded == handbackLanded;

  @override
  int get hashCode => Object.hashAll([
    issueNumber,
    title,
    state,
    retryCount,
    prNumber,
    prUrl,
    closedUnmerged,
    retryAt,
    narrationId,
    lastFailureReason,
    handbackLanded,
  ]);

  /// The row with the given run-state fields replaced (the run service
  /// writes the row back after every state-machine step it takes). A field
  /// left unset keeps its value; a nullable field is cleared by passing
  /// `null` explicitly (the unset/cleared distinction rides on the
  /// [absent] sentinel).
  AfkRun copyWith({
    Object? state = absent,
    Object? retryCount = absent,
    Object? prNumber = absent,
    Object? prUrl = absent,
    Object? closedUnmerged = absent,
    Object? retryAt = absent,
    Object? narrationId = absent,
    Object? lastFailureReason = absent,
    Object? handbackLanded = absent,
  }) => AfkRun(
    issueNumber: issueNumber,
    title: title,
    state: state == absent ? this.state : state as String,
    retryCount: retryCount == absent ? this.retryCount : retryCount as int,
    prNumber: prNumber == absent ? this.prNumber : prNumber as int?,
    prUrl: prUrl == absent ? this.prUrl : prUrl as String?,
    closedUnmerged: closedUnmerged == absent
        ? this.closedUnmerged
        : closedUnmerged as bool,
    retryAt: retryAt == absent ? this.retryAt : retryAt as int?,
    narrationId: narrationId == absent
        ? this.narrationId
        : narrationId as String?,
    lastFailureReason: lastFailureReason == absent
        ? this.lastFailureReason
        : lastFailureReason as String?,
    handbackLanded: handbackLanded == absent
        ? this.handbackLanded
        : handbackLanded as bool,
  );

  /// The [copyWith] "field left unset" sentinel (distinct from a `null`
  /// value, which clears).
  static const Object absent = Object();

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
/// poller's admissions, and since T3 the machine state the run service
/// drives them through — state, issue number, title, retry count, PR
/// number/URL, the backoff deadline, the processed narration). The store is
/// the one home for that machine state — the charter holds standing rules,
/// the wiki tribal knowledge, the tracker narrations the per-run journal,
/// and this store the machine state.
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
  /// issue's [title]. The row's run-state fields (retry count, PR
  /// number/URL, …) stay at their defaults — the run service moves the row
  /// with [updateRun]. Other stored values are kept.
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

  /// Replace the whole run row [run] (spec #376, T3): the run service
  /// writes the row back after every state-machine step it takes (the
  /// state, the retry count and backoff deadline, the recorded PR
  /// number/URL, the processed narration's id). Other stored values (the
  /// session record, the other rows) are kept.
  Future<void> updateRun(AfkRun run) async {
    final map = load();
    map[keyRun(run.issueNumber)] = jsonEncode({
      'state': run.state,
      'issueNumber': run.issueNumber,
      'title': run.title,
      'retryCount': run.retryCount,
      'prNumber': run.prNumber,
      'prUrl': run.prUrl,
      'closedUnmerged': run.closedUnmerged,
      'retryAt': run.retryAt,
      'narrationId': run.narrationId,
      'lastFailureReason': run.lastFailureReason,
      'handbackLanded': run.handbackLanded,
    });
    await _write(map);
  }

  /// The run row decoded from a stored value ([runFor], [runs]), or `null`
  /// when the value is missing or does not decode to the row's fields (a
  /// corrupt row is unreadable, never a throw).
  ///
  /// The run-state fields (since T3) degrade to their defaults when
  /// missing (a T2-era row reads back as a fresh `idle` admission) or of
  /// the wrong type (a corrupt field is unreadable, never a throw).
  static AfkRun? _runFrom(String? raw) {
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final number = decoded['issueNumber'];
      final title = decoded['title'];
      if (number is! int || title is! String) return null;
      final state = decoded['state'];
      final retryCount = decoded['retryCount'];
      final prNumber = decoded['prNumber'];
      final prUrl = decoded['prUrl'];
      final closedUnmerged = decoded['closedUnmerged'];
      final retryAt = decoded['retryAt'];
      final narrationId = decoded['narrationId'];
      final lastFailureReason = decoded['lastFailureReason'];
      final handbackLanded = decoded['handbackLanded'];
      return AfkRun(
        issueNumber: number,
        title: title,
        state: state is String ? state : 'idle',
        retryCount: retryCount is int ? retryCount : 0,
        prNumber: prNumber is int ? prNumber : null,
        prUrl: prUrl is String ? prUrl : null,
        closedUnmerged: closedUnmerged is bool ? closedUnmerged : false,
        retryAt: retryAt is int ? retryAt : null,
        narrationId: narrationId is String ? narrationId : null,
        lastFailureReason: lastFailureReason is String
            ? lastFailureReason
            : null,
        handbackLanded: handbackLanded is bool ? handbackLanded : false,
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
