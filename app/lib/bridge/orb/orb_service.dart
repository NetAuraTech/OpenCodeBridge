import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../model/orb.dart';
import '../../model/session.dart';
import '../docker/docker_backend.dart';
import '../events/bridge_event.dart';
import '../sessions/opencode_cli.dart';
import '../sessions/opencode_http_service.dart';
import '../sessions/opencode_service.dart';
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
GhRunner hostGhRunner(String binary) =>
    (argv) => _hostGhRun(binary, argv);

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

  /// The orb is not wakeable: its state is not `stopped` (issue #97, spec
  /// §2.4).
  static const String notWakeable = 'not_wakeable';

  /// The project checkout cannot be resolved on the host (the move-to-orb's
  /// create, issue #97).
  static const String missingCheckout = 'missing_checkout';

  /// The orb is not running (the per-orb session create, issue #97).
  static const String notRunning = 'not_running';

  /// The orb is not updatable: its state is neither `running` nor `stopped`
  /// (the per-orb image update, issue #98, spec §2.8).
  static const String notUpdatable = 'not_updatable';

  /// The running orb is busy (an active session or a pending permission) —
  /// the update is never forced (issue #98, spec §2.8/§2.10.1).
  static const String updateBusy = 'update_busy';

  /// The orb's workspace volume is missing (the export, issue #98, spec
  /// §3.4): there is nothing to export.
  static const String missingWorkspace = 'missing_workspace';

  /// The refusal code (`no_remote`, `non_github_remote`,
  /// `missing_git_identity`, `not_wakeable`, `missing_checkout`,
  /// `not_running`, `not_updatable`, `update_busy`, `missing_workspace`).
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

/// The orb id has no record — no labeled container (issue #97): the
/// lifecycle endpoints answer 404.
class OrbNotFoundError implements Exception {
  const OrbNotFoundError(this.id);

  final String id;

  @override
  String toString() => 'OrbNotFoundError($id)';
}

/// The deletion guard's evaluation for one orb (issue #98, spec §2.7):
/// whether the workspace could be inspected at all, and — when it could —
/// the dirty-tree lines and the unpushed-commit count. The automated
/// lifecycle pass re-evaluates this as-is: a not-deletable orb is kept,
/// never force-deleted (spec §2.10.2).
class OrbDeletionGuard {
  const OrbDeletionGuard({
    required this.evaluable,
    this.dirty = const [],
    this.unpushedCount = 0,
  });

  /// Whether the workspace could be inspected (a container with a readable
  /// git state). `false` means the guard cannot prove the workspace is
  /// safe — deletion is refused without force (never delete the
  /// unverifiable).
  final bool evaluable;

  /// The `git status --porcelain` lines (untracked included, ignored
  /// excluded) — empty when the tree is clean.
  final List<String> dirty;

  /// The commits not on any remote (`git rev-list --count HEAD --not
  /// --remotes`).
  final int unpushedCount;

  /// The guard's verdict: deletable when it was evaluable and nothing
  /// needs protecting (clean tree + everything pushed).
  bool get canDelete => evaluable && dirty.isEmpty && unpushedCount == 0;

  /// The machine-readable refusal words (spec §2.7): `workspace_missing`
  /// (no inspectable workspace — no container, or an unreadable git
  /// state), `dirty_tree`, `unpushed_commits` — empty when [canDelete].
  List<String> get reasons {
    if (canDelete) return const [];
    if (!evaluable) return const ['workspace_missing'];
    return [
      if (dirty.isNotEmpty) 'dirty_tree',
      if (unpushedCount > 0) 'unpushed_commits',
    ];
  }
}

/// The deletion guard refused the deletion of [id] (issue #98, spec
/// §2.7): the bridge answers 409 with [guard]'s reasons. An explicit
/// force overrides the guard (`force: true` — a human UI action, or an
/// agent within its spawn tree, §8.4; the automated path never forces).
class OrbDeletionRefusedError implements Exception {
  const OrbDeletionRefusedError(this.id, this.guard);

  /// The orb id the deletion was refused for.
  final String id;

  /// The guard's evaluation (its `reasons` are the refusal words).
  final OrbDeletionGuard guard;

  @override
  String toString() => 'OrbDeletionRefusedError($id: ${guard.reasons})';
}

/// A single session could not be moved (its export or its import failed,
/// issue #97): [detail] is the CLI's error output.
class OrbSessionMoveError implements Exception {
  const OrbSessionMoveError(this.session, this.detail);

  /// The session id the move failed on.
  final String session;

  /// The CLI's error detail (the stderr, or the stdout when the stderr is
  /// empty).
  final String detail;

  @override
  String toString() => 'OrbSessionMoveError($session: $detail)';
}

/// The stop or a move cannot run: the host opencode CLI, the host sessions
/// service, the project checkout lookup, or the orb's password (issue #97)
/// is not available.
class OrbSessionsUnavailableError implements Exception {
  const OrbSessionsUnavailableError(this.detail);

  final String detail;

  @override
  String toString() => 'OrbSessionsUnavailableError($detail)';
}

