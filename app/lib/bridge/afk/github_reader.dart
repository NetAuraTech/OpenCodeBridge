import 'dart:convert';
import 'dart:io';

/// A labelled issue the GitHub reader admits to the AFK run store (spec
/// #376, "The Ready gate and the feed", T2): the poller admits one row per
/// ready issue — state `idle`, the issue number, the title.
class ReadyIssue {
  const ReadyIssue({required this.number, required this.title});

  /// The issue's number.
  final int number;

  /// The issue's title.
  final String title;

  @override
  bool operator ==(Object other) =>
      other is ReadyIssue && other.number == number && other.title == title;

  @override
  int get hashCode => Object.hash(number, title);

  @override
  String toString() => 'ReadyIssue(number: $number, title: $title)';
}

/// The issue's last comment (spec #376, T3): the agent's terminal
/// narration rides on it (`PR opened: <url>` / `FAILED: <reason>`). [id]
/// identifies the comment (the store's dedup key — a narration is acted on
/// exactly once), [body] its text.
class IssueComment {
  const IssueComment({required this.id, required this.body});

  /// The comment's id (the one the store's row records as the last
  /// processed narration).
  final String id;

  /// The comment's body.
  final String body;

  @override
  bool operator ==(Object other) =>
      other is IssueComment && other.id == id && other.body == body;

  @override
  int get hashCode => Object.hash(id, body);

  @override
  String toString() => 'IssueComment(id: $id, body: $body)';
}

/// The PR the run service confirms on the `pr-open` transition and follows
/// to the run's `done` (spec #376, T3): the number the bridge records, the
/// URL the `afk.pr_open` event carries, and the state gh reports — `OPEN`,
/// `MERGED`, or `CLOSED` (a `CLOSED` PR is a closed-unmerged one: the PR's
/// fate is a human decision, not a system error).
class PrInfo {
  const PrInfo({required this.number, required this.url, required this.state});

  /// The PR's number (recorded on the run row at `pr-open`).
  final int number;

  /// The PR's GitHub URL (the `afk.pr_open` event's deep-link, the push
  /// ticket's).
  final String url;

  /// The PR's state as gh reports it (`OPEN` / `MERGED` / `CLOSED`).
  final String state;

  /// Whether the PR is open (the `pr-open` transition's confirmation).
  bool get isOpen => state == 'OPEN';

  /// Whether the PR is closed unmerged (the run's `done` is recorded as
  /// "closed unmerged" when this is the PR's fate).
  bool get isClosedUnmerged => state == 'CLOSED';

  @override
  bool operator ==(Object other) =>
      other is PrInfo &&
      other.number == number &&
      other.url == url &&
      other.state == state;

  @override
  int get hashCode => Object.hash(number, url, state);

  @override
  String toString() => 'PrInfo(number: $number, url: $url, state: $state)';
}

/// The GitHub reader the AFK system reads through (spec #376: the Ready
/// gate's poller, T2, and the run service, T3).
///
/// A **thin interface**:
/// - [listReadyIssues]: open issues carrying the `ready-for-agent` label —
///   the gate's entry; the poller admits the ones without a run row.
/// - [readIssueState]: the issue's state as gh reports it ("OPEN" /
///   "CLOSED"); `''` when the read fails or the field is missing.
/// - [readLastComment]: the issue's last comment (id + body) — the agent's
///   terminal narration rides on it; `null` when there are none.
/// - [hasLabel]: whether the issue carries [label] (the run service's
///   ready-check on a run's issue, and the deliberate retry's).
/// - [readPr]: the PR's number, URL, and state — the run service's
///   `pr-open` confirmation and its `done` follow; `null` when unreadable.
/// - [addLabel]: the terminal failure's `needs-triage` label (the
///   deliberate retry's `ready-for-agent` is added by the human, never the
///   bridge).
/// - [addComment]: the terminal failure's comment on the issue.
///
/// The real implementation ([GhGitHubReader]) shells out to the `gh` CLI —
/// the bridge's existing pattern for `gh` — so the poller's and the run
/// service's passes need no network of their own: an unreachable `gh` makes
/// every read fail and the pass inert. Tests fake this interface; the real
/// `gh` calls are not unit-tested (the JSON shapes are validated against
/// the live CLI).
abstract class GitHubReader {
  /// Open issues carrying the `ready-for-agent` label (number + title).
  Future<List<ReadyIssue>> listReadyIssues();

  /// The issue's state ("OPEN" / "CLOSED") or `''` when unreadable.
  Future<String> readIssueState(int issueNumber);

  /// The issue's last comment (id + body), or `null` when there are none.
  Future<IssueComment?> readLastComment(int issueNumber);

