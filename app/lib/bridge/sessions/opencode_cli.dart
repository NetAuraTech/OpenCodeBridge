import 'dart:convert';
import 'dart:io';

/// The result of one short opencode CLI invocation (the session export and
/// import of the orb stop/wake sequence, issue #97).
class OpencodeCliResult {
  const OpencodeCliResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Runs one opencode CLI argv and waits for it to exit (the session export
/// and import, issue #97). [env] overlays the child's environment (the
/// export's `OPENCODE_PASSWORD`); the child's base environment is the
/// bridge's own — the runner merges it, because on Linux passing an
/// `environment:` to [Process.run] replaces the whole environment.
typedef OpencodeCliRunner = Future<OpencodeCliResult> Function(
  List<String> argv, {
  Map<String, String>? env,
});

/// Resolves the opencode CLI on this host's PATH, or `null` when it is not
/// found. [path] overrides `PATH` (tests). Mirrors the `findHostGit` /
/// `findHostGh` pattern in `orb_service.dart` (duplicated here to keep the
/// sessions slice free of an orb import — the orb service imports this
/// file, not the other way round).
String? findHostOpencode({String? path}) {
  final pathValue = path ?? Platform.environment['PATH'] ?? '';
  for (final dir in pathValue.split(':')) {
    if (dir.isEmpty) continue;
    try {
      final candidate = File('$dir/opencode');
      final stat = candidate.statSync();
      if (stat.type != FileSystemEntityType.file) continue;
      if ((stat.mode & 0x49) == 0) continue; // No exec bit (u/g/o).
      return candidate.path;
    } on FileSystemException {
      // Missing file or broken symlink: not this entry.
      continue;
    }
  }
  return null;
}

/// The host opencode CLI's [OpencodeCliRunner] seam: the same host
/// invocation the default `OrbService` uses (issue #97), like
/// `hostGitRunner` is for git.
OpencodeCliRunner hostOpencodeRunner(String binary) =>
    (argv, {env}) => _hostOpencodeRun(binary, argv, env: env);

Future<OpencodeCliResult> _hostOpencodeRun(
  String binary,
  List<String> argv, {
  Map<String, String>? env,
}) async {
  // `Process.run`'s `environment:` REPLACES the child's environment on
  // Linux: merge the overlay over the bridge's own environment, and pass
  // `null` (inherit) when there is no overlay.
  final environment = env == null ? null : {...Platform.environment, ...env};
  final result = await Process.run(
    binary,
    argv,
    environment: environment,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  return OpencodeCliResult(
    exitCode: result.exitCode,
    stdout: result.stdout as String,
    stderr: result.stderr as String,
  );
}