/// One endpoint the opencode CLI talks to during a session move (issue
/// #97): the service the session is deleted from, and the CLI's
/// `--server` / `OPENCODE_PASSWORD` overlay for reaching it. Both `null`
/// is the host endpoint — no `--server` flag, no password environment (the
/// host CLI finds the shared opencode service by default).
class OpencodeEndpoint {
  const OpencodeEndpoint({required this.service, this.server, this.password});

  final OpencodeService service;
  final String? server;
  final String? password;
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
    this.opencodeCli,
    this.checkoutFor,
    this.hostSessions,
    this.orbServiceFor,
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

  /// The host opencode CLI runner (the stop/wake session export and import,
  /// issue #97). `null` when this machine has no opencode CLI on its PATH —
  /// the stop and the moves then refuse with [OrbSessionsUnavailableError].
  final OpencodeCliRunner? opencodeCli;

  /// Resolves a project id to its host checkout (the stop's import
  /// `--directory` and the wake's `.env*` source, issue #97). `null` when
  /// the bridge cannot resolve projects — the stop then refuses with
  /// [OrbSessionsUnavailableError] and the move-to-orb's create with
  /// [OrbRefusalError.missingCheckout].
  final Future<String?> Function(String projectId)? checkoutFor;

  /// The host's shared opencode service (the stop's import target, the
  /// move-to-orb's source, issue #97). `null` when this machine has no
  /// shared service — the stop and the moves then refuse with
  /// [OrbSessionsUnavailableError].
  final OpencodeService? hostSessions;

