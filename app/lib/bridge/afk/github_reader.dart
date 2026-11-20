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

/// The GitHub reader the AFK Ready gate's poller reads through (spec #376,
/// "The Ready gate and the feed", T2).
///
/// A **thin interface**:
/// - [listReadyIssues]: open issues carrying the `ready-for-agent` label —
///   the gate's entry; the poller admits the ones without a run row.
/// - [readIssueState]: the issue's state as gh reports it ("OPEN" /
///   "CLOSED"); `''` when the read fails or the field is missing.
/// - [readLastComment]: the issue's last comment body; `null` when there are
///   none.
///
/// The real implementation ([GhGitHubReader]) shells out to the `gh` CLI —
/// the bridge's existing pattern for `gh` — so the poller's admit loop needs
/// no network of its own: an unreachable `gh` makes every read fail and the
/// pass inert. Poller tests fake this interface; the real `gh` calls are
/// not unit-tested (the JSON shapes are validated against the live CLI).
abstract class GitHubReader {
  /// Open issues carrying the `ready-for-agent` label (number + title).
  Future<List<ReadyIssue>> listReadyIssues();

  /// The issue's state ("OPEN" / "CLOSED") or `''` when unreadable.
  Future<String> readIssueState(int issueNumber);

  /// The issue's last comment body, or `null` when there are none.
  Future<String?> readLastComment(int issueNumber);
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
  Future<String?> readLastComment(int issueNumber) async {
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
    final body = last['body'];
    return body is String ? body : null;
  }
}
