import 'dart:convert';
import 'dart:io';

import '../sessions/paths.dart';

/// A stored run row (spec #376, reshaped by #407): one issue the Ready-gate
/// poller admitted to the AFK run store, and the machine state the run
/// service drives it through the per-issue state machine (`idle → dispatched
/// → pr-open → done`, plus the terminal `failed`).
///
/// The row is the run's one durable record: the admission (issue number,
/// title, state), the retry (the count, the backoff deadline), the PR (the
/// number and URL the bridge recorded on the `pr-open` transition, and
/// whether it closed unmerged), and the last terminal narration it processed
/// (the comment's id — a narration is acted on exactly once).
///
/// [ownerRepo] (spec #407) names the repo identity (`owner/repo`) the run
/// belongs to — the row is now keyed per repo (`afk.run.<owner/repo>.<issue>`
///), so the same issue number in two repos is two distinct rows. It is
/// recorded on the row (and the key) so the row carries its own home.
class AfkRun {
  const AfkRun({
    required this.ownerRepo,
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

  /// The repo identity (`owner/repo`) the run belongs to (spec #407): the row
  /// is keyed per repo, so the same issue number in two repos is two rows.
  final String ownerRepo;

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
      other.ownerRepo == ownerRepo &&
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
    ownerRepo,
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
  /// [absent] sentinel). [ownerRepo], [issueNumber], and [title] are
  /// identity — they are never replaced.
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
    ownerRepo: ownerRepo,
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
      'AfkRun($ownerRepo#$issueNumber, title: $title, state: $state)';
}

/// The bridge's persisted AFK machine state (spec #407, reshaped from #376):
/// the one app-owned file the AFK system reads and writes, in the bridge's
/// state area `~/.config/opencodebridge/afk.json` (ADR-0002, the same
/// app-owned-file pattern as `tasks.json` and `session-order.json`).
///
/// It is now keyed **per repo identity** (`owner/repo`): one AFK session id
/// per armed repo (`afk.session.<owner/repo>`) and one run row per
/// (repo, issue) (`afk.run.<owner/repo>.<issue>`). Two checkouts of the same
/// repo share one identity and thus one session + one set of rows; the same
/// issue number in two repos is two distinct rows.
///
/// **No migration** (spec #407): the pre-scoping flat keys (`afk.sessionId`
/// and `afk.run.<issue>`) are *ignored on read* — the per-repo accessors
/// never see them — and are *never written* (a write drops any that a loaded
/// map still carries, so they are not carried forward or migrated; the
/// pre-pilot rows were killed by the developer, nothing to preserve). A
/// missing file reads empty; a corrupt or non-object file degrades to empty,
/// never a throw.
class AfkStore {
  AfkStore({File? file}) : file = file ?? AfkStore.host();

  /// The app-owned AFK state file.
  final File file;

  /// The host path: `~/.config/opencodebridge/afk.json`.
  static File host() =>
      File('${homeDirectory()}/.config/opencodebridge/afk.json');

  /// The key under which a repo's AFK session id is stored:
  /// `afk.session.<owner/repo>`.
  static String keySession(String repo) => 'afk.session.$repo';

  /// The key of the run row for issue [issueNumber] in [repo]:
  /// `afk.run.<owner/repo>.<issueNumber>` — stored as a JSON string in the
  /// flat map.
  static String keyRun(String repo, int issueNumber) =>
      'afk.run.$repo.$issueNumber';

  /// The whole map, re-read fresh from the file on every call (a restarted
  /// bridge, or a second instance, sees the latest). Returns the raw
  /// string→string map, including any pre-scoping flat keys a legacy file
  /// still carries (the per-repo accessors below filter those out on read).
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

  /// The stored AFK session id for [repo], or `null` when none is stored.
  /// The legacy flat `afk.sessionId` key is not read (no migration).
  String? sessionIdFor(String repo) => load()[keySession(repo)];

  /// Every stored AFK session id (all `afk.session.<owner/repo>` values),
  /// deduplicated, empty strings dropped. This is the **disarming-stable**
  /// set (spec #407 T5): a disarm never deletes a stored session id (the
  /// session outlives a disarm — spec #376, user story #24), so a repo
  /// disarmed while its orb is in flight keeps its id in the set until the
  /// orb settles. It is the set the spawn gate's attribution and the
  /// in-flight counter are held against — the in-flight fact is the creating
  /// task's caller, not the current arming. The legacy flat `afk.sessionId`
  /// key is not read (no migration).
  Set<String> allSessionIds() {
    final ids = <String>{};
    for (final entry in load().entries) {
      if (!_isSessionKey(entry.key)) continue;
      if (entry.value.isNotEmpty) ids.add(entry.value);
    }
    return ids;
  }

  /// Store the AFK session id for [repo] (the session the bridge created
  /// under that repo's checkout). `null` clears it. Other stored values are
  /// kept.
  Future<void> setSessionId(String repo, String? id) async {
    final map = load();
    if (id == null) {
      map.remove(keySession(repo));
    } else {
      map[keySession(repo)] = id;
    }
    await _write(map);
  }

  /// The stored run row for issue [issueNumber] in [repo], or `null` when
  /// that (repo, issue) is not recorded — not yet admitted, or its row is
  /// unreadable.
  AfkRun? runFor(String repo, int issueNumber) =>
      _runFrom(load()[keyRun(repo, issueNumber)]);

  /// The stored run rows for [repo], sorted by issue number.
  List<AfkRun> runsFor(String repo) =>
      allRuns().where((run) => run.ownerRepo == repo).toList(growable: false);

  /// Every stored per-repo run row, sorted by issue number. The pre-scoping
  /// flat keys (`afk.run.<issue>`) are ignored — they carry no repo identity
  /// (no `/` in the key), and a per-repo key always does.
  List<AfkRun> allRuns() {
    final rows = <AfkRun>[];
    for (final entry in load().entries) {
      if (!_isPerRepoRunKey(entry.key)) continue;
      final run = _runFrom(entry.value);
      if (run != null) rows.add(run);
    }
    rows.sort((a, b) => a.issueNumber.compareTo(b.issueNumber));
    return List.unmodifiable(rows);
  }

  /// Record (or update) the run row for issue [issueNumber] in [repo]: state
  /// [state] (`idle` — the poller's admission), the repo, the issue number,
  /// and the issue's [title]. The row's run-state fields (retry count, PR
  /// number/URL, …) stay at their defaults — the run service moves the row
  /// with [updateRun]. Other stored values are kept.
  Future<void> addRun(
    String repo,
    int issueNumber,
    String title, {
    String state = 'idle',
  }) async {
    final map = load();
    map[keyRun(repo, issueNumber)] = jsonEncode({
      'ownerRepo': repo,
      'state': state,
      'issueNumber': issueNumber,
      'title': title,
    });
    await _write(map);
  }

  /// Replace the whole run row [run] (spec #376, T3; keyed per repo by
  /// spec #407): the run service writes the row back after every
  /// state-machine step it takes (the state, the retry count and backoff
  /// deadline, the recorded PR number/URL, the processed narration's id).
  /// The row is keyed by its own [AfkRun.ownerRepo]. Other stored values
  /// (the session records, the other rows) are kept.
  Future<void> updateRun(AfkRun run) async {
    final map = load();
    map[keyRun(run.ownerRepo, run.issueNumber)] = jsonEncode({
      'ownerRepo': run.ownerRepo,
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

  /// The run row decoded from a stored value ([runFor], [allRuns]), or
  /// `null` when the value is missing or does not decode to the row's fields
  /// (a corrupt row is unreadable, never a throw).
  ///
  /// The run-state fields degrade to their defaults when missing (an older
  /// row reads back with the defaults) or of the wrong type (a corrupt field
  /// is unreadable, never a throw). [AfkRun.ownerRepo] degrades to `''` when
  /// missing (a hand-written row without it — a per-repo row always carries
  /// it).
  static AfkRun? _runFrom(String? raw) {
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final number = decoded['issueNumber'];
      final title = decoded['title'];
      if (number is! int || title is! String) return null;
      final ownerRepo = decoded['ownerRepo'];
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
        ownerRepo: ownerRepo is String ? ownerRepo : '',
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

  /// Whether [key] is a per-repo run-row key: `afk.run.<owner/repo>.<issue>`,
  /// where the repo identity always contains exactly one `/`. A pre-scoping
  /// flat run key (`afk.run.<issue>`) has no repo identity and thus no `/`
  /// after the `afk.run.` prefix, so it is never mistaken for a per-repo key.
  /// (The legacy rows are ignored on read, not migrated — spec #407.)
  static bool _isPerRepoRunKey(String key) {
    const runPrefix = 'afk.run.';
    if (!key.startsWith(runPrefix)) return false;
    return key.substring(runPrefix.length).contains('/');
  }

  /// Whether [key] is a per-repo session-id key: `afk.session.<owner/repo>`,
  /// where the repo identity always contains exactly one `/`. The legacy flat
  /// `afk.sessionId` key has no repo identity, so it is never mistaken for a
  /// per-repo key (it is not read, no migration — spec #407).
  static bool _isSessionKey(String key) {
    const sessionPrefix = 'afk.session.';
    if (!key.startsWith(sessionPrefix)) return false;
    return key.substring(sessionPrefix.length).contains('/');
  }

  /// Whether [key] is a pre-scoping flat key (spec #407, "no migration"): the
  /// old session id (`afk.sessionId`) or an old run row (`afk.run.<issue>`,
  /// no repo identity). Such keys are ignored on read and dropped on the next
  /// write — never written back, never migrated.
  static bool _isLegacyKey(String key) =>
      key == 'afk.sessionId' ||
      (key.startsWith('afk.run.') && !_isPerRepoRunKey(key));

  /// Persist [map] to the app-owned file (creating the parent directory when
  /// it is missing). Pre-scoping flat keys still present in the map are
  /// dropped — they are neither migrated nor written back (spec #407). An
  /// empty map removes the file: there is nothing to keep (no AFK fact yet)
  /// and the app-owned dir is left without cruft.
  Future<void> _write(Map<String, String> map) async {
    final clean = {
      for (final entry in map.entries)
        if (!_isLegacyKey(entry.key)) entry.key: entry.value,
    };
    if (clean.isEmpty) {
      if (file.existsSync()) {
        await file.delete();
      }
      return;
    }
    final parent = file.parent;
    if (!parent.existsSync()) {
      await parent.create(recursive: true);
    }
    await file.writeAsString(jsonEncode(clean));
  }
}