  /// Builds the per-orb opencode service (the move's orb side and the
  /// per-orb session create, issue #97). The default is a plain
  /// [OpencodeHttpService] for the given url and password (tests inject a
  /// fake).
  final OpencodeService Function(String url, String password)? orbServiceFor;

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
        rows.add(await _withPreparingState(containerNames[i], status, record));
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
      rows.setAll(0, [
        for (var i = 0; i < rows.length; i++) _withPr(rows[i], prs[i]),
      ]);
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
    return _replacedState(
      record,
      stage == null ? 'preparing' : 'preparing:$stage',
    );
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
    // Same root-owned content as the guarded deletion (spec §2.7): the
    // orphan's container is gone, so the throwaway clean runs on the
    // current shared image.
    await _removeStateDir(id, await imageBuilder.ensureImage());
    _removeStagedConfig(id);
  }

  // ------------------------------------------------------------------------
  // The orb lifecycle: stop (move to host), wake, session moves
  // (issue #97, spec §2.4/§2.5).

  /// Whether [id] has the `ocb.stopped` marker (a stopped orb, issue #97):
  /// the card's state gate (Stop while running, Wake while stopped).
  /// Container labels are immutable at runtime, so the marker is a file in
  /// the per-orb state dir (`<stateRoot>/<id>/stopped`): created at the end
  /// of a successful stop, removed at the end of a successful wake.
  bool isStopped(String id) => _stoppedMarker(id).existsSync();

  File _stoppedMarker(String id) => File('${stateRoot.path}/$id/stopped');

  Future<void> _setStoppedMarker(String id) async {
    final marker = _stoppedMarker(id);
    await marker.parent.create(recursive: true);
    await marker.writeAsString(DateTime.now().toUtc().toIso8601String());
  }

  Future<void> _removeStoppedMarker(String id) async {
    final marker = _stoppedMarker(id);
    if (marker.existsSync()) {
      await marker.delete();
    }
  }

  /// The record of the orb [id] (from the label-composed list), or `null`
  /// when the id has no labeled container.
  Future<OrbRecord?> _record(String id) async {
    for (final record in await list()) {
      if (record.id == id) return record;
    }
    return null;
  }

  /// The per-orb opencode service for [url]/[password]: the injected
  /// factory's build, or a plain [OpencodeHttpService].
  OpencodeService _orbService(String url, String password) {
    final factory = orbServiceFor;
    if (factory != null) return factory(url, password);
    return OpencodeHttpService(baseUrl: Uri.parse(url), password: password);
  }

  /// The orb's service url: the descriptor's ephemeral url from the list,
  /// re-read from the container's port mapping when the list carried none.
  Future<String> _orbUrl(String id, OrbRecord record) async {
    final url = record.url;
    if (url != null && url.isNotEmpty) return url;
    return 'http://127.0.0.1:${await _hostPort(id, 'orb-$id')}';
  }

  /// The CLI's `--server <url>` args for [server] (none for the host).
  List<String> _serverArgs(String? server) =>
      server == null ? const <String>[] : ['--server', server];

  /// The CLI's environment overlay for [password] (none for the host).
  Map<String, String>? _passwordEnv(String? password) =>
      password == null ? null : {'OPENCODE_PASSWORD': password};

  /// The detail to surface from a failed CLI call: the stderr (the CLI's
  /// error channel), or the stdout when the stderr is empty.
  String _cliDetail(OpencodeCliResult result) {
    final detail = result.stderr.trim();
    if (detail.isNotEmpty) return detail;
    return result.stdout.trim();
  }

  /// Whether a failed session import is the idempotent 409 (the session
  /// already exists on the target — a move re-run, issue #97).
  bool _isImport409(OpencodeCliResult result) {
    if (result.exitCode == 0) return false;
    return RegExp(
      r'409|conflict',
      caseSensitive: false,
    ).hasMatch('${result.stdout}\n${result.stderr}');
  }

  /// The orb stop (issue #97, spec §2.5): the single trigger for every orb
  /// death path. It is unguarded (lossless — the guard exists only on
  /// delete): it exports every session on the orb (top-level plus
  /// child/subagent, one by one — an in-flight session as its history up to
  /// now), imports each into the host checkout (idempotent — a 409 is the
  /// session already there), deletes it from the orb only after its import
  /// succeeded, then `docker stop`s the container last and sets the
  /// `ocb.stopped` marker (the wake's gate). A re-issue while stopped is a
  /// safe no-op.
  Future<void> stop(String id) async {
    final record = await _record(id);
    if (record == null) throw OrbNotFoundError(id);
    if (record.state != 'running') return;
    final cli = opencodeCli;
    final host = hostSessions;
    final resolve = checkoutFor;
    if (cli == null || host == null || resolve == null) {
      throw OrbSessionsUnavailableError(
        'the host opencode CLI, the host sessions service, or the project '
        'checkout lookup is not available on this bridge',
      );
    }
    final password = await lastPassword(id);
    if (password == null) {
      throw OrbSessionsUnavailableError(
        'the orb service password cannot be read from the orb logs',
      );
    }
    // Every session on the orb shares its project: the host checkout they
    // move into, resolved up front so a missing checkout fails before any
    // export.
    final checkoutPath = await resolve(record.project);
    if (checkoutPath == null || checkoutPath.trim().isEmpty) {
      throw OrbSessionsUnavailableError(
        'the project checkout is not available on the host',
      );
    }
    final url = await _orbUrl(id, record);
    final service = _orbService(url, password);
    final all = await service.listSessions();
    // Phase 1: export every session (top-level plus child/subagent), one
    // by one, into a temp file. The export is a full snapshot — a partial
    // turn becomes history, and the session is continuable from the host.
    // Staged in the system temp, never in the per-orb state dir (that dir
    // is bind-mounted into the container as /root/.local).
    final files = <String, File>{};
    try {
      for (final session in all) {
        final file = File(
          '${Directory.systemTemp.path}/ocb-stop-$id-${session.id}.json',
        )..createSync();
        try {
          final export = await cli([
            'session',
            'export',
            session.id,
            ..._serverArgs(url),
          ], env: _passwordEnv(password));
          if (export.exitCode != 0) {
            throw OrbSessionMoveError(session.id, _cliDetail(export));
          }
          await file.writeAsString(export.stdout);
          files[session.id] = file;
        } catch (_) {
          if (file.existsSync()) await file.delete();
          rethrow;
        }
      }
      // Phase 2: per session, import into the host checkout (409 = already
      // there, idempotent), then delete it from the orb only after its
      // import succeeded.
      for (final session in all) {
        final file = files[session.id]!;
        final import = await cli([
          'session',
          'import',
          file.path,
          '--directory',
          checkoutPath,
        ]);
        if (import.exitCode != 0 && !_isImport409(import)) {
          throw OrbSessionMoveError(session.id, _cliDetail(import));
        }
        try {
          await service.deleteSession(session.id);
        } catch (error) {
          throw OrbSessionMoveError(
            session.id,
            'the session import succeeded but the deletion from the orb '
            'failed: $error',
          );
        }
      }
      // `docker stop` last — only after every session has moved to the
      // host.
      await _runOrThrow(['stop', 'orb-$id']);
      // The wake's gate (issue #97, spec §2.4).
      await _setStoppedMarker(id);
    } finally {
      for (final file in files.values) {
        if (file.existsSync()) await file.delete();
      }
    }
  }

  /// The orb wake (issue #97, spec §2.4): re-runs the full start path on
  /// the same container/volumes/state — the `.env*` re-injection and the
  /// config/auth re-copy (host-authoritative, §6), `docker start`, the boot
  /// wait (entrypoint services + health gate — the first-start path is
  /// skipped, the clone exists), the ephemeral port re-read and the
  /// password re-read (the descriptor read back and verified, §7.1) — and
  /// removes the `ocb.stopped` marker only on success. It is lossless by
  /// construction: after a clean stop the orb holds no sessions, and after
  /// a crash its own are re-attached by the composite services. A
  /// re-issue while running is a safe no-op.
  Future<OrbRecord> wake(String id) async {
    final record = await _record(id);
    if (record == null) throw OrbNotFoundError(id);
    if (record.state == 'running') return record;
    if (record.state != 'stopped') {
      throw const OrbRefusalError(
        OrbRefusalError.notWakeable,
        'only a stopped orb can be woken',
      );
    }
    final container = 'orb-$id';
    // The `.env*` re-injection (host-authoritative, §6.1): the same copy
    // as the create. A missing checkout is non-fatal — the orb keeps the
    // env files of its last start.
    final resolve = checkoutFor;
    if (resolve != null) {
      final checkoutPath = await resolve(record.project);
      if (checkoutPath != null && checkoutPath.isNotEmpty) {
        for (final file in _envFiles(checkoutPath)) {
          await _runOrThrow([
            'cp',
            file.path,
            '$container:/workspace/${file.path.split('/').last}',
          ]);
        }
      }
    }
    // The config/auth re-copy (host-authoritative, §6.2): `docker cp`
    // works on the stopped container, as on the create.
    final staged = await _stageConfig(id);
    await _copyStagedConfig(container, staged);
    await _copyAuth(container);
    // The in-container service mints a fresh `server password` on every
    // start (spec §7.1) and the container log keeps the lines of every
    // previous boot: count them before the start so the boot wait skips
    // them and verifies only against the password this start mints
    // (a first poll racing the new line would otherwise pin the stale
    // one and fail verification for the whole boot timeout).
    final stalePasswords = countServerPasswords(await _fullLog(container));
    await _runOrThrow(['start', container]);
    // The boot wait: the follow stream (live `orb.boot` events) and the
    // poll loop that re-reads and verifies the descriptor (§7.1).
    final logProcess = await spawn(['logs', '--follow', container]);
    final tail = <String>[];
    _streamBootLines(id, logProcess, tail);
    try {
      final (url, password) = await _waitForBoot(
        id,
        container,
        tail,
        skipPasswords: stalePasswords,
      );
      await _removeStoppedMarker(id);
      return OrbRecord(
        id: id,
        name: record.name,
        project: record.project,
        branch: record.branch,
        state: 'running',
        created: record.created,
        url: url,
      );
    } finally {
      await logProcess.kill();
    }
  }

  /// The generic session move primitive (issue #97, spec §2.5): exports
  /// [session] from [source], imports it into [target] at [directory]
  /// (idempotent — a 409 is the session already there), and deletes it from
  /// [source] only after the import succeeded. Both directions (orb→host
  /// and host→orb) run through it; the target service must be running —
  /// the caller guarantees it (a wake or a create).
  Future<void> moveSession({
    required String session,
    required OpencodeEndpoint source,
    required OpencodeEndpoint target,
    required String directory,
  }) async {
    final cli = opencodeCli;
    if (cli == null) {
      throw OrbSessionsUnavailableError(
        'the host opencode CLI is not available on this bridge',
      );
    }
    final file = File(
      '${Directory.systemTemp.path}/ocb-move-$session-${DateTime.now().millisecondsSinceEpoch}.json',
    );
    try {
      final export = await cli([
        'session',
        'export',
        session,
        ..._serverArgs(source.server),
      ], env: _passwordEnv(source.password));
      if (export.exitCode != 0) {
        throw OrbSessionMoveError(session, _cliDetail(export));
      }
      await file.writeAsString(export.stdout);
      final import = await cli([
        'session',
        'import',
        file.path,
        '--directory',
        directory,
        ..._serverArgs(target.server),
      ], env: _passwordEnv(target.password));
      if (import.exitCode != 0 && !_isImport409(import)) {
        throw OrbSessionMoveError(session, _cliDetail(import));
      }
      try {
        await source.service.deleteSession(session);
      } catch (error) {
        throw OrbSessionMoveError(
          session,
          'the session import succeeded but the deletion from the source '
          'failed: $error',
        );
      }
    } finally {
      if (file.existsSync()) await file.delete();
    }
  }

  /// The host→orb move (issue #97, spec §2.5): one action, entirely through
  /// the bridge. [session] must live on the host service; the target orb is
  /// resolved by [orbName] within the session's project — woken when
  /// stopped, created (the full spec §2.3 sequence) when absent (its
  /// checkout resolved through [checkoutFor]), otherwise refused. The
  /// import's `--directory` is the orb's workspace (`/workspace`).
  Future<void> moveSessionToOrb({
    required String session,
    required String orbName,
  }) async {
    final cli = opencodeCli;
    final host = hostSessions;
    if (cli == null || host == null) {
      throw OrbSessionsUnavailableError(
        'the host opencode CLI and the host sessions service are not '
        'available on this bridge',
      );
    }
    OpencodeSession? source;
    for (final candidate in await host.listSessions()) {
      if (candidate.id == session) {
        source = candidate;
        break;
      }
    }
    if (source == null) {
      throw OrbSessionMoveError(
        session,
        'the session is not on the host service — it cannot be moved to an '
        'orb',
      );
    }
    OrbRecord? orb;
    for (final record in await list()) {
      if (record.project == source.projectId && record.name == orbName) {
        orb = record;
        break;
      }
    }
    if (orb == null) {
      // No such orb in the project: create it (spec §2.3) — the checkout
      // is the create's `.env*` source and the remote probe.
      final resolve = checkoutFor;
      final checkoutPath = resolve == null
          ? null
          : await resolve(source.projectId);
      if (checkoutPath == null || checkoutPath.trim().isEmpty) {
        throw const OrbRefusalError(
          OrbRefusalError.missingCheckout,
          'the project checkout is not available on the host — the orb '
          'cannot be created',
        );
      }
      orb = await create(
        project: source.projectId,
        name: orbName,
        checkout: checkoutPath,
      );
    } else if (orb.state == 'stopped') {
      orb = await wake(orb.id);
    } else if (orb.state != 'running') {
      throw const OrbRefusalError(
        OrbRefusalError.notWakeable,
        'the orb is not running and cannot be woken',
      );
    }
    final password = await lastPassword(orb.id);
    if (password == null) {
      throw OrbSessionsUnavailableError(
        'the orb service password cannot be read from the orb logs',
      );
    }
    final url = await _orbUrl(orb.id, orb);
    await moveSession(
      session: session,
      source: OpencodeEndpoint(service: host),
      target: OpencodeEndpoint(
        service: _orbService(url, password),
        server: url,
        password: password,
      ),
      directory: '/workspace',
    );
  }

  /// Create a session on the running orb [id] (issue #97, spec §9.5): the
  /// orb's workspace (`/workspace`) is the new session's working directory.
  /// The returned row is the home-list row as the orb service reports it —
  /// its `orb` is the orb id. A stopped orb refuses with
  /// [OrbRefusalError.notRunning] (wake it first).
  Future<Session> createSessionOnOrb(String id) async {
    final record = await _record(id);
    if (record == null) throw OrbNotFoundError(id);
    if (record.state != 'running') {
      throw const OrbRefusalError(
        OrbRefusalError.notRunning,
        'only a running orb can create a session',
      );
    }
    final password = await lastPassword(id);
    if (password == null) {
      throw OrbSessionsUnavailableError(
        'the orb service password cannot be read from the orb logs',
      );
    }
    final url = await _orbUrl(id, record);
    final service = _orbService(url, password);
    final session = await service.createSessionInDirectory('/workspace');
    final names = await service.projectNames();
    final active = await service.activeSessionIds();
    return Session(
      id: session.id,
      title: session.title,
      project: SessionProject(
        id: session.projectId,
        name: names[session.projectId] ?? '',
      ),
      created: session.created,
      location: session.location,
      active: active.contains(session.id),
      orb: id,
    );
  }

  // ------------------------------------------------------------------------
  // The exit paths: protected deletion, per-orb image update, the
  // `docker cp` export (issue #98, spec §2.7/§2.8/§3.4).

  /// The deletion guard's evaluation for [id] (issue #98, spec §2.7): the
  /// pure, reusable read the automated lifecycle pass re-evaluates on every
  /// pass (it never forces — a blocked orb is kept and surfaced).
  /// [OrbNotFoundError] when the id has no record. The checks run against
  /// the actual container state: a running container is probed with
  /// `docker exec git`; any other existing container is probed with a
  /// throwaway container over the same workspace volume (the image carries
  /// an entrypoint — `--entrypoint git` overrides it). Any git failure, a
  /// missing workspace volume, or an orphan (no container) is
  /// `evaluable: false` — the guard refuses without force (never delete the
  /// unverifiable; the orphan's removal is the explicit orphan cleanup).
  Future<OrbDeletionGuard> deleteGuard(String id) async {
    final record = await _record(id);
    if (record == null) throw OrbNotFoundError(id);
    if (record.state == 'orphan') {
      return const OrbDeletionGuard(evaluable: false);
    }
    final container = 'orb-$id';
    final state = await _inspectState(container);
    if (state == 'running') {
      final status = await run([
        'exec',
        container,
        'git',
        '-C',
        '/workspace',
        'status',
        '--porcelain',
      ]);
      if (status.exitCode != 0) {
        return const OrbDeletionGuard(evaluable: false);
      }
      final unpushed = await run([
        'exec',
        container,
        'git',
        '-C',
        '/workspace',
        'rev-list',
        '--count',
        'HEAD',
        '--not',
        '--remotes',
      ]);
      if (unpushed.exitCode != 0) {
        return const OrbDeletionGuard(evaluable: false);
      }
      return _guardResult(status.stdout, unpushed.stdout);
    }
    // The container exists but is not running: a throwaway container over
    // the same workspace volume.
    if (!await _workspaceVolumePresent(id)) {
      return const OrbDeletionGuard(evaluable: false);
    }
    final image = await _containerImage(id);
    if (image == null) {
      return const OrbDeletionGuard(evaluable: false);
    }
    final status = await run([
      'run',
      '--rm',
      '--entrypoint',
      'git',
      '-v',
      'orb-$id-workspace:/ws',
      image,
      '-C',
      '/ws',
      'status',
      '--porcelain',
    ]);
    if (status.exitCode != 0) {
      return const OrbDeletionGuard(evaluable: false);
    }
    final unpushed = await run([
      'run',
      '--rm',
      '--entrypoint',
      'git',
      '-v',
      'orb-$id-workspace:/ws',
      image,
      '-C',
      '/ws',
      'rev-list',
      '--count',
      'HEAD',
      '--not',
      '--remotes',
    ]);
    if (unpushed.exitCode != 0) {
      return const OrbDeletionGuard(evaluable: false);
    }
    return _guardResult(status.stdout, unpushed.stdout);
  }

  /// The guard from two git outputs: the porcelain lines and the unpushed
  /// count — a parse failure of the count is unevaluable (never delete the
  /// unverifiable).
  OrbDeletionGuard _guardResult(String statusOut, String unpushedOut) {
    int count;
    try {
      count = int.parse(unpushedOut.trim());
    } on FormatException {
      return const OrbDeletionGuard(evaluable: false);
    }
    return OrbDeletionGuard(
      evaluable: true,
      dirty: _lines(statusOut),
      unpushedCount: count,
    );
  }

  /// The protected deletion (issue #98, spec §2.7): [OrbNotFoundError] when
  /// the id has no record; an `orphan` record goes through the explicit
  /// orphan cleanup ([deleteOrphan] — its semantics are unchanged).
  /// Otherwise the guard ([deleteGuard]) is evaluated first: when it
  /// refuses and [force] is false, [OrbDeletionRefusedError] carries its
  /// reasons. A guard pass or [force] removes the container, the workspace
  /// and data volumes, and the state dir (nothing port-wise to release —
  /// the port is ephemeral; the service data volume is wiped with it — the
  /// accepted consequence, the guard protects the git work, not the
  /// database content).
  Future<void> delete(String id, {bool force = false}) async {
    final record = await _record(id);
    if (record == null) throw OrbNotFoundError(id);
    if (record.state == 'orphan') {
      await deleteOrphan(id);
      return;
    }
    final guard = await deleteGuard(id);
    if (!force && !guard.canDelete) {
      throw OrbDeletionRefusedError(id, guard);
    }
    // The container's image, read before the removal: the state dir's
    // cleaner may need a throwaway container (below).
    final image = await _containerImage(id);
    await _runOrThrow(['rm', '-f', 'orb-$id']);
    // The state dir before the volumes: if its container-side clean fails,
    // the volumes still mark the orb and a retry re-enters through the
    // orphan cleanup — nothing left dangling.
    await _removeStateDir(id, image ?? await imageBuilder.ensureImage());
    _removeStagedConfig(id);
    await _removeVolume('orb-$id-workspace');
    await _removeVolume('orb-$id-data');
  }

  /// The last create/update/wake's config staging copy (`staged-<id>` in
  /// the state root, bridge-owned): a throwaway of the injection, gone with
  /// the deletion (nothing orb-related remains, spec §2.7).
  void _removeStagedConfig(String id) {
    final staged = Directory('${stateRoot.path}/staged-$id');
    if (staged.existsSync()) staged.deleteSync(recursive: true);
  }

  /// Removes the orb's state dir. The dir itself is bridge-owned, but the
  /// container writes through its `/root/.local` bind mount **as root**:
  /// root-owned files the host user cannot unlink (the boot's config, the
  /// opencode data). When the host-side recursive delete hits them, a
  /// throwaway container over the same mount deletes the contents as root,
  /// and the host removes the now-empty dir. [image] is any image present
  /// on the host for the throwaway run.
  Future<void> _removeStateDir(String id, String image) async {
    final stateDir = Directory('${stateRoot.path}/$id');
    if (!stateDir.existsSync()) return;
    try {
      stateDir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      // Root-owned content (the container wrote it): clean through docker.
      // A partial host-side delete may have taken some entries already —
      // the container-side clean is idempotent over the rest.
    }
    await _runOrThrow([
      'run',
      '--rm',
      '--entrypoint',
      'sh',
      '-v',
      '${stateDir.path}:/ocb-state',
      image,
      '-c',
      'find /ocb-state -mindepth 1 -delete',
    ]);
    stateDir.deleteSync();
  }

  /// Removes the volume [name], tolerating an already-absent volume
  /// (idempotent — a broken orb may be missing its workspace volume).
  Future<void> _removeVolume(String name) async {
    final result = await run(['volume', 'rm', name]);
    if (result.exitCode == 0) return;
    final stderr = result.stderr.toLowerCase();
    if (stderr.contains('no such volume') || stderr.contains('not found')) {
      return;
    }
    throw DockerUnavailableError(result.stderr.trim());
  }

  /// The per-orb image update (issue #98, spec §2.8): the container is
  /// recreated on the current shared image over the same workspace and data
  /// volumes — the code lives in the volume and is preserved, the
  /// container is disposable, the in-container rw layer (config, auth) is
  /// re-injected wake-style, and the `ocb.stopped` marker is untouched: a
  /// stopped orb is recreated (not started) and stays stopped. A running
  /// orb is only updatable while it is not busy — no active session and no
  /// pending permission (the update is never forced, and never automatic
  /// on wake) — and comes back running, with a fresh boot and a fresh
  /// ephemeral port. [OrbNotFoundError] for an unknown id; the named
  /// refusals are [OrbRefusalError.notUpdatable] (a state that is neither
  /// running nor stopped — `preparing`, `broken:*` — or a missing state
  /// dir) and [OrbRefusalError.updateBusy].
  Future<OrbRecord> update(String id) async {
    final record = await _record(id);
    if (record == null) throw OrbNotFoundError(id);
    final running = record.state == 'running';
    if (!running && record.state != 'stopped') {
      throw const OrbRefusalError(
        OrbRefusalError.notUpdatable,
        'only a running or a stopped orb can be updated',
      );
    }
    final container = 'orb-$id';
    if (running) {
      final password = await lastPassword(id);
      if (password == null) {
        throw OrbSessionsUnavailableError(
          'the orb service password cannot be read from the orb logs',
        );
      }
      final service = _orbService(await _orbUrl(id, record), password);
      if (await _hasBusySessions(service)) {
        throw const OrbRefusalError(
          OrbRefusalError.updateBusy,
          'the orb has a busy session (active or awaiting a permission) — '
          'finish it or stop the orb before the update',
        );
      }
    }
    final stateDir = Directory('${stateRoot.path}/$id');
    if (!stateDir.existsSync()) {
      throw const OrbRefusalError(
        OrbRefusalError.notUpdatable,
        'the orb state dir is missing — the orb cannot be updated',
      );
    }
    // The orb's own env, read while the container still exists (the
    // recreate re-applies it — the repo and the commit identity it
    // committed under are kept, spec §3.1).
    final env = await _orbEnv(container);
    final newTag = await imageBuilder.ensureImage();
    if (running) {
      await _runOrThrow(['stop', container]);
    }
    await _runOrThrow(['rm', container]);
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
      for (final entry in env) ...['-e', entry],
      '-l',
      'ocb.orb=true',
      '-l',
      'ocb.id=$id',
      '-l',
      'ocb.name=${record.name}',
      '-l',
      'ocb.project=${record.project}',
      '-l',
      'ocb.branch=${record.branch}',
      '-l',
      'ocb.created=${record.created}',
      newTag,
    ]);
    // The wake-style re-injection (host-authoritative, §6): the checkout's
    // `.env*` (non-fatal — a missing checkout keeps the last boot's files),
    // then the staged config and the auth into the fresh rw layer.
    final resolve = checkoutFor;
    if (resolve != null) {
      final checkoutPath = await resolve(record.project);
      if (checkoutPath != null && checkoutPath.isNotEmpty) {
        for (final file in _envFiles(checkoutPath)) {
          await _runOrThrow([
            'cp',
            file.path,
            '$container:/workspace/${file.path.split('/').last}',
          ]);
        }
      }
    }
    final staged = await _stageConfig(id);
    await _copyStagedConfig(container, staged);
    await _copyAuth(container);
    if (!running) {
      // A stopped orb stays stopped: the container is recreated (created,
      // not started) and the marker is untouched.
      return _replacedState(record, 'stopped');
    }
    // A fresh container holds a fresh log: no stale password lines to
    // skip.
    await _runOrThrow(['start', container]);
    final logProcess = await spawn(['logs', '--follow', container]);
    final tail = <String>[];
    _streamBootLines(id, logProcess, tail);
    try {
      final (url, password) = await _waitForBoot(id, container, tail);
      return OrbRecord(
        id: id,
        name: record.name,
        project: record.project,
        branch: record.branch,
        state: 'running',
        created: record.created,
        url: url,
      );
    } finally {
      await logProcess.kill();
    }
  }

  /// Whether the orb's service is busy (spec §2.10.1): an active session
  /// (TUI-attached, agent working) or a session with a pending permission
  /// request — a mid-turn state, the most fragile thing to carry through a
  /// recreation.
  Future<bool> _hasBusySessions(OpencodeService service) async {
    final active = await service.activeSessionIds();
    if (active.isNotEmpty) return true;
    for (final session in await service.listSessions()) {
      final pending = await service.pendingPermissions(session.id);
      if (pending.isNotEmpty) return true;
    }
    return false;
  }

  /// The container's own `ORB_*` env entries (`Key=Value` strings from its
  /// `Config.Env`), re-applied by the recreate (minus `ORB_ID`, which the
  /// recreate sets explicitly) — the recreate keeps the orb's repo and the
  /// commit identity it committed under (spec §3.1).
  Future<List<String>> _orbEnv(String container) async {
    final result = await run([
      'inspect',
      '--format',
      '{{json .Config.Env}}',
      container,
    ]);
    if (result.exitCode != 0) {
      throw DockerUnavailableError(result.stderr.trim());
    }
    final decoded = jsonDecode(result.stdout);
    if (decoded is! List) return const [];
    return [
      for (final entry in decoded)
        if (entry is String &&
            entry.startsWith('ORB_') &&
            !entry.startsWith('ORB_ID='))
          entry,
    ];
  }

  /// The `docker cp` export (issue #98, spec §3.4): a lossless tar.gz of
  /// the whole orb workspace (untracked files and `.git` included) written
  /// next to the project's local clone (the checkout's parent dir) with the
  /// deterministic [exportFileName] name — the user extracts and resumes
  /// exactly where the agent stopped. A running orb tars in place
  /// (`docker exec tar`, then `docker cp` out — a binary cannot flow
  /// through the string runner seam); a stopped or broken orb and an
  /// orphan use a throwaway container over the workspace volume with the
  /// target dir bind-mounted (`--entrypoint tar` overrides the image's
  /// entrypoint; the orphan runs on the current shared image). Returns the
  /// export file's path.
  Future<String> export(String id) async {
    final record = await _record(id);
    if (record == null) throw OrbNotFoundError(id);
    final resolve = checkoutFor;
    final checkout = resolve == null ? null : await resolve(record.project);
    if (checkout == null || checkout.trim().isEmpty) {
      throw const OrbRefusalError(
        OrbRefusalError.missingCheckout,
        'the project checkout is not available on the host — the workspace '
        'cannot be exported',
      );
    }
    final targetDir = File(checkout).parent.path;
    final fileName = exportFileName(
      record.name,
      record.id,
      DateTime.now().toUtc(),
    );
    final target = '$targetDir/$fileName';
    if (record.state != 'orphan') {
      final state = await _inspectState('orb-$id');
      if (state == 'running') {
        await _runOrThrow([
          'exec',
          'orb-$id',
          'tar',
          'czf',
          '/tmp/$fileName',
          '-C',
          '/workspace',
          '.',
        ]);
        await _runOrThrow(['cp', 'orb-$id:/tmp/$fileName', target]);
        // Best-effort cleanup inside the orb (the container is disposable).
        await run(['exec', 'orb-$id', 'rm', '-f', '/tmp/$fileName']);
        return target;
      }
    }
    // A non-running container (or none at all — the orphan): a throwaway
    // container over the workspace volume, writing into the bind-mounted
    // out dir.
    await _requireWorkspaceVolume(id);
    final image = record.state == 'orphan'
        ? await imageBuilder.ensureImage()
        : await _containerImage(id);
    if (image == null) {
      throw const OrbRefusalError(
        OrbRefusalError.missingWorkspace,
        'the orb container image cannot be read — the workspace cannot be '
        'exported',
      );
    }
    await _runOrThrow([
      'run',
      '--rm',
      '--entrypoint',
      'tar',
      '-v',
      'orb-$id-workspace:/ws',
      '-v',
      '$targetDir:/out',
      image,
      '-czf',
      '/out/$fileName',
      '-C',
      '/ws',
      '.',
    ]);
    return target;
  }

  /// Refuses when the orb's workspace volume is missing (issue #98, spec
  /// §3.4 — [OrbRefusalError.missingWorkspace]: there is nothing to
  /// export).
  Future<void> _requireWorkspaceVolume(String id) async {
    if (await _workspaceVolumePresent(id)) return;
    throw const OrbRefusalError(
      OrbRefusalError.missingWorkspace,
      'the orb workspace volume is missing — there is nothing to export',
    );
  }

  /// Whether the labeled volume `orb-<id>-workspace` exists (the filter is
  /// the id's prefix — the data volume may share it).
  Future<bool> _workspaceVolumePresent(String id) async {
    final result = await run([
      'volume',
      'ls',
      '--filter',
      'name=orb-$id-',
      '--format',
      '{{.Name}}',
    ]);
    if (result.exitCode != 0) {
      throw DockerUnavailableError(result.stderr.trim());
    }
    return _lines(result.stdout).contains('orb-$id-workspace');
  }

  /// The image reference the orb's own container was created from (its
  /// `Config.Image`) — what a throwaway container (the guard's git, the
  /// export's tar) runs on; `null` when the container does not exist or the
  /// image cannot be read.
  Future<String?> _containerImage(String id) async {
    final result = await run([
      'inspect',
      '--format',
      '{{.Config.Image}}',
      'orb-$id',
    ]);
    if (result.exitCode != 0) return null;
    final image = result.stdout.trim();
    return image.isEmpty ? null : image;
  }

  /// The export file name (issue #98, spec §3.4):
  /// `<sanitized name>-<id>-<YYYYMMDD-HHMMSS>UTC.tar.gz` — deterministic
  /// for a given (name, id, instant), pure (the lifecycle's tests pin the
  /// format). [now] is converted to UTC.
  static String exportFileName(String name, String id, DateTime now) {
    final utc = now.toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${utc.year}${two(utc.month)}${two(utc.day)}-'
        '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}UTC';
    return '${_exportNamePart(name)}-$id-$stamp.tar.gz';
  }

  /// The name part of the export file name: lowercased, every run of
  /// characters outside `[a-z0-9._-]` collapsed to one `-`, leading and
  /// trailing separators trimmed, `orb` when nothing is left.
  static String _exportNamePart(String name) {
    final cleaned = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'^[.-]+|[.-]+$'), '');
    return cleaned.isEmpty ? 'orb' : cleaned;
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

  /// The password of the last `server password <pw>` line of [log] (spec
  /// §7.1: every start/respawn generates a new password — the last line
  /// wins), or `null` when the log has none.
  static String? lastServerPassword(String log) =>
      lastServerPasswordAfter(log, 0);

  /// The password of the last `server password <pw>` line of [log] after
  /// skipping the first [skip] password lines (spec §7.1: every start
  /// mints a fresh password — a wake re-reads a log that already holds
  /// the passwords of every previous boot, so the wait for the new boot
  /// takes only the lines after them), or `null` when none remain.
  static String? lastServerPasswordAfter(String log, int skip) {
    String? password;
    var seen = 0;
    for (final line in const LineSplitter().convert(log)) {
      const prefix = 'server password ';
      if (line.startsWith(prefix)) {
        seen++;
        if (seen <= skip) continue;
        final pw = line.substring(prefix.length).trim();
        if (pw.isNotEmpty) password = pw;
      }
    }
    return password;
  }

  /// The number of `server password` lines in [log] (the boots already
  /// recorded in a container log — the wake skips them).
  static int countServerPasswords(String log) {
    var count = 0;
    for (final line in const LineSplitter().convert(log)) {
      if (line.startsWith('server password ')) count++;
    }
    return count;
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

  /// [skipPasswords] is the number of `server password` lines the log
  /// already held before this boot (a wake re-starts a container whose
  /// log keeps every previous boot's password — only the line this start
  /// mints is the one to verify with).
  Future<(String url, String password)> _waitForBoot(
    String id,
    String container,
    List<String> tail, {
    int skipPasswords = 0,
  }) async {
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
        password ??= lastServerPasswordAfter(
          await _fullLog(container),
          skipPasswords,
        );
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