  /// Whether the issue carries [label].
  Future<bool> hasLabel(int issueNumber, String label);

  /// The PR [prNumber]'s number, URL, and state, or `null` when the PR is
  /// unreadable (a failed `gh` read, a missing field).
  Future<PrInfo?> readPr(int prNumber);

  /// Add [label] to the issue (a no-op when it already carries it).
  Future<void> addLabel(int issueNumber, String label);

  /// Post [body] as a comment on the issue.
  Future<void> addComment(int issueNumber, String body);
}

/// The real [GitHubReader]: `gh` shells out — `gh issue list` / `gh issue
/// view`, the bridge's existing `gh` pattern ([Process.run], utf8), in the
/// bridge process's cwd, like the bridge's other `gh` calls.
class GhGitHubReader implements GitHubReader {
  /// The gate's entry label, passed as `gh issue list --label`.
  static const String readyLabel = 'ready-for-agent';

  /// The reader lists at most this many ready issues per pass — a gate that
  /// admitted only the first of many ready issues would silently miss the
  /// rest.
  static const int listLimit = 200;

  @override
  Future<List<ReadyIssue>> listReadyIssues() async {
    final result = await Process.run(
      'gh',
      [
        'issue',
        'list',
        '--state',
        'open',
        '--label',
        readyLabel,
        '--json',
        'number,title',
        '--limit',
        '$listLimit',
      ],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) return [];
    return _parseIssues(result.stdout as String);
  }

  /// The issues of `gh issue list --json number,title`: `[{number, title}]`
  /// — keep the well-formed rows, drop the rest (a corrupt row is skipped,
  /// never a throw).
  static List<ReadyIssue> _parseIssues(String stdout) {
    final Object? decoded;
    try {
      decoded = jsonDecode(stdout);
    } catch (_) {
      return [];
    }
    if (decoded is! List) return [];
    final out = <ReadyIssue>[];
    for (final row in decoded) {
      if (row is! Map) continue;
      final number = row['number'];
      final title = row['title'];
      if (number is! int || title is! String) continue;
      out.add(ReadyIssue(number: number, title: title));
    }
    return out;
  }

  @override
  Future<String> readIssueState(int issueNumber) async {
    final result = await Process.run(
      'gh',
      ['issue', 'view', '$issueNumber', '--json', 'state'],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) return '';
    final Object? decoded;
    try {
      decoded = jsonDecode(result.stdout as String);
    } catch (_) {
      return '';
    }
    if (decoded is! Map) return '';
    final state = decoded['state'];
    return state is String ? state : '';
  }

  @override
  Future<IssueComment?> readLastComment(int issueNumber) async {
    final result = await Process.run(
      'gh',
      ['issue', 'view', '$issueNumber', '--json', 'comments'],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(result.stdout as String);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final comments = decoded['comments'];
    if (comments is! List || comments.isEmpty) return null;
    final last = comments.last;
    if (last is! Map) return null;
    final id = last['id'];
    final body = last['body'];
    if (id is! String || body is! String) return null;
    return IssueComment(id: id, body: body);
  }

  @override
  Future<bool> hasLabel(int issueNumber, String label) async {
    final result = await Process.run(
      'gh',
      ['issue', 'view', '$issueNumber', '--json', 'labels'],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) return false;
    final Object? decoded;
    try {
      decoded = jsonDecode(result.stdout as String);
    } catch (_) {
      return false;
    }
    if (decoded is! Map) return false;
    final labels = decoded['labels'];
    if (labels is! List) return false;
    for (final row in labels) {
      if (row is Map && row['name'] == label) return true;
    }
    return false;
  }

  @override
  Future<PrInfo?> readPr(int prNumber) async {
    final result = await Process.run(
      'gh',
      ['pr', 'view', '$prNumber', '--json', 'number,url,state'],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(result.stdout as String);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final number = decoded['number'];
    final url = decoded['url'];
    final state = decoded['state'];
    if (number is! int || url is! String || state is! String) return null;
    return PrInfo(number: number, url: url, state: state);
  }

  @override
  Future<void> addLabel(int issueNumber, String label) async {
    final result = await Process.run(
      'gh',
      ['issue', 'edit', '$issueNumber', '--add-label', label],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      throw Exception('gh issue edit failed: ${result.stderr}');
    }
  }

  @override
  Future<void> addComment(int issueNumber, String body) async {
    final result = await Process.run(
      'gh',
      ['issue', 'comment', '$issueNumber', '--body', body],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      throw Exception('gh issue comment failed: ${result.stderr}');
    }
  }
}
