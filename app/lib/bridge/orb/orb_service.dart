import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../model/orb.dart';
import '../docker/docker_backend.dart';
import '../events/bridge_event.dart';
import 'orb_image_builder.dart';

/// The result of one short git CLI invocation.
class GitCliResult {
  const GitCliResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Runs one git CLI argv and waits for it to exit (the short commands: the
/// remote probe and the host identity read). [workingDirectory] is the
/// child's working directory (the checkout-relative commands); `null`
/// inherits the bridge's.
typedef GitRunner = Future<GitCliResult> Function(
  List<String> argv, {
  String? workingDirectory,
});

/// Resolves the git CLI on this host's PATH, or `null` when it is not
/// found. [path] overrides `PATH` (tests). Mirrors [findHostDocker].
String? findHostGit({String? path}) {
  final pathValue = path ?? Platform.environment['PATH'] ?? '';
  for (final dir in pathValue.split(':')) {
    if (dir.isEmpty) continue;
    try {
      final candidate = File('$dir/git');
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

/// The host git CLI's [GitRunner] seam (like [DockerBackend.hostCli] is for
/// docker): the same host invocation the default [OrbService] uses.
GitRunner hostGitRunner(String binary) =>
    (argv, {workingDirectory}) =>
        _hostGitRun(binary, argv, workingDirectory: workingDirectory);

/// Runs one gh CLI argv and waits for it to exit (the short commands: the
/// PR-state read, issue #96).
typedef GhRunner = Future<GitCliResult> Function(List<String> argv);

/// Resolves the gh CLI on this host's PATH, or `null` when it is not
/// found. [path] overrides `PATH` (tests). Mirrors [findHostGit].
String? findHostGh({String? path}) {
  final pathValue = path ?? Platform.environment['PATH'] ?? '';
  for (final dir in pathValue.split(':')) {
    if (dir.isEmpty) continue;
    try {
      final candidate = File('$dir/gh');
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

/// The host gh CLI's [GhRunner] seam: the same host invocation the default
/// [OrbService] uses for the PR-state read.
GhRunner hostGhRunner(String binary) => (argv) => _hostGhRun(binary, argv);

/// The host's docker-bridge address (spec §8.5): the `docker0` interface's
/// address — the host's endpoint of the default bridge network the orb
/// containers are created on (they get no `--network` flag), the one they
/// use to reach the host. Falls back to the conventional docker bridge
/// address when the interface or its address cannot be read.
Future<String> hostDockerHostIp() async {
  try {
    final result = await Process.run(
      'ip',
      const ['-4', 'addr', 'show', 'docker0'],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode == 0) {
      final inet = RegExp(r'inet\s+(\d{1,3}(?:\.\d{1,3}){3})/')
          .firstMatch(result.stdout as String);
      if (inet != null) return inet.group(1)!;
    }
  } on ProcessException {
    // No `ip` binary on PATH: fall through to the conventional default.
  }
  return '172.17.0.1';
}

/// The orb name is already taken in the project (spec §2.3, up-front
/// refusal).
class OrbNameTakenError implements Exception {
  const OrbNameTakenError(this.project, this.name);

  final String project;
  final String name;

  @override
  String toString() => 'OrbNameTakenError($project, $name)';
}

/// An up-front creation refusal (spec §2.3): a named refusal the bridge
/// answers 400 with `details`, so the app can show the clear message.
class OrbRefusalError implements Exception {
  const OrbRefusalError(this.code, this.message);

  /// The project checkout has no `origin` remote.
  static const String noRemote = 'no_remote';

  /// The project's `origin` remote is not a GitHub remote (the push channel
  /// is gh-backed, spec §3).
  static const String nonGithubRemote = 'non_github_remote';

  /// The host git config has no commit identity (spec §3.1: the orb commits
  /// as the host's `user.name`/`user.email`).
  static const String missingGitIdentity = 'missing_git_identity';

  /// The refusal code (`no_remote`, `non_github_remote`,
  /// `missing_git_identity`).
  final String code;

  /// The clear message for the app.
  final String message;

  @override
  String toString() => 'OrbRefusalError($code: $message)';
}

/// The orb's boot did not complete (issue #93): the container exited during
/// boot, the boot timed out, or the descriptor could not be read back.
/// [logTail] carries the last container-log lines for the failure UI.
class OrbBootError implements Exception {
  const OrbBootError(this.id, this.detail, this.logTail);

  /// The orb id the failed boot was for.
  final String id;

  /// What went wrong (the boot reason).
  final String detail;

  /// The last container-log lines (most recent last).
  final List<String> logTail;

  @override
  String toString() => 'OrbBootError($id: $detail)';
}

/// There is nothing to clean for [id]: no orphan volumes exist (issue #96,
/// spec §2.2 — the explicit orphan cleanup found no orphan).
class OrbOrphanNotFoundError implements Exception {
  const OrbOrphanNotFoundError(this.id);

  final String id;

  @override
  String toString() => 'OrbOrphanNotFoundError($id)';
}

/// A container exists for [id]: a live (running, stopped, or broken) orb,
/// not an orphan (issue #96) — the orphan cleanup refuses to touch it; a
/// live orb's force-delete lands with the lifecycle actions.
class OrbExistsError implements Exception {
  const OrbExistsError(this.id);

  final String id;

  @override
  String toString() => 'OrbExistsError($id)';
}

/// The bridge-side orb creation and list (issue #93, spec §2.3/§2.2):
/// [create] is the full bridge-owned creation sequence (refusals up front,
/// image ensure, labeled volumes + state dir, `docker create` with all the
/// flags, `.env*` + config/auth injection, `docker start`, the boot wait
/// with the descriptor read back and verified); [list] composes the orb
/// list from the `ocb.*` labels (no registry file).
class OrbService {
  OrbService({
    required this.imageBuilder,
    required this.run,
    required this.spawn,
    required this.git,
    required this.home,
    required this.stateRoot,
    required this.bridgePort,
    this.emit,
    this.hostIp,
    this.gh,
    this.repoFor,
    this.bootTimeout = const Duration(minutes: 10),
    this.pollInterval = const Duration(milliseconds: 500),
  });

  /// The in-container port opencode serves on (spec §2.9): the single
  /// constant shared by the entrypoint and the `-p` mapping. The host port
  /// is ephemeral (`-p 127.0.0.1:0:<port>`); only this one is fixed.
  static const int inContainerPort = 4096;

  /// The max container-log lines kept as the boot-failure tail.
  static const int maxTailLines = 20;

  /// The image pipeline (the first step of creation, spec §5.3).
  final OrbImageBuilder imageBuilder;

  /// The docker CLI runner (the short commands).
  final DockerRunner run;

  /// The docker CLI spawner (`docker logs --follow`, the boot stream).
  final DockerSpawner spawn;

  /// The host git CLI runner (the remote probe and the identity read).
  final GitRunner git;

  /// The host user's home (the mounted auth dirs, the opencode config/auth,
  /// the state root's sibling paths).
  final String home;

  /// The orb state dirs' root (`<stateRoot>/<id>/` per orb, spec §2.7).
  final Directory stateRoot;

  /// The bridge's host port: the `bridgeUrl` written into the container-
  /// local config (`http://host.docker.internal:<port>`, spec §6.2/§8.5).
  final int bridgePort;

  /// Where the boot-log events go (the event hub's `emit`); `null` when
  /// this machine has no event hub, in which case the boot output is only
  /// drained.
  final void Function(String)? emit;

  /// The host's docker-bridge address for `--add-host=host.docker.internal`
  /// (spec §8.5); the default reads the default route's gateway.
  final Future<String> Function()? hostIp;

  /// The host gh CLI runner (the PR-state read, issue #96); `null` when this
  /// machine has no `gh` on its PATH, in which case `list` never carries the
  /// PR state even when asked for it.
  final GhRunner? gh;

  /// Resolves the `owner/repo` of a project id for the PR query (issue #96):
  /// the project's `origin` remote, parsed to `owner/repo`. `null` when the
  /// bridge cannot resolve projects (no PR state then either).
  final Future<String?> Function(String projectId)? repoFor;

  /// How long the boot wait runs before it fails the create.
  final Duration bootTimeout;

  /// The boot wait's poll pace.
  final Duration pollInterval;

  /// Create the orb [name] in [project] (the project's canonical checkout is
  /// [checkout]) and wait for its boot (spec §2.3). The password is derived
  /// and verified internally (ADR-0001: it is never exposed through the
  /// bridge); the returned record carries the ephemeral-URL descriptor.
  Future<OrbRecord> create({
    required String project,
    required String name,
    required String checkout,
  }) async {
    // The up-front refusals (spec §2.3), in order.
    await _refuseIfNameTaken(project, name);
    final remote = await _remoteUrl(checkout);
    final gitIdentity = await _hostGitIdentity();

    final tag = await imageBuilder.ensureImage();

    final id = _mintId();
    final container = 'orb-$id';
    final created = DateTime.now().toUtc().toIso8601String();
    final branch = 'orb/$id';

    // The workspace + data volumes (labeled, §2.1) and the state dir.
    await _createVolume(
      'orb-$id-workspace',
      id,
      name,
      project,
      branch,
      created,
    );
    await _createVolume('orb-$id-data', id, name, project, branch, created);
    final stateDir = Directory('${stateRoot.path}/$id')
      ..createSync(recursive: true);

    // `docker create` first, with every flag (spec §2.3 step 5): the orb is
    // fully described before any file moves into it.
    final host = await (hostIp ?? hostDockerHostIp)();
    await _runOrThrow([
      'create',
      '--name',
      container,
      '-p',
      '127.0.0.1:0:$inContainerPort',
      '--add-host',
      'host.docker.internal:$host',
      '-v',
      '$home/.ssh:/root/.ssh:ro',
      '-v',
      '$home/.config/gh:/root/.config/gh:ro',
      '-v',
      'orb-$id-workspace:/workspace',
      '-v',
      'orb-$id-data:/var/lib/orb-data',
      '-v',
      '${stateDir.path}:/root/.local',
      '-e',
      'ORB_ID=$id',
      '-e',
      'ORB_REPO_URL=$remote',
      '-e',
      'ORB_GIT_NAME=${gitIdentity.$1}',
      '-e',
      'ORB_GIT_EMAIL=${gitIdentity.$2}',
      '-l',
      'ocb.orb=true',
      '-l',
      'ocb.id=$id',
      '-l',
      'ocb.name=$name',
      '-l',
      'ocb.project=$project',
      '-l',
      'ocb.branch=$branch',
      '-l',
      'ocb.created=$created',
      tag,
    ]);

    // The host checkout's `.env*` (host-authoritative, §6.1): always before
    // the start, so the first-start clone runs over the injected files.
    for (final file in _envFiles(checkout)) {
      await _runOrThrow([
        'cp',
        file.path,
        '$container:/workspace/${file.path.split('/').last}',
      ]);
    }

    // The host's opencode config+auth (host-authoritative, §6.2): staged on
    // the host (the container is created, not started — no `docker exec`),
    // the bridge URL injected, then copied in.
    final staged = await _stageConfig(id);
    await _copyStagedConfig(container, staged);
    await _copyAuth(container);

    // The start: the entrypoint's first-start path (clone, hook,
    // container-local gitconfig — spec §6.3) then `opencode serve`.
    await _runOrThrow(['start', container]);

    // The boot wait: the follow stream (live events + the failure tail) and
    // the poll loop that reads back and verifies the descriptor (§7.1).
    final logProcess = await spawn(['logs', '--follow', container]);
    final tail = <String>[];
    _streamBootLines(id, logProcess, tail);
    try {
      final (url, password) = await _waitForBoot(id, container, tail);
      return OrbRecord(
        id: id,
        name: name,
        project: project,
        branch: branch,
        state: 'running',
        created: created,
        url: url,
      );
    } finally {
      await logProcess.kill();
    }
  }

  /// The orb list composed from the labels (spec §2.2): the labeled
  /// containers (running with their ephemeral URL, or stopped/broken) plus
  /// the labeled volumes without a container (orphans, surfaced for
  /// explicit cleanup — never auto-deleted). A container whose boot has not
  /// completed is `preparing`, with the current boot stage as sub-state
  /// (issue #96, spec §9.3); [includePr] enriches each row with the PR of
  /// its branch, resolved through the host `gh` CLI (off by default — the
  /// composite services' hot path pays nothing, and the Orbs tab refreshes
  /// on foreground-return, not on a poll).
  Future<List<OrbRecord>> list({bool includePr = false}) async {
    final ps = await run([
      'ps',
      '-a',
      '--filter',
      'label=ocb.orb=true',
      '--format',
      '{{.Names}}',
    ]);
    if (ps.exitCode != 0) {
      throw DockerUnavailableError(ps.stderr.trim());
    }
    final containerNames = _lines(ps.stdout);

    final rows = <OrbRecord>[];
    final ids = <String>{};
    if (containerNames.isNotEmpty) {
      final labels = await run([
        'inspect',
        ...containerNames,
        '--format',
        '{{json .Config.Labels}}',
      ]);
      if (labels.exitCode != 0) {
        throw DockerUnavailableError(labels.stderr.trim());
      }
      final statuses = await run([
        'inspect',
        ...containerNames,
        '--format',
        '{{.State.Status}}',
      ]);
      if (statuses.exitCode != 0) {
        throw DockerUnavailableError(statuses.stderr.trim());
      }
      final ports = await run([
        'inspect',
        ...containerNames,
        '--format',
        '{{json .NetworkSettings.Ports}}',
      ]);
      if (ports.exitCode != 0) {
        throw DockerUnavailableError(ports.stderr.trim());
      }
      final labelLines = _lines(labels.stdout);
      final statusLines = _lines(statuses.stdout);
      final portLines = _lines(ports.stdout);
      for (var i = 0; i < containerNames.length; i++) {
        final status = statusLines[i].trim();
        final record = _containerRecord(
          labelLines[i],
          status,
          i < portLines.length ? portLines[i] : '',
        );
        if (record == null) continue;
        rows.add(
          await _withPreparingState(containerNames[i], status, record),
        );
        ids.add(record.id);
      }
    }

    // The labeled volumes: orphans (no container) and the broken checks'
    // workspace side.
    final volumes = await run([
      'volume',
      'ls',
      '--filter',
      'label=ocb.orb=true',
      '--format',
      '{{.Name}}',
    ]);
    if (volumes.exitCode != 0) {
      throw DockerUnavailableError(volumes.stderr.trim());
    }
    final volumeNames = _lines(volumes.stdout);
    final volumeLabels = <String, Map<String, Object?>>{};
    if (volumeNames.isNotEmpty) {
      final result = await run([
        'volume',
        'inspect',
        ...volumeNames,
        '--format',
        '{{json .Labels}}',
      ]);
      if (result.exitCode != 0) {
        throw DockerUnavailableError(result.stderr.trim());
      }
      final lines = _lines(result.stdout);
      for (var i = 0; i < volumeNames.length; i++) {
        if (i < lines.length) {
          final decoded = jsonDecode(lines[i]);
          if (decoded is Map<String, Object?>) {
            volumeLabels[volumeNames[i]] = decoded;
          }
        }
      }
    }

    // Re-check the broken containers against what the volumes say.
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row.state != 'stopped') continue;
      rows[i] = _withBrokenState(row, volumeNames);
    }

    for (final volumeName in volumeNames) {
      final id = _volumeOrbId(volumeName);
      if (id == null || ids.contains(id)) continue;
      final labels = volumeLabels[volumeName];
      if (labels == null) continue;
      rows.add(
        OrbRecord(
          id: id,
          name: labels['ocb.name'] as String? ?? '',
          project: labels['ocb.project'] as String? ?? '',
          branch: labels['ocb.branch'] as String? ?? '',
          state: 'orphan',
          created: labels['ocb.created'] as String? ?? '',
        ),
      );
      ids.add(id);
    }

    // The PR enrichment (issue #96, spec §9.1): one `gh pr view` per row,
    // in parallel (the list is a cold path; the badge shows when the PR is
    // open). A failure of any kind — no `gh`, no repo, no PR — leaves the
    // row without PR state.
    if (includePr) {
      final prs = await Future.wait([for (final row in rows) _prFor(row)]);
      rows.setAll(
        0,
        [for (var i = 0; i < rows.length; i++) _withPr(rows[i], prs[i])],
      );
    }
    return rows;
  }

  /// The preparing derivation (issue #96, spec §9.3): a container that has
  /// not finished booting yet — docker status `created` (the first start has
  /// not begun) or `running` whose log carries no `server password` line yet
  /// — is `preparing`, with the last `[orb] stage: <word>` line of its log as
  /// sub-state. The full log is read (a `--tail` window is unsafe: the
  /// password line sinks as opencode logs grow); the list is a cold path.
  Future<OrbRecord> _withPreparingState(
    String container,
    String status,
    OrbRecord record,
  ) async {
    if (status != 'created' && status != 'running') return record;
    var log = '';
    if (status == 'running') {
      log = await _fullLog(container);
      if (lastServerPassword(log) != null) return record;
    }
    final stage = lastStage(log);
    return _replacedState(record, stage == null ? 'preparing' : 'preparing:$stage');
  }

  /// The PR of [record]'s branch (issue #96): `gh pr view` for the head ref
  /// `orb/<id>` (positional — `gh pr view` has no `--head` flag; that flag
  /// belongs to `gh pr list`) in the project's repo. Every absence — no `gh`
  /// runner, no
  /// repo resolver, no resolvable repo, no PR, a failed call — is `null`
  /// (the badge simply does not render).
  Future<OrbPr?> _prFor(OrbRecord record) async {
    final runner = gh;
    final resolver = repoFor;
    if (runner == null || resolver == null) return null;
    String? repo;
    try {
      repo = await resolver(record.project);
    } catch (_) {
      // The project list is unreachable (opencode down, project gone):
      // no PR state.
      return null;
    }
    if (repo == null) return null;
    try {
      final result = await runner([
        'pr',
        'view',
        record.branch,
        '--repo',
        repo,
        '--json',
        'state,url',
      ]);
      if (result.exitCode != 0) return null; // No PR for the head ref.
      final decoded = jsonDecode(result.stdout);
      if (decoded is! Map<String, Object?>) return null;
      final state = (decoded['state'] as String? ?? '').toLowerCase();
      final url = decoded['url'] as String? ?? '';
      if (state.isEmpty || url.isEmpty) return null;
      return OrbPr(state: state, url: url);
    } on FormatException {
      return null; // Malformed output: treat as no PR.
    } catch (_) {
      return null; // A gh failure (auth, network) degrades to no PR.
    }
  }

  OrbRecord _withPr(OrbRecord record, OrbPr? pr) => OrbRecord(
    id: record.id,
    name: record.name,
    project: record.project,
    branch: record.branch,
    state: record.state,
    created: record.created,
    url: record.url,
    pr: pr,
  );

  /// The explicit orphan cleanup (spec §2.2 — surfaced in the Orbs tab,
  /// never auto-deleted; issue #96): removes the orphan's labeled volumes
  /// (`orb-<id>-workspace`, `orb-<id>-data` — either or both) and its state
  /// dir. [OrbExistsError] when a container still exists for the id (a live
  /// orb is not an orphan — its force-delete lands with the lifecycle
  /// actions, #98); [OrbOrphanNotFoundError] when neither volume exists.
  Future<void> deleteOrphan(String id) async {
    final container = await run(['inspect', 'orb-$id', '--format', '{{.Id}}']);
    if (container.exitCode == 0) {
      throw OrbExistsError(id);
    }
    if (container.exitCode != 1) {
      // `docker inspect` exits 1 for a missing container; anything else is
      // a daemon failure.
      throw DockerUnavailableError(container.stderr.trim());
    }
    final volumes = await run([
      'volume',
      'ls',
      '--filter',
      'name=orb-$id-',
      '--format',
      '{{.Name}}',
    ]);
    if (volumes.exitCode != 0) {
      throw DockerUnavailableError(volumes.stderr.trim());
    }
    final present = [
      for (final name in _lines(volumes.stdout))
        if (name == 'orb-$id-workspace' || name == 'orb-$id-data') name,
    ];
    if (present.isEmpty) throw OrbOrphanNotFoundError(id);
    for (final name in present) {
      await _runOrThrow(['volume', 'rm', name]);
    }
    final stateDir = Directory('${stateRoot.path}/$id');
    if (stateDir.existsSync()) {
      stateDir.deleteSync(recursive: true);
    }
  }

  /// Whether [url] is a GitHub remote url — `https://`, `http://`, the
  /// scp-like `git@github.com:`, or `ssh://` form (spec §2.3: the push
  /// channel is gh-backed, GitHub only).
  static bool isGitHubRemote(String url) {
    final u = url.trim();
    return u.startsWith('https://github.com/') ||
        u.startsWith('http://github.com/') ||
        u.startsWith('git@github.com:') ||
        u.startsWith('ssh://git@github.com/');
  }

  /// The password of the last `server password <pw>` line of [log] (spec
  /// §7.1: every start/respawn generates a new password — the last line
  /// wins), or `null` when the log has none.
  /// The current `server password` of orb [id]: the last `server password`
  /// line of its container log (spec §7.1: the password is re-derived at
  /// every start — the last line wins on a respawn). `null` when the
  /// container log cannot be read (the orb is gone or docker is down).
  Future<String?> lastPassword(String id) async {
    try {
      return lastServerPassword(await _fullLog('orb-$id'));
    } on DockerUnavailableError {
      return null;
    }
  }

  static String? lastServerPassword(String log) {
    String? password;
    for (final line in const LineSplitter().convert(log)) {
      const prefix = 'server password ';
      if (line.startsWith(prefix)) {
        final pw = line.substring(prefix.length).trim();
        if (pw.isNotEmpty) password = pw;
      }
    }
    return password;
  }

  /// The last boot stage word of [log] (the entrypoint's
  /// `[orb] stage: <word>` lines — spec §9.3), or `null` when the log has
  /// none (a boot that has not reached its first stage yet).
  static String? lastStage(String log) {
    String? stage;
    const prefix = '[orb] stage: ';
    for (final line in const LineSplitter().convert(log)) {
      if (line.startsWith(prefix)) {
        final word = line.substring(prefix.length).trim();
        if (word.isNotEmpty) stage = word;
      }
    }
    return stage;
  }

  /// The `owner/repo` a GitHub remote url encodes — the four forms
  /// [isGitHubRemote] accepts (https, http, scp-like, ssh://), with or
  /// without the `.git` suffix — or `null` when the url is not one of them
  /// (issue #96: the repo for the PR query).
  static String? githubRepo(String url) {
    final u = url.trim();
    String? rest;
    if (u.startsWith('https://github.com/')) {
      rest = u.substring('https://github.com/'.length);
    } else if (u.startsWith('http://github.com/')) {
      rest = u.substring('http://github.com/'.length);
    } else if (u.startsWith('git@github.com:')) {
      rest = u.substring('git@github.com:'.length);
    } else if (u.startsWith('ssh://git@github.com/')) {
      rest = u.substring('ssh://git@github.com/'.length);
    } else {
      return null;
    }
    if (rest.endsWith('.git')) {
      rest = rest.substring(0, rest.length - '.git'.length);
    }
    final parts = rest.split('/');
    if (parts.length != 2 || parts.any((p) => p.isEmpty)) return null;
    return '${parts[0]}/${parts[1]}';
  }

  // ------------------------------------------------------------------------
  // The creation steps.

  Future<void> _refuseIfNameTaken(String project, String name) async {
    final result = await run([
      'ps',
      '-a',
      '--filter',
      'label=ocb.orb=true',
      '--filter',
      'label=ocb.project=$project',
      '--format',
      '{{.Label "ocb.name"}}',
    ]);
    if (result.exitCode != 0) {
      throw DockerUnavailableError(result.stderr.trim());
    }
    for (final line in _lines(result.stdout)) {
      if (line == name) throw OrbNameTakenError(project, name);
    }
  }

  Future<String> _remoteUrl(String checkout) async {
    final result = await git([
      'remote',
      'get-url',
      'origin',
    ], workingDirectory: checkout);
    if (result.exitCode != 0) {
      throw const OrbRefusalError(
        OrbRefusalError.noRemote,
        'the project has no git remote to push the orb branch to',
      );
    }
    final url = result.stdout.trim();
    if (!OrbService.isGitHubRemote(url)) {
      throw OrbRefusalError(
        OrbRefusalError.nonGithubRemote,
        'the project remote is not a GitHub remote: $url',
      );
    }
    return url;
  }

  Future<(String, String)> _hostGitIdentity() async {
    final name = await _gitConfigValue('user.name');
    final email = await _gitConfigValue('user.email');
    if (name.isEmpty || email.isEmpty) {
      throw const OrbRefusalError(
        OrbRefusalError.missingGitIdentity,
        'the host git config has no user.name / user.email — the orb '
        'commits as the host identity (spec §3.1); set them and retry',
      );
    }
    return (name, email);
  }

  Future<String> _gitConfigValue(String key) async {
    final result = await git(['config', key], workingDirectory: home);
    if (result.exitCode != 0) return '';
    return result.stdout.trim();
  }

  Future<void> _createVolume(
    String name,
    String id,
    String orbName,
    String project,
    String branch,
    String created,
  ) async {
    await _runOrThrow([
      'volume',
      'create',
      '--name',
      name,
      '--label',
      'ocb.orb=true',
      '--label',
      'ocb.id=$id',
      '--label',
      'ocb.name=$orbName',
      '--label',
      'ocb.project=$project',
      '--label',
      'ocb.branch=$branch',
      '--label',
      'ocb.created=$created',
    ]);
  }

  Future<Directory> _stageConfig(String id) async {
    // Outside the per-orb state dir: that dir is bind-mounted into the
    // container as /root/.local, so anything staged there would leak into
    // the orb's home (and survive there after the start).
    final staged = Directory('${stateRoot.path}/staged-$id');
    if (staged.existsSync()) staged.deleteSync(recursive: true);
    staged.createSync(recursive: true);
    final source = Directory('$home/.config/opencode');
    if (source.existsSync()) {
      _copyTree(source, staged);
    }
    _injectBridgeUrl(staged);
    return staged;
  }

  /// Recursively copies [from] into [to] (host-authoritative, §6.2),
  /// skipping the per-service descriptors (`service.json` — spec §7.1: an
  /// orb derives its own descriptor, never inherits the host service's).
  void _copyTree(Directory from, Directory to) {
    for (final entity in from.listSync(followLinks: false)) {
      final name = entity.path.split('/').last;
      if (name == 'service.json') continue;
      if (entity is File) {
        entity.copySync('${to.path}/$name');
      } else if (entity is Directory) {
        final sub = Directory('${to.path}/$name')..createSync(recursive: true);
        _copyTree(entity, sub);
      }
    }
  }

  /// Writes the bridge URL (spec §6.2: `host.docker.internal`, §8.5) into
  /// the staged opencode config's top level, textually (the config is
  /// JSONC — `//` comments make parsing unsafe) — replacing the key when
  /// present, inserting it after the first `{` otherwise.
  void _injectBridgeUrl(Directory staged) {
    final url = 'http://host.docker.internal:$bridgePort';
    String? configPath;
    for (final name in const ['opencode.jsonc', 'opencode.json']) {
      final file = File('${staged.path}/$name');
      if (file.existsSync()) {
        configPath = file.path;
        break;
      }
    }
    if (configPath == null) {
      // No host opencode config: a minimal one, so the bridge URL still has
      // a home (the orb's tool reads it from the config, spec §6.2).
      configPath = '${staged.path}/opencode.json';
      File(configPath).writeAsStringSync('{}\n');
    }
    final file = File(configPath);
    final text = file.readAsStringSync();
    final updated = RegExp(r'"bridgeUrl"\s*:\s*"[^"]*"').hasMatch(text)
        ? text.replaceFirst(
            RegExp(r'"bridgeUrl"\s*:\s*"[^"]*"'),
            '"bridgeUrl": "$url"',
          )
        : text.replaceFirst(RegExp(r'\{'), '{\n  "bridgeUrl": "$url",');
    file.writeAsStringSync(updated);
  }

  Future<void> _copyStagedConfig(String container, Directory staged) async {
    // Per TOP-LEVEL entry, never per file: the container is created, not
    // started (no `docker exec`), and `docker cp` of a file into a
    // destination whose parent directory does not exist there fails, while a
    // directory copy creates its whole subtree in one call. The image's
    // /root/.config/opencode exists but is empty, so a top-level copy never
    // lands inside a pre-existing entry.
    for (final entry in staged.listSync(followLinks: false)) {
      final name = entry.path.split('/').last;
      await _runOrThrow([
        'cp',
        entry.path,
        '$container:/root/.config/opencode/$name',
      ]);
    }
  }

  Future<void> _copyAuth(String container) async {
    final auth = File('$home/.local/share/opencode/auth.json');
    if (!auth.existsSync()) return; // Copy-if-exists (host-authoritative).
    await _runOrThrow([
      'cp',
      auth.path,
      '$container:/root/.local/share/opencode/auth.json',
    ]);
  }

  /// The host checkout's `.env*` files, host-authoritative (spec §6.1):
  /// `.env` + `.env.*`, excluding `*.example`, in name order.
  List<File> _envFiles(String checkout) {
    final dir = Directory(checkout);
    if (!dir.existsSync()) return const [];
    final files = dir.listSync(followLinks: false).whereType<File>().where((f) {
      final name = f.path.split('/').last;
      if (name == '.env') return true;
      return name.startsWith('.env.') && !name.endsWith('.example');
    }).toList()..sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  void _streamBootLines(String id, DockerProcess process, List<String> tail) {
    void line(String l) {
      tail.add(l);
      if (tail.length > OrbService.maxTailLines) tail.removeAt(0);
      final emitter = emit;
      if (emitter != null) {
        emitter(
          bridgeEvent(
            type: BridgeEventType.orbBoot,
            data: {'id': id, 'line': l},
          ),
        );
      }
    }

    // Drained unconditionally (a full pipe would stall the container's
    // logging); the lines become events only when there is a hub.
    process.stdout.listen(line, onError: (Object _) {});
    process.stderr.listen(line, onError: (Object _) {});
  }

  Future<(String url, String password)> _waitForBoot(
    String id,
    String container,
    List<String> tail,
  ) async {
    final deadline = DateTime.now().add(bootTimeout);
    String? password;
    int? port;
    while (true) {
      if (DateTime.now().isAfter(deadline)) {
        throw OrbBootError(
          id,
          'the orb did not come up within $bootTimeout',
          List.of(tail),
        );
      }
      final state = await _inspectState(container);
      if (state == 'exited' || state == 'dead') {
        final log = await _fullLog(container);
        throw OrbBootError(
          id,
          'the orb container exited during boot',
          _logTail(log),
        );
      }
      if (state == 'running') {
        password ??= lastServerPassword(await _fullLog(container));
        if (password != null && port == null) {
          port = await _hostPort(id, container);
        }
        if (password != null && port != null) {
          final url = 'http://127.0.0.1:$port';
          if (await _verifyDescriptor(url, password)) {
            return (url, password);
          }
          // Not accepting connections yet (or the auth did not verify):
          // the next poll retries.
        }
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  /// The descriptor verification (issue #93): the orb's `/api/session`
  /// with the Basic `opencode:<password>` auth (spec §7.1) — `true` on the
  /// 200. A refused connection is the server not up yet, not a failure.
  Future<bool> _verifyDescriptor(String url, String password) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('$url/api/session'));
      request.headers.set(
        'Authorization',
        'Basic ${base64.encode(utf8.encode('opencode:$password'))}',
      );
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } on SocketException {
      return false;
    } on HttpException {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _inspectState(String container) async {
    final result = await run([
      'inspect',
      '--format',
      '{{.State.Status}}',
      container,
    ]);
    if (result.exitCode != 0) {
      throw DockerUnavailableError(result.stderr.trim());
    }
    return result.stdout.trim();
  }

  Future<String> _fullLog(String container) async {
    final result = await run(['logs', container]);
    if (result.exitCode != 0) {
      throw DockerUnavailableError(result.stderr.trim());
    }
    return result.stdout;
  }

  Future<int> _hostPort(String id, String container) async {
    final result = await run([
      'inspect',
      '--format',
      '{{json .NetworkSettings.Ports}}',
      container,
    ]);
    if (result.exitCode != 0) {
      throw DockerUnavailableError(result.stderr.trim());
    }
    final decoded = jsonDecode(result.stdout);
    final ports = decoded is Map<String, Object?> ? decoded : const {};
    final bindings = ports['$inContainerPort/tcp'];
    if (bindings is List) {
      for (final entry in bindings) {
        if (entry is Map<String, Object?>) {
          final hostPort = entry['HostPort'];
          if (hostPort is String && hostPort.isNotEmpty) {
            return int.parse(hostPort);
          }
        }
      }
    }
    throw OrbBootError(
      id,
      'the container has no host port for $inContainerPort',
      const [],
    );
  }

  Future<void> _runOrThrow(List<String> argv) async {
    final result = await run(argv);
    if (result.exitCode != 0) {
      throw DockerUnavailableError(result.stderr.trim());
    }
  }

  String _mintId() {
    final random = Random.secure();
    return List.generate(8, (_) => random.nextInt(16).toRadixString(16)).join();
  }

  // ------------------------------------------------------------------------
  // The list composition.

  OrbRecord? _containerRecord(
    String labelsJson,
    String state,
    String portsJson,
  ) {
    final decoded = jsonDecode(labelsJson);
    if (decoded is! Map<String, Object?>) return null;
    final id = decoded['ocb.id'] as String?;
    if (id == null || id.isEmpty) return null;
    String? url;
    if (state == 'running') {
      final parsed = jsonDecode(portsJson);
      final ports = parsed is Map<String, Object?> ? parsed : const {};
      final bindings = ports['$inContainerPort/tcp'];
      if (bindings is List) {
        for (final entry in bindings) {
          if (entry is Map<String, Object?>) {
            final hostPort = entry['HostPort'];
            if (hostPort is String && hostPort.isNotEmpty) {
              url = 'http://127.0.0.1:$hostPort';
              break;
            }
          }
        }
      }
    }
    return OrbRecord(
      id: id,
      name: decoded['ocb.name'] as String? ?? '',
      project: decoded['ocb.project'] as String? ?? '',
      branch: decoded['ocb.branch'] as String? ?? '',
      state: state == 'running' ? 'running' : 'stopped',
      created: decoded['ocb.created'] as String? ?? '',
      url: url,
    );
  }

  OrbRecord _withBrokenState(OrbRecord record, List<String> volumeNames) {
    if (!volumeNames.contains('orb-${record.id}-workspace')) {
      return _replacedState(record, 'broken:workspace');
    }
    if (!Directory('${stateRoot.path}/${record.id}').existsSync()) {
      return _replacedState(record, 'broken:state');
    }
    return record;
  }

  OrbRecord _replacedState(OrbRecord record, String state) => OrbRecord(
    id: record.id,
    name: record.name,
    project: record.project,
    branch: record.branch,
    state: state,
    created: record.created,
    url: null,
    pr: record.pr,
  );

  /// The orb id a labeled volume name encodes (`orb-<id>-workspace` /
  /// `orb-<id>-data`), or `null` for an unrelated volume name.
  static String? _volumeOrbId(String volumeName) {
    final match = RegExp(r'^orb-(.+)-(workspace|data)$').firstMatch(volumeName);
    return match?.group(1);
  }

  List<String> _lines(String output) => [
    for (final line in const LineSplitter().convert(output))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  static List<String> _logTail(String log) {
    final lines = const LineSplitter()
        .convert(log)
        .where((l) => l.isNotEmpty)
        .toList();
    final n = lines.length > maxTailLines ? maxTailLines : lines.length;
    return lines.sublist(lines.length - n);
  }
}

Future<GitCliResult> _hostGitRun(
  String binary,
  List<String> argv, {
  String? workingDirectory,
}) async {
  final result = await Process.run(
    binary,
    argv,
    workingDirectory: workingDirectory,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  return GitCliResult(
    exitCode: result.exitCode,
    stdout: result.stdout as String,
    stderr: result.stderr as String,
  );
}

Future<GitCliResult> _hostGhRun(String binary, List<String> argv) async {
  final result = await Process.run(
    binary,
    argv,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  return GitCliResult(
    exitCode: result.exitCode,
    stdout: result.stdout as String,
    stderr: result.stderr as String,
  );
}
