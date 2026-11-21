/// The repo identity (spec #407): the `owner/repo` of the repository the
/// project's checkout tracks, resolved from its `origin` remote. It is the
/// one fact that pins both the AFK session's home (the checkout directory)
/// and the `gh` reader's working directory to the *same* checkout — the
/// #405 incident was the two diverging (the reader read the app's cwd, the
/// session landed in the wrong project). Two checkouts of the same repo
/// share one identity, and with it one armed state and one AFK session.
///
/// - [parseRepoIdentity] is the **pure** parser: `owner/repo` from an https
///   or ssh remote URL, `null` when the input is not such a URL (junk, no
///   owner/repo split, empty parts). Exhaustively unit-tested.
/// - [repoIdentityOf] is the **one git wrapper**: `git -C dir remote
///   get-url origin` (the bridge's `Process.run` pattern, like the GitHub
///   reader's `gh` shells) piped into [parseRepoIdentity]; `null` on any
///   failure (not a git dir, no `origin` remote, non-zero exit, unparseable
///   URL) — the project is then not armable (its arm toggle is hidden).
library;

import 'dart:convert';
import 'dart:io';

/// The remote the identity is read from: a project tracks its repo on
/// `origin`, and only `origin` counts (another remote is not the project's
/// tracker).
const String _originRemote = 'origin';

/// The pure parser: the `owner/repo` carried by an https
/// (`https://host/owner/repo[.git]`) or ssh (`git@host:owner/repo[.git]`)
/// remote URL, or `null` when [remoteUrl] is not one.
///
/// The host is whatever sits between the scheme (`https://`) or the user
/// separator (`git@host:`) and the path; it is accepted as-is (github,
/// gitlab, a self-hosted server). Exactly two path segments make an identity
/// — a third (a nested group, a sub-path) is a refusal, and a `.git` suffix
/// on the repo is stripped. An empty segment (an empty owner or repo) and
/// any other shape (no split, junk) answer `null`: never a partial identity,
/// never a throw.
String? parseRepoIdentity(String remoteUrl) {
  final text = remoteUrl.trim();
  // The path part that must be exactly owner/repo (the host is dropped in
  // both shapes: after the scheme for https, after the `:` for ssh).
  final scheme = text.indexOf('://');
  String? path;
  if (scheme > 0) {
    // https://host/owner/repo[.git] — drop the host (the first segment).
    final afterScheme = text.substring(scheme + '://'.length);
    final slash = afterScheme.indexOf('/');
    if (slash < 0) return null; // host but no owner/repo path.
    path = afterScheme.substring(slash + 1);
  } else {
    // scp-like ssh: git@host:owner/repo[.git] — drop the host (before the `:`).
    final colon = text.indexOf(':');
    final at = text.lastIndexOf('@');
    if (colon <= 0 || at <= 0 || at > colon) return null;
    path = text.substring(colon + 1);
  }
  final segments = path.split('/');
  if (segments.length != 2) return null;
  final owner = segments[0];
  var repo = segments[1];
  if (repo.endsWith('.git')) {
    repo = repo.substring(0, repo.length - '.git'.length);
  }
  if (owner.isEmpty || repo.isEmpty) return null;
  return '$owner/$repo';
}

/// Resolve [dir]'s repo identity: `git -C <dir> remote get-url origin`,
/// parsed by [parseRepoIdentity]. `null` on any failure — the directory is
/// not a git checkout, has no `origin` remote, git exits non-zero, or the
/// URL does not parse. The caller treats `null` as "not armable" (there is
/// nowhere for the agent to read its tracker).
Future<String?> repoIdentityOf(Directory dir) async {
  final result = await Process.run(
    'git',
    ['-C', dir.path, 'remote', 'get-url', _originRemote],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) return null;
  return parseRepoIdentity((result.stdout as String).trim());
}
