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
import '../../model/command.dart';
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

  /// No orb with the `seed` name exists in the project (issue #100, spec
  /// §3.3).
  static const String seedNotFound = 'seed_not_found';

  /// The seed orb's branch was never pushed, so there is no remote state to
  /// clone from — its state is the default branch anyway (issue #100, spec
  /// §3.3).
  static const String seedNotPushed = 'seed_not_pushed';

  /// A `seed` was given but the targeting resolves to an existing orb —
  /// the seed only parameterizes a new orb's clone (issue #100, spec §3.3).
  static const String seedConflict = 'seed_conflict';

  /// The target orb cannot run a command — its boot died at the shell probe
  /// (`broken:shell`, issue #149, spec §6.8). [message] is the boot's own
  /// reason. The caller says "spawned, works nowhere": the orb exists, but no
  /// code task can land on it.
  static const String noShell = 'no_shell';

  /// The refusal code (`no_remote`, `non_github_remote`,
  /// `missing_git_identity`, `not_wakeable`, `missing_checkout`,
  /// `not_running`, `not_updatable`, `update_busy`, `missing_workspace`,
  /// `seed_not_found`, `seed_not_pushed`, `seed_conflict`, `no_shell`).
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

/// One host provider credential for the post-boot credential sync (issue
/// #138, spec §6.7): the integration the orb's opencode stores its key
/// under, and the credential value as the host service's `GET
/// /api/credential` reports it (an opencode `Credential.Value` JSON object,
/// e.g. `{"type":"key","key":"…"}`). The secret crosses only from the
/// bridge to the orb's own server — never through the bridge's API surface
/// (ADR-0001).
class OrbCredential {
  const OrbCredential({
    required this.integrationId,
    required this.value,
    this.label,
  });

  /// The integration id (the credential's provider key).
  final String integrationId;

  /// The stored credential value, verbatim from the host service.
  final Map<String, Object?> value;

  /// The display label, when the host carries one.
  final String? label;
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
/// issue #97): [detail] is the CLI's error output — and for a failed
/// import, the staged export file's shape too (size and first/last bytes,
/// issue #137), since the CLI's bare schema errors describe only what the
/// file is not.
class OrbSessionMoveError implements Exception {
  const OrbSessionMoveError(this.session, this.detail);

  /// The session id the move failed on.
  final String session;

  /// The failure's detail: the CLI's error output (both channels for an
  /// import, the stderr for an export), with the staged file's shape
  /// appended when an import rejected it (issue #137).
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
    this.hostCredentials,
    this.bootTimeout = const Duration(minutes: 10),
    this.pollInterval = const Duration(milliseconds: 500),
  });

  /// The in-container port opencode serves on (spec §2.9): the single
  /// constant shared by the entrypoint and the `-p` mapping. The host port
  /// is ephemeral (`-p 127.0.0.1:0:<port>`); only this one is fixed.
  static const int inContainerPort = 4096;

  /// The staged gh config dir inside the orb, as the entrypoint sets it
  /// (`$STATE_DIR/gh`, the state mount being `/root/.local`; `ORB_STATE_DIR`
  /// is never passed by the bridge). `docker exec` does not inherit the
  /// entrypoint's export, so the in-container probe passes it explicitly
  /// (issue #145).
  static const String inContainerGhConfigDir = '/root/.local/gh';

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

  /// Reads the host's provider credentials for the post-boot credential sync
  /// (issue #138, spec §6.7): the host service's stored integration
  /// credentials, secret values included (`GET /api/credential` — the only
  /// supported read of the whole store). The default reads the shared-service
  /// descriptor (`~/.local/state/opencode/service.json`); a missing or
  /// unreadable descriptor yields the empty list — the orb then boots with
  /// whatever credentials its state dir already holds (tests inject a fake).
  final Future<List<OrbCredential>> Function()? hostCredentials;

  /// How long the boot wait runs before it fails the create.
  final Duration bootTimeout;

  /// The boot wait's poll pace.
  final Duration pollInterval;

  /// Create the orb [name] in [project] (the project's canonical checkout is
  /// [checkout]) and wait for its boot (spec §2.3). The password is derived
  /// and verified internally (ADR-0001: it is never exposed through the
  /// bridge); the returned record carries the ephemeral-URL descriptor.
  /// [base] (issue #100, spec §3.3) is the branch the clone starts from —
  /// the seed's branch, whose tip the entrypoint's first-start clone checks
  /// out (`ORB_BASE_BRANCH`) instead of the remote's default; the record
  /// carries it as the PR base of the orb's work.
  Future<OrbRecord> create({
    required String project,
    required String name,
    required String checkout,
    String? base,
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
      base,
    );
    await _createVolume(
      'orb-$id-data',
      id,
      name,
      project,
      branch,
      created,
      base,
    );
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
      if (base != null) ...['-e', 'ORB_BASE_BRANCH=$base'],
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
      if (base != null) ...['-l', 'ocb.base=$base'],
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
    // The container-local gh credentials (issue #120): the host's gh token
    // read bridge-side (the bridge reaches the keyring the read-only mount
    // cannot), staged on the state dir mount the entrypoint points gh at.
    // The boot below then proves them in-container (issue #145).
    await _stageGhConfig(id);

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
      // ... and the in-container gh check (issue #145, spec §4): a staged
      // file is not proof, the running orb's own gh is. It never fails the
      // boot — the orb is a working workspace — but a refusal leaves the
      // `gh-auth-failed` cause for the list and the boot report (the 401s
      // are then named at boot, not discovered mid-task).
      await verifyGhAuth(id, container);
      await _syncHostCredentials(id, url, password);
      return OrbRecord(
        id: id,
        name: name,
        project: project,
        branch: branch,
        state: 'running',
        created: created,
        url: url,
        base: base,
      );
    } finally {
      await logProcess.kill();
    }
  }

  /// Resolve the `seed` of a new orb's clone (issue #100, spec §3.3): the
  /// [project]'s orb named [seed] (a stopped one is fine — the seed reads
  /// the branch tip **from the remote**, never the parent's volume or
  /// working tree), verified pushed: a branch never pushed cannot be
  /// seeded (its state is the default branch anyway). Returns the seed's
  /// branch — the new orb's base — or `null` when no such orb exists in
  /// the project (the caller's message lists what does).
  /// [OrbRefusalError.seedNotPushed] when the branch is absent from the
  /// remote.
  Future<String?> seedBranch({
    required String project,
    required String seed,
    required String checkout,
  }) async {
    OrbRecord? seedOrb;
    for (final row in await list()) {
      if (row.project == project && row.state != 'orphan' && row.name == seed) {
        seedOrb = row;
        break;
      }
    }
    if (seedOrb == null) return null;
    // The remote probe doubles as the seed read: ls-remote asks the remote
    // directly, so a stopped parent still answers.
    await _remoteUrl(checkout);
    final probe = await git([
      'ls-remote',
      '--heads',
      'origin',
      seedOrb.branch,
    ], workingDirectory: checkout);
    if (probe.exitCode != 0 || probe.stdout.trim().isEmpty) {
      throw OrbRefusalError(
        OrbRefusalError.seedNotPushed,
        'the orb $seed has no pushed branch — its work is not on the '
        'remote, so there is nothing to seed from (spec §3.3)',
      );
    }
    return seedOrb.branch;
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

    // Re-check the broken containers against what the volumes say, and
    // compose the cleanup-pending badge the lifecycle pass marked (issue
    // #101, spec §2.10.2/§9.4): a stopped orb the pass surfaced is the same
    // container state carrying its reason.
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row.state != 'stopped') continue;
      final checked = _withBrokenState(row, volumeNames);
      if (checked.state != 'stopped') {
        rows[i] = checked;
        continue;
      }
      // The boot failed at the shell probe (issue #149, spec §6.8): the
      // container's volumes are all there, but its last boot died before
      // serving opencode — the agent cannot run a command. That is not a
      // clean `stopped` orb: it is never surfaced as ready for a code task.
      // The entrypoint leaves the reason as a `no-shell` marker on the state
      // mount (a cheap host-side read, never a container probe: the list is
      // the composite services' hot path, spec §2.2).
      final marker = _noShellMarker(row.id);
      if (marker != null) {
        rows[i] = _withBootReason(_replacedState(row, 'broken:shell'), marker);
        continue;
      }
      final reason = _cleanupReason(row.id);
      if (reason != null) {
        rows[i] = _replacedState(row, 'cleanup_pending:$reason');
      }
    }

    // The push-failure surfacing (issue #120): the orb's post-commit hook
    // writes a `push-failed` marker on the state mount when its push to
    // the remote fails; the row carries it (the return channel — seed,
    // the PR flow, the guard's pushed side — silently rides on that push,
    // spec §3, so a failed push must not leave the orb looking healthy).
    // A cheap host-side file read, never a container probe; the broken
    // rows' detail (the missing volume/dir) is the louder signal, and an
    // orphan's marker is stale by construction (no container to push).
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row.state == 'orphan' || row.state.startsWith('broken')) {
        continue;
      }
      if (File('${stateRoot.path}/${row.id}/push-failed').existsSync()) {
        rows[i] = _withPushFailing(row);
      }
    }

    // The gh-auth surfacing (issue #145): the bridge could not stage usable
    // gh credentials at the last create/wake/update, so the agent's gh is as
    // good as dead and every API call answers 401 mid-task. Same host-side
    // read as push-failed (#120) - never a container probe, the list is the
    // services' hot path (spec 2.2). The marker describes the start, not
    // the orb: `_stageGhConfig` clears it on the next passing stage.
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row.state == 'orphan' || row.state.startsWith('broken')) {
        continue;
      }
      final reason = _ghAuthFailedMarker(row.id);
      if (reason != null) rows[i] = _withGhAuthFailure(row, reason);
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
          base: labels['ocb.base'] as String?,
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
    base: record.base,
    pushFailing: record.pushFailing,
    ghAuthFailed: record.ghAuthFailed,
    bootReason: record.bootReason,
  );

  OrbRecord _withPushFailing(OrbRecord record) => OrbRecord(
    id: record.id,
    name: record.name,
    project: record.project,
    branch: record.branch,
    state: record.state,
    created: record.created,
    url: record.url,
    pr: record.pr,
    base: record.base,
    pushFailing: true,
    ghAuthFailed: record.ghAuthFailed,
    bootReason: record.bootReason,
  );

  /// [record] carrying its gh-auth failure cause (issue #145) - every other
  /// field a copy, like [_withPushFailing].
  OrbRecord _withGhAuthFailure(OrbRecord record, String reason) => OrbRecord(
    id: record.id,
    name: record.name,
    project: record.project,
    branch: record.branch,
    state: record.state,
    created: record.created,
    url: record.url,
    pr: record.pr,
    base: record.base,
    pushFailing: record.pushFailing,
    ghAuthFailed: reason,
    bootReason: record.bootReason,
  );

  /// The cause in orb [id]'s `gh-auth-failed` marker (issue #145), or `null`
  /// when the bridge has no such marker - the credentials staged fine, or
  /// the host has no gh. A host-side read only (like [_noShellMarker] and the
  /// push marker): cleared by the next passing stage.
  String? _ghAuthFailedMarker(String id) {
    final file = File('${stateRoot.path}/$id/gh-auth-failed');
    if (!file.existsSync()) return null;
    try {
      final reason = file.readAsStringSync().trim();
      return reason.isEmpty ? 'gh could not authenticate' : reason;
    } on FileSystemException {
      // Unreadable for a moment (a boot rewriting it): no verdict beats a
      // wrong one, and the next list reads it again.
      return null;
    }
  }

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

  /// The `cleanup-pending` marker of the per-orb state dir (issue #101,
  /// spec §2.10.2): written by the automated lifecycle pass when a stopped
  /// auto-delete candidate is guard-blocked, carrying the reason (`uncommitted
  /// work` / `unpushed work` / …) that the card surfaces as the
  /// "cleanup pending" state (spec §9.4). State, like the stop marker — the
  /// pass re-evaluates the guard on every pass and the wake clears the badge.
  File _cleanupMarker(String id) =>
      File('${stateRoot.path}/$id/cleanup-pending');

  /// Surfaces [id] as cleanup-pending with the guard's [reason] (the
  /// lifecycle pass only — the badge is the automated path's surfacing of a
  /// guard-blocked candidate, never a manual state).
  Future<void> _markCleanupPending(String id, String reason) async {
    final marker = _cleanupMarker(id);
    await marker.parent.create(recursive: true);
    await marker.writeAsString(reason);
  }

  Future<void> _removeCleanupMarker(String id) async {
    final marker = _cleanupMarker(id);
    if (marker.existsSync()) {
      await marker.delete();
    }
  }

  String? _cleanupReason(String id) {
    final marker = _cleanupMarker(id);
    if (!marker.existsSync()) return null;
    try {
      final reason = marker.readAsStringSync().trim();
      return reason.isEmpty ? null : reason;
    } on FileSystemException {
      return null;
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

  /// The CLI's full output (both channels) for a failure report (issue
  /// #137): [_cliDetail] alone hides the stdout half of a CLI that errors
  /// on both channels.
  String _cliOutput(OpencodeCliResult result) {
    final out = result.stdout.trim();
    final err = result.stderr.trim();
    if (out.isEmpty && err.isEmpty) return '(no output)';
    final parts = <String>[
      if (err.isNotEmpty) 'stderr: $err',
      if (out.isNotEmpty) 'stdout: $out',
    ];
    return parts.join('\n');
  }

  /// A bounded excerpt of [payload] for an error report (issue #137): the
  /// first and last bytes with the size between them — the shape that
  /// distinguishes an empty export from banner noise around the document.
  String _payloadExcerpt(String payload) {
    const edge = 192;
    if (payload.length <= edge * 2) {
      return '${payload.length} bytes: ${_flatText(payload)}';
    }
    final middle = payload.length - edge * 2;
    return '${payload.length} bytes: first [${_flatText(payload.substring(0, edge))}] '
        '… $middle elided … '
        'last [${_flatText(payload.substring(payload.length - edge))}]';
  }

  /// Escapes control characters so a payload excerpt reads on one line.
  static String _flatText(String s) =>
      s.replaceAll('\r', r'\r').replaceAll('\n', r'\n').replaceAll('\t', r'\t');

  /// The bare JSON documents the CLI's `session import` accepts: the
  /// export stdout reduced to every document it carries (issues #137,
  /// #144). The import schema parses its file argument as one JSON document,
  /// and every other shape (an empty file, banner or log lines around the
  /// document, ANSI codes, the document wrapped as one JSON string) aborts
  /// it with a bare `SchemaError: Expected a valid JSON string`. The CLI
  /// also emits a JSON array (the session document plus more elements):
  /// each object element is a document of its own, the single-element array
  /// unwrapping to the bare document. `null` when the payload carries no
  /// document: the caller reports the payload instead of staging a file the
  /// import can only reject.
  List<String>? _exportDocuments(String exportStdout) {
    final trimmed = exportStdout.trim();
    if (trimmed.isEmpty) return null;
    final whole = _documentsOf(_tryDecode(trimmed));
    if (whole != null) return whole;
    // Noise around the document (banner or log lines, ANSI included): the
    // widest outermost `{...}` slice, or `[...]` array, that parses as the
    // document or the array of them. A payload of several bare documents
    // never parses as one and stays refused: which document to move is not
    // the bridge's guess.
    for (final (open, close) in const [('{', '}'), ('[', ']')]) {
      final first = trimmed.indexOf(open);
      final last = trimmed.lastIndexOf(close);
      if (first == -1 || last <= first) continue;
      final sliced = _documentsOf(
        _tryDecode(trimmed.substring(first, last + 1)),
      );
      if (sliced != null) return sliced;
    }
    return null;
  }

  /// [decoded], a parsed export payload, reduced to the bare document texts
  /// it carries (issue #144): a JSON object is one document; a JSON array is
  /// one document per object element, its nested arrays and wrapped strings
  /// flattened (so a nested array and a wrapped element stage their
  /// documents too); a JSON string is the wrapped text of either. `null` for
  /// anything else: no document to move.
  List<String>? _documentsOf(Object? decoded) {
    if (decoded is Map) return [jsonEncode(decoded)];
    if (decoded is String) {
      final inner = decoded;
      if (inner.trim().isEmpty) return null;
      final parsed = _tryDecode(inner);
      if (parsed is Map) return [inner];
      if (parsed is List) return _documentsOf(parsed);
      return null;
    }

    if (decoded is! List) return null;
    final documents = <String>[];
    for (final element in decoded) {
      if (element is Map) {
        documents.add(jsonEncode(element));
        continue;
      }
      final nested = _documentsOf(element);
      if (nested != null) documents.addAll(nested);
    }
    return documents.isEmpty ? null : documents;
  }

  /// [text] parsed as JSON, or `null` when it does not parse.
  Object? _tryDecode(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  /// The session id the export [document] names (`info.id`), or `null` when
  /// it names none (issue #144): an extra document of an array payload is
  /// staged and ordered by the id it names.
  String? _exportDocumentId(String document) {
    final decoded = _tryDecode(document);
    if (decoded is! Map) return null;
    final info = decoded['info'];
    if (info is! Map) return null;
    final id = info['id'];
    return id is String && id.isNotEmpty ? id : null;
  }

  /// The staged export file's shape for a failed import (issue #137): the
  /// size and the first and last bytes, read from the file the import
  /// actually parsed (a large export never reaches the error whole).
  String _stagedFileSummary(File file) {
    try {
      final length = file.lengthSync();
      const edge = 192;
      final random = file.openSync();
      try {
        if (length <= edge * 2) {
          final all = utf8.decode(
            random.readSync(length),
            allowMalformed: true,
          );
          return 'staged file ${file.path}: ${_payloadExcerpt(all)}';
        }
        final head = utf8.decode(random.readSync(edge), allowMalformed: true);
        random.setPositionSync(length - edge);
        final tail = utf8.decode(random.readSync(edge), allowMalformed: true);
        return 'staged file ${file.path}: $length bytes: '
            'first [${_flatText(head)}] '
            '… ${length - edge * 2} elided … '
            'last [${_flatText(tail)}]';
      } finally {
        random.closeSync();
      }
    } on FileSystemException {
      return 'staged file ${file.path} is no longer readable';
    }
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
  /// now) into a bare JSON document the host CLI's import accepts (issue
  /// #137), imports each into the host checkout parent-first (idempotent —
  /// a 409 is the session already there), deletes them from the orb
  /// child-first once every import has landed, then `docker stop`s the
  /// container last and sets the `ocb.stopped` marker (the wake's gate). A
  /// re-issue while stopped is a safe no-op.
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
    final order = <String>[for (final session in all) session.id];
    try {
      for (final session in all) {
        final file = File(
          '${Directory.systemTemp.path}/ocb-stop-$id-${session.id}.json',
        );
        final extras = <String>[];
        try {
          extras.addAll(
            await _exportStaged(
              cli,
              file,
              session.id,
              source: service,
              server: url,
              password: password,
            ),
          );
          files[session.id] = file;
          for (var i = 0; i < extras.length; i++) {
            final documentId =
                _exportDocumentId(extras[i]) ?? '${session.id}-document-$i';
            if (files.containsKey(documentId)) continue;
            final documentFile = File(
              '${Directory.systemTemp.path}/'
              'ocb-stop-$id-$documentId-$i.json',
            );
            await documentFile.writeAsString(extras[i]);
            files[documentId] = documentFile;
            order.add(documentId);
          }
        } catch (_) {
          for (final staged in files.values) {
            if (staged.existsSync()) await staged.delete();
          }
          rethrow;
        }
      }
      // Phase 2: import every session into the host checkout (a 409 is the
      // session already there — a re-run), parent-first (issue #137): the
      // CLI rejects a child session whose parent is not yet on the target,
      // and the service list is newest-first — exactly backwards.
      final ordered = _parentsFirst(order, files);
      for (final id in ordered) {
        await _importStaged(
          cli,
          files[id]!,
          id,
          targetArgs: ['--directory', checkoutPath],
        );
      }
      // Phase 3: delete from the orb only once every import has landed —
      // child-first, the reverse of the import order (issue #137): the
      // orb-side delete of a parent cascades to its children, so deleting
      // a parent mid-list could strand a not-yet-imported child with only
      // its temp file left. A session already gone (404 — a cascade from
      // an earlier run, a startup reconciliation) is the move's end state.
      for (final id in ordered.reversed) {
        await _deleteMoved(
          service,
          id,
          'the session import succeeded but the deletion from the orb '
          'failed',
        );
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

  /// The export of [session] staged into [file] for a later `session
  /// import` (issue #137): the CLI's stdout reduced to the bare JSON
  /// documents the import schema parses (banner noise stripped, a wrapped
  /// payload unwrapped, a JSON array split per element of which the first
  /// is [file] — issues #137, #144). The further documents are returned.
  ///
  /// When the CLI's stdout carries no document at all, the export is
  /// recovered through [source]'s HTTP `exportSession` (issue #173): an
  /// old host CLI (v2.1.4) loses data in its own stdout write once the
  /// document exceeds a pipe buffer — it exits 0 with a stream cut
  /// mid-document — while the service's HTTP answer of the same document
  /// is never capped. An export neither path can read fails here, with
  /// the payload excerpt in the error — an empty or noisy staged file
  /// would only reach the import as a bare `SchemaError`.
  Future<List<String>> _exportStaged(
    OpencodeCliRunner cli,
    File file,
    String session, {
    required OpencodeService source,
    String? server,
    String? password,
  }) async {
    final export = await cli([
      'session',
      'export',
      session,
      ..._serverArgs(server),
    ], env: _passwordEnv(password));
    if (export.exitCode != 0) {
      throw OrbSessionMoveError(session, _cliDetail(export));
    }
    var documents = _exportDocuments(export.stdout);
    Object? httpFailure;
    if (documents == null) {
      try {
        documents = _exportDocuments(await source.exportSession(session));
        if (documents == null) {
          httpFailure = 'answered without a readable document';
        }
      } catch (error) {
        httpFailure = '$error';
      }
    }
    if (documents == null) {
      throw OrbSessionMoveError(
        session,
        'the session export exited 0 without a bare JSON document the '
        'import can read${_truncationNote(export.stdout)}; the service '
        'HTTP export could not recover it ($httpFailure) — '
        '${_payloadExcerpt(export.stdout)}\n'
        '${_cliOutput(export)}',
      );
    }
    await file.writeAsString(documents.first);
    return documents.sublist(1);
  }

  /// The error note naming the issue #173 shape: a payload that starts a
  /// JSON document (`{` or `[`) and closes it nowhere — the CLI's stdout
  /// cut mid-document, not noise around a document the slicer would have
  /// found.
  String _truncationNote(String payload) {
    final trimmed = payload.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.startsWith('{') || trimmed.startsWith('[')
        ? ' — the export stream looks truncated: it starts a JSON '
              'document that never closes (a CLI stdout write cut '
              'mid-document, issue #173)'
        : '';
  }

  /// The staged [file] imported on the target CLI (issue #97: a 409 is the
  /// session already there — a move re-run). A failed import reports the
  /// staged file the CLI actually parsed (size, first and last bytes) next
  /// to the CLI's own output, not the bare `SchemaError` (issue #137).
  Future<void> _importStaged(
    OpencodeCliRunner cli,
    File file,
    String session, {
    required List<String> targetArgs,
    String? server,
    String? password,
  }) async {
    final import = await cli([
      'session',
      'import',
      file.path,
      ...targetArgs,
      ..._serverArgs(server),
    ], env: _passwordEnv(password));
    if (import.exitCode != 0 && !_isImport409(import)) {
      throw OrbSessionMoveError(
        session,
        '${_cliOutput(import)}\n${_stagedFileSummary(file)}',
      );
    }
  }

  /// The source-side delete after a successful import: the moved session is
  /// removed from [source]. A 404 is tolerated — the session is already
  /// gone there (the parent's delete cascades to children on the orb, or a
  /// startup reconciliation removed it first; issue #137): the move's end
  /// state either way.
  Future<void> _deleteMoved(
    OpencodeService source,
    String session,
    String failure,
  ) async {
    try {
      await source.deleteSession(session);
    } on OpencodeServiceError catch (error) {
      if (error.statusCode != HttpStatus.notFound) {
        throw OrbSessionMoveError(session, '$failure: $error');
      }
    } catch (error) {
      throw OrbSessionMoveError(session, '$failure: $error');
    }
  }

  /// Every staged id in parent-first import order (issue #137): a child
  /// session's export document names its parent (`info.parentID`), and the
  /// CLI's import rejects a child whose parent is not yet on the target —
  /// while the service's session list is newest-first. All parents import
  /// before all children, in the service's own order; a cycle (impossible in
  /// the service's tree, cheap to defend) keeps the remaining order. Issue
  /// #144: the ids are read from every staged file, so round-robin or grand-
  /// child lists order correctly; a document naming no id is imported last.
  List<String> _parentsFirst(List<String> all, Map<String, File> files) {
    final parents = <String, String?>{};
    for (final entry in files.entries) {
      String? parent;
      try {
        final info =
            (jsonDecode(entry.value.readAsStringSync()) as Map)['info'];
        if (info is Map) parent = info['parentID'] as String?;
      } on Object {
        // Unreadable (it was staged from a parsed document, so this is not
        // expected): no ordering constraint on it.
      }
      parents[entry.key] = parent;
    }
    final ids = all.toSet();
    final ordered = <String>[];
    final done = <String>{};
    while (done.length < all.length) {
      final ready =
          [
            for (final id in all)
              if (!done.contains(id)) id,
          ].where((id) {
            final parent = parents[id];
            return parent == null ||
                !ids.contains(parent) ||
                done.contains(parent);
          }).toList();
      if (ready.isEmpty) {
        for (final id in all) {
          if (!done.contains(id)) {
            ordered.add(id);
            done.add(id);
          }
        }
        break;
      }
      for (final id in ready) {
        ordered.add(id);
        done.add(id);
      }
    }
    return ordered;
  }

  /// The startup auto-wake (issue #102, spec §2.11): the bridge owns every
  /// start — no Docker restart policy. After the label-composed enumeration
  /// ([list]), every stopped orb without the `ocb.stopped` marker was
  /// running at crash/reboot time and is auto-woken through the full start
  /// path ([wake]); a marked orb had its move-to-host complete and stays
  /// stopped. The in-orb sessions of an auto-woken orb stay in the orb
  /// (re-attached by the composite services) — no move at recovery.
  /// Then the startup reconciliation ([_reconcileSessions]).
  Future<void> recover() async {
    for (final record in await list()) {
      if (record.state != 'stopped') continue;
      if (isStopped(record.id)) continue;
      try {
        await wake(record.id);
      } catch (_) {
        // Boot failure of an auto-wake = the existing boot-failure state
        // (spec §2.11): the orb stays as it is (unmarked — the next
        // startup re-tries) and the rest of the fleet recovers.
      }
    }
    await _reconcileSessions();
  }

  /// The startup reconciliation (issue #102, spec §2.11): for every session
  /// id present on **both** the host and a running orb, the in-orb copy is
  /// deleted (the host is canonical — the import is 409-idempotent, so the
  /// surviving copy is always the host's). This completes a stop the crash
  /// interrupted between the import and the orb-side delete (every session
  /// ends up exactly once, no direction recorded) and reverts a host→orb
  /// move the crash interrupted after the import (the session stays on the
  /// host; the user re-issues the move). A host or per-orb read failure
  /// skips it — never a silent delete on uncertain ground.
  Future<void> _reconcileSessions() async {
    final host = hostSessions;
    if (host == null) return;
    List<OpencodeSession> hostRows;
    try {
      hostRows = await host.listSessions();
    } catch (_) {
      return; // The host is unreachable: nothing is reconciled this pass.
    }
    final hostIds = {for (final session in hostRows) session.id};
    if (hostIds.isEmpty) return;
    for (final record in await list()) {
      final url = record.url;
      if (record.state != 'running' || url == null) continue;
      final password = await lastPassword(record.id);
      if (password == null) continue; // Still booting: nothing to reconcile.
      final service = _orbService(url, password);
      try {
        final orbSessions = await service.listSessions();
        for (final session in orbSessions) {
          if (!hostIds.contains(session.id)) continue;
          await service.deleteSession(session.id);
        }
      } catch (_) {
        // A degraded orb is skipped for this pass; the next bridge
        // startup re-tries.
      }
    }
  }

  /// The broken orb's start-with-fresh-state (issue #102, spec §9.4): a
  /// normal [wake] over a recreated state dir — a fresh `opencode.db` —
  /// which keeps the workspace volume (uncommitted work included) and
  /// loses the in-orb sessions (the app's confirmation states it). Only a
  /// `broken:state` orb (workspace present, state dir missing) is
  /// wakeable this way; anything else refuses — never a silent repair.
  Future<OrbRecord> startWithFreshState(String id) async {
    final record = await _record(id);
    if (record == null) throw OrbNotFoundError(id);
    if (record.state != 'broken:state') {
      throw const OrbRefusalError(
        OrbRefusalError.notWakeable,
        'only a broken orb whose state dir is missing can start with fresh '
        'state',
      );
    }
    // The fresh state dir: what `_withBrokenState` found missing; the wake
    // then runs its full start path over it (and `_stageConfig` finds the
    // per-orb dir it needs).
    Directory('${stateRoot.path}/$id').createSync(recursive: true);
    return wake(id);
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
    if (!record.isStoppedLike) {
      throw const OrbRefusalError(
        OrbRefusalError.notWakeable,
        'only a stopped orb can be woken',
      );
    }
    // The wake resets the idle clock (issue #101, spec §2.10.1): a freshly
    // woken orb starts its idle window from now — the pre-stop clock no
    // longer describes its idleness.
    _idleSince.remove(id);
    final container = 'orb-$id';
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
    // The gh credentials re-stage (issue #120): the current host token
    // (it rotates), and a stale push marker from before the stop is not
    // carried into the new boot when the credentials were refreshed.
    await _stageGhConfig(id);
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
      // ... and the in-container gh check (issue #145, spec §4): a staged
      // file is not proof, the running orb's own gh is. It never fails the
      // wake — the orb is a working workspace — but a refusal leaves the
      // `gh-auth-failed` cause for the list and the boot report.
      await verifyGhAuth(id, container);
      await _syncHostCredentials(id, url, password);
      await _removeStoppedMarker(id);
      await _removeCleanupMarker(id);
      return OrbRecord(
        id: id,
        name: record.name,
        project: record.project,
        branch: record.branch,
        state: 'running',
        created: record.created,
        url: url,
        base: record.base,
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
      await _exportStaged(
        cli,
        file,
        session,
        source: source.service,
        server: source.server,
        password: source.password,
      );
      await _importStaged(
        cli,
        file,
        session,
        targetArgs: ['--directory', directory],
        server: target.server,
        password: target.password,
      );
      await _deleteMoved(
        source.service,
        session,
        'the session import succeeded but the deletion from the source '
        'failed',
      );
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
    } else if (orb.isStoppedLike) {
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
  /// The bridge applies the current/default model (including its thinking
  /// level / variant) so the new session shows its model like one created
  /// directly in opencode. The agent is not passed — the orb service picks
  /// its default (a fresh session starts on the default agent, not the
  /// previous session's, which may be a restricted subagent). The returned
  /// row is the home-list row as the orb service reports it — its `orb` is
  /// the orb id. A stopped orb refuses with
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
    final model = await _defaultModel(service);
    final session = await service.createSessionInDirectory(
      '/workspace',
      model: model,
    );
    await _applyDefaultModel(service, session.id, model);
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

  /// The model (with its thinking level / variant) to apply to a new orb
  /// session: copied from the orb's most recent session that has a model,
  /// which mirrors opencode's "current model" behavior. The agent is
  /// deliberately not carried over — it is a per-session explicit choice,
  /// and inheriting the previous session's (which may be a restricted
  /// subagent) is exactly what a fresh session in opencode does not do;
  /// the orb service picks its default agent. Best-effort.
  Future<ModelRef?> _defaultModel(OpencodeService service) async {
    try {
      final sessions = await service.listSessions();
      sessions.sort((a, b) => b.created.compareTo(a.created));
      for (final candidate in sessions.take(8)) {
        try {
          final detail = await service.getDetail(candidate.id);
          if (detail.model != null) {
            return detail.model;
          }
        } catch (_) {
          // Try the next candidate.
        }
      }
    } catch (_) {
      // No default available.
    }
    return null;
  }

  Future<void> _applyDefaultModel(
    OpencodeService service,
    String id,
    ModelRef? model,
  ) async {
    if (model == null) return;
    try {
      await service.setModel(id, model);
    } catch (_) {
      // Best-effort.
    }
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
      // The running container is probed in place.
      return _guardProbe(['exec', container, 'git', '-C', '/workspace']);
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
    return _guardProbe([
      'run',
      '--rm',
      '--entrypoint',
      'git',
      '-v',
      'orb-$id-workspace:/ws',
      image,
      '-C',
      '/ws',
    ]);
  }

  /// The guard's git probe under [git] (the docker argv prefix that runs
  /// git in the orb's clone, spec §2.7): the dirty tree and the unpushed
  /// count; any git failure is unevaluable. When the count is not zero the
  /// probe fetches `origin` once and re-counts (issue #137): a branch the
  /// host pushed leaves the orb's clone without a
  /// `refs/remotes/origin/<branch>`, and `rev-list --not --remotes` then
  /// counts those pushed commits as unpushed — a false refusal. A failed
  /// fetch (no network, no credentials in the throwaway container) keeps
  /// the first count: the guard fails closed, never delete the unverifiable.
  Future<OrbDeletionGuard> _guardProbe(List<String> git) async {
    final status = await run([...git, 'status', '--porcelain']);
    if (status.exitCode != 0) {
      return const OrbDeletionGuard(evaluable: false);
    }
    Future<int?> count() async {
      final out = await run([
        ...git,
        'rev-list',
        '--count',
        'HEAD',
        '--not',
        '--remotes',
      ]);
      if (out.exitCode != 0) return null;
      return int.tryParse(out.stdout.trim());
    }

    var unpushed = await count();
    if (unpushed == null) {
      return const OrbDeletionGuard(evaluable: false);
    }
    if (unpushed > 0) {
      final fetched = await run([...git, 'fetch', 'origin']);
      if (fetched.exitCode == 0) {
        // After a successful fetch the re-count is authoritative — an
        // unreadable one leaves the state unverifiable.
        final recounted = await count();
        if (recounted == null) {
          return const OrbDeletionGuard(evaluable: false);
        }
        unpushed = recounted;
      }
    }
    return OrbDeletionGuard(
      evaluable: true,
      dirty: _lines(status.stdout),
      unpushedCount: unpushed,
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
    if (!running && !record.isStoppedLike) {
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
      if (record.base != null) ...['-l', 'ocb.base=${record.base}'],
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
    // The gh credentials re-stage (issue #120, wake-style).
    await _stageGhConfig(id);
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
      // ... and the in-container gh check (issue #145, spec §4): a staged
      // file is not proof, the running orb's own gh is. It never fails the
      // boot — the orb is a working workspace — but a refusal leaves the
      // `gh-auth-failed` cause for the list and the boot report.
      await verifyGhAuth(id, container);
      await _syncHostCredentials(id, url, password);
      return OrbRecord(
        id: id,
        name: record.name,
        project: record.project,
        branch: record.branch,
        state: 'running',
        created: record.created,
        url: url,
        base: record.base,
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

  // ------------------------------------------------------------------------
  // The automated lifecycle pass (issue #101, spec §2.10): the single actor
  // of orb automation — 60-min idle auto-stop through the shared stop path,
  // the 24-h stopped-TTL auto-delete with the guard re-evaluated every pass
  // (never forced), the merged-PR bypass of the TTL, the "cleanup pending"
  // surfacing of guard-blocked candidates, and the mid-run gh re-stage on
  // `push-failed` (issue #167, spec §4).

  /// The idle threshold before the pass auto-stops an orb (spec §2.10.1):
  /// no busy session for this long. A fixed constant, no knob (a future
  /// knob = config field + UI, zero logic change, §2.10.5).
  static const Duration idleStopAfter = Duration(minutes: 60);

  /// How long an orb stays stopped before it becomes an auto-delete
  /// candidate (spec §2.10.2), clocked from the container's last exit. A
  /// merged PR bypasses it (§2.10.3). A fixed constant, no knob.
  static const Duration stoppedAutoDeleteAfter = Duration(hours: 24);

  /// The pass's pace (spec §2.10): ~1 minute over all orbs.
  static const Duration lifecyclePassInterval = Duration(minutes: 1);

  /// The mid-run gh re-stage's backoff (issue #167, spec §4): while the
  /// `push-failed` marker persists for one generation, the re-stage +
  /// in-container re-probe runs at most once per this window — a
  /// permanently broken host token must not hammer a `docker exec` probe
  /// every pass. A fixed constant, no knob. A fresh marker generation
  /// re-attempts promptly (the gate is per generation, not a global pace).
  static const Duration ghRestageBackoff = Duration(minutes: 5);

  /// The idle clocks (bridge memory only, spec §2.10): orb id → the instant
  /// the pass first saw it idle after its last busy observation. A busy orb
  /// has no entry (the clock resets); a bridge restart resets them all —
  /// harmless, the stop is lossless.
  final Map<String, DateTime> _idleSince = {};

  /// The gh re-stage gates (bridge memory only, issue #167, spec §4): orb
  /// id → (the `push-failed` marker's mtime at the last attempt, the
  /// attempt's wall clock). The mtime is the marker's generation: the hook
  /// rewrites the file on every failed push, so a fresh failure after a
  /// clearing moves the generation and re-attempts promptly, while a
  /// persisting marker stays within the backoff. A bridge restart resets
  /// the gates — at most one redundant probe (like the idle clocks).
  final Map<String, (DateTime, DateTime)> _ghRestage = {};

  Timer? _lifecycleTimer;
  bool _lifecycleRunning = false;

  /// The single per-orb exemption point (spec §2.10.5): "is this orb exempt
  /// from auto-cleanup?" — always no today. A future pin answers yes (stored
  /// as a Docker label); the pass consults nothing else.
  bool _isExemptFromAutoCleanup(String id) => false;

  /// Starts the periodic lifecycle pass (spec §2.10): [interval] overrides
  /// the ~1-min pace (tests). A re-issue replaces the running pass.
  void startLifecyclePass({Duration? interval}) {
    _lifecycleTimer?.cancel();
    _lifecycleTimer = Timer.periodic(
      interval ?? lifecyclePassInterval,
      (_) => unawaited(runLifecyclePass()),
    );
  }

  /// Stops the periodic pass (the bridge's shutdown); the pass can still be
  /// driven manually through [runLifecyclePass].
  void stopLifecyclePass() {
    _lifecycleTimer?.cancel();
    _lifecycleTimer = null;
  }

  /// Whether the periodic pass is armed (tests).
  bool get lifecyclePassRunning => _lifecycleTimer != null;

  /// One lifecycle pass over all orbs (spec §2.10) — the single actor:
  ///
  /// 1. a **running** orb with no busy session (active session or pending
  ///    permission) for [idleStopAfter] is auto-stopped through exactly the
  ///    shared [stop] path (all sessions, in-flight included, move to the
  ///    host; unguarded by construction);
  /// 2. a **stopped** orb is an auto-delete candidate once the container's
  ///    last exit is older than [stoppedAutoDeleteAfter] — or immediately,
  ///    on the pass following its stop, when its PR is merged (§2.10.3); the
  ///    deletion [deleteGuard] is re-evaluated on every pass and the
  ///    candidate is deleted **without force** when it passes, kept and
  ///    surfaced as cleanup-pending with the guard's reason when it blocks;
  /// 3. orphans, broken orbs, and preparing orbs are left alone (no
  ///    auto-reaping, no auto-force — §2.10.4); [delete]'s guard is the
  ///    leak backstop: a leaked orphan's gone-from-the-remote commits read
  ///    as unpushed and keep it alive behind the badge;
  /// 4. a **running** orb whose `push-failed` marker is set gets a
  ///    best-effort mid-run gh re-stage + in-container re-probe
  ///    ([_lifecycleGhRestage], issue #167, spec §4) — the list itself stays
  ///    probe-free, this pass is where the container probe lives.
  ///
  /// Every per-orb failure is swallowed (the next pass retries): one orb's
  /// docker hiccup never cancels the pass, and the pass never throws.
  /// [now] is the wall clock the idle and TTL comparisons run against
  /// (tests inject a scripted one; production uses `DateTime.now()`).
  Future<void> runLifecyclePass({DateTime? now}) async {
    if (_lifecycleRunning) return;
    _lifecycleRunning = true;
    try {
      final clock = now ?? DateTime.now();
      final List<OrbRecord> records;
      try {
        records = await list();
      } catch (_) {
        return; // docker unreachable: no automation this pass.
      }
      final live = <String>{};
      for (final record in records) {
        live.add(record.id);
        if (_isExemptFromAutoCleanup(record.id)) {
          _idleSince.remove(record.id);
          continue;
        }
        try {
          await _lifecycleOrb(record, clock);
        } catch (_) {
          // A per-orb failure (docker hiccup, a failed move, a failed
          // deletion): kept for the next pass — the pass never throws and
          // one orb never blocks the others.
        }
      }
      // Idle clocks and gh re-stage gates of orbs that are gone (deleted).
      _idleSince.removeWhere((id, _) => !live.contains(id));
      _ghRestage.removeWhere((id, _) => !live.contains(id));
    } finally {
      _lifecycleRunning = false;
    }
  }

  /// The pass's per-orb step (see [runLifecyclePass]).
  Future<void> _lifecycleOrb(OrbRecord record, DateTime now) async {
    switch (record.state) {
      case 'running':
        var autoStopped = false;
        final busy = await _orbIsBusy(record);
        if (busy == null || busy) {
          // Busy — or its busy state could not be read (degraded service,
          // unreadable password): never stop an orb you cannot prove idle.
          _idleSince.remove(record.id);
        } else {
          final idle = _idleSince.putIfAbsent(record.id, () => now);
          if (now.difference(idle) >= idleStopAfter) {
            // Auto-stop is exactly the shared stop path (§2.10.1). A failed
            // stop leaves the clock set: the next pass retries.
            await stop(record.id);
            _idleSince.remove(record.id);
            autoStopped = true;
          }
        }
        if (!autoStopped) {
          // The mid-run gh re-stage (issue #167, spec §4): only a
          // still-running orb — an orb this pass is stopping gets its
          // re-stage + re-probe on the wake's shared start path instead.
          await _lifecycleGhRestage(record, now);
        }
        return;
      case 'stopped':
        await _lifecycleStopped(record, now);
        return;
      default:
        // cleanup_pending:<reason> is the same container stopped with the
        // pass's own badge (the list already composed it): re-run the
        // candidate rule. Anything else (preparing, broken:*, orphan) is
        // left alone.
        if (record.isStoppedLike) {
          await _lifecycleStopped(record, now);
        }
    }
  }

  /// The mid-run gh re-stage (issue #167, spec §4): a running orb whose
  /// post-commit push is failing (§3.1) may be pushing with a gh token that
  /// died after staging — revoked, rotated, or an app-OAuth expiry; the boot
  /// validation ran once, at the start (#166). The staged file lives on the
  /// state-dir mount, which is the running container's own `GH_CONFIG_DIR`
  /// (`/root/.local/gh`, §4), so re-writing it updates the running orb's gh
  /// with no `docker cp` and no restart — gh re-reads `hosts.yml` on every
  /// call. Hence: re-stage the host's current token (fixes "the token
  /// rotated, the host has the new one"; a passing stage clears
  /// `push-failed`), then re-run the authoritative in-container probe —
  /// the host's token may be dead too (a full revocation, a logged-out
  /// host), in which case the probe (or the stage's own refusal) writes the
  /// `gh-auth-failed` cause and the card shows the real reason — no wake.
  ///
  /// Runs only here, never in [list] (the hot path stays probe-free,
  /// §2.2/§2.9). Gated per marker generation (the marker's mtime): while
  /// the marker persists, at most one re-stage + probe per
  /// [ghRestageBackoff]; a fresh failure after a clearing re-attempts
  /// promptly. The marker re-read is host-side (the file the hook writes);
  /// every failure swallows to the next pass, like the rest of the per-orb
  /// step (the pass never throws).
  Future<void> _lifecycleGhRestage(OrbRecord record, DateTime now) async {
    final marker = File('${stateRoot.path}/${record.id}/push-failed');
    if (!marker.existsSync()) {
      // No failed push: the boot-time staging stands (or the hook's last
      // push cleared the marker — a new failure is a new generation).
      _ghRestage.remove(record.id);
      return;
    }
    final generation = marker.lastModifiedSync();
    final gate = _ghRestage[record.id];
    if (gate != null &&
        gate.$1 == generation &&
        now.difference(gate.$2) < ghRestageBackoff) {
      return; // The same generation, still inside the backoff.
    }
    _ghRestage[record.id] = (generation, now);
    // Best effort, in this order: the re-stage (a passing one clears
    // `push-failed` and `gh-auth-failed`), then the probe — which
    // early-returns when nothing is staged, so a dead host token costs
    // exactly the host-side stage, no container probe.
    await _stageGhConfig(record.id);
    await verifyGhAuth(record.id, 'orb-${record.id}');
  }

  /// The stopped-orb candidate rule: merged-PR bypass first (a merged orb
  /// dies without waiting the TTL — the pass following its stop deletes it),
  /// then the 24-h clock from the container's last exit. A candidate whose
  /// guard passes is deleted without force; a guard-blocked candidate is
  /// kept and surfaced as cleanup-pending with the reason; a kept candidate
  /// whose guard passes again later (the work got pushed) drops the badge.
  Future<void> _lifecycleStopped(OrbRecord record, DateTime now) async {
    _idleSince.remove(record.id);
    final merged = await _prIsMerged(record);
    if (!merged) {
      final exit = await _lastExit(record.id);
      if (exit == null || now.difference(exit) < stoppedAutoDeleteAfter) {
        // Not yet a candidate: no badge before candidacy (§9.4 — the badge
        // marks guard-blocked *candidates*).
        await _removeCleanupMarker(record.id);
        return;
      }
    }
    try {
      // Never force — the automated path (§2.10.2): [delete] re-evaluates
      // the deletion guard on this very pass and a blocked candidate is
      // kept.
      await delete(record.id);
    } on OrbDeletionRefusedError catch (e) {
      await _markCleanupPending(record.id, _autoCleanupReason(e.guard));
    }
  }

  /// Whether the orb's service is busy, or `null` when it cannot be read
  /// (a degraded orb, an unreadable password, a service error): the caller
  /// treats both as "keep the orb alive" — the pass never stops an orb it
  /// cannot prove idle.
  Future<bool?> _orbIsBusy(OrbRecord record) async {
    try {
      final password = await lastPassword(record.id);
      if (password == null) return null;
      final url = await _orbUrl(record.id, record);
      return await _hasBusySessions(_orbService(url, password));
    } catch (_) {
      return null;
    }
  }

  /// Whether the orb's branch PR reports `merged` (the TTL bypass,
  /// §2.10.3). Any absence — no `gh`, no repo, no PR, a failed call — is
  /// false (the TTL applies). A merged PR never stops a live orb here: this
  /// is consulted only for an orb that is already stopped.
  Future<bool> _prIsMerged(OrbRecord record) async =>
      (await _prFor(record))?.state == 'merged';

  /// The container's last exit (the stopped clock, spec §2.10: read from
  /// `docker inspect` — no new state), or `null` when it cannot be read or
  /// the container has never exited (`0001-01-01T00:00:00Z`). A `null`
  /// leaves the orb out of the TTL rule until the clock is readable.
  Future<DateTime?> _lastExit(String id) async {
    final result = await run([
      'inspect',
      '--format',
      '{{.State.FinishedAt}}',
      'orb-$id',
    ]);
    if (result.exitCode != 0) return null;
    final exit = DateTime.tryParse(result.stdout.trim());
    // Docker's never-exited zero value (`0001-01-01T00:00:00Z`): no clock.
    if (exit == null || exit.year <= 1) return null;
    return exit;
  }

  /// The cleanup-pending badge's reason from the guard's evaluation (spec
  /// §2.10.2: "uncommitted / unpushed work"; an unreadable workspace names
  /// itself — the leaked-variant backstop, §2.10.4).
  static String _autoCleanupReason(OrbDeletionGuard guard) {
    if (!guard.evaluable) return 'workspace unreadable';
    final parts = [
      if (guard.dirty.isNotEmpty) 'uncommitted work',
      if (guard.unpushedCount > 0) 'unpushed work',
    ];
    return parts.isEmpty ? 'work needs protecting' : parts.join(' and ');
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

  /// The reason a boot died at the entrypoint's shell probe (issue #149,
  /// spec §6.8): the `[orb] FATAL: no usable shell …` line and the `[orb]
  /// shell: …` detail lines right after it, joined — `null` when [log] holds
  /// no such failure (a healthy boot, or a boot that failed elsewhere).
  ///
  /// The log is the ground truth, not an assumption: a boot that reached
  /// `[orb] stage: ready` has its shell, whatever else the log says.
  static String? noShellReason(String log) {
    final lines = const LineSplitter().convert(log);
    var ready = false;
    for (final line in lines) {
      if (line.startsWith('[orb] stage: ready')) ready = true;
    }
    if (ready) return null;
    final reason = <String>[];
    for (final line in lines) {
      if (!line.startsWith('[orb] ')) {
        // The FATAL and its details are one contiguous block (a log line
        // each); any foreign line ends it.
        if (reason.isNotEmpty) break;
        continue;
      }
      final body = line.substring('[orb] '.length).trim();
      if (body.startsWith('FATAL: no usable shell')) {
        reason.add(body);
      } else if (body.startsWith('shell:') && reason.isNotEmpty) {
        reason.add(body);
      } else if (reason.isNotEmpty) {
        break;
      }
    }
    return reason.isEmpty ? null : reason.join(' — ');
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
    String created, [
    String? base,
  ]) async {
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
      if (base != null) ...['--label', 'ocb.base=$base'],
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
    _rewriteLoopbackUrls(staged);
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

  /// Rewrites host-loopback URLs to `host.docker.internal` in the staged
  /// config (#117): a provider `baseURL` (or MCP server URL) pointing at
  /// `localhost` / `127.0.0.1` / `0.0.0.0` addresses the container itself
  /// inside an orb — nothing listens there, so the provider is dead. The
  /// containers already carry `--add-host=host.docker.internal:<host IP>`
  /// (§8.5), so swapping the host part — port and path kept — makes the
  /// host service reachable. Textual like [_injectBridgeUrl] (the config is
  /// JSONC — `//` comments make parsing unsafe); remote URLs and the rest of
  /// the config pass through untouched, and the host config file is never
  /// modified (host-authoritative, §6.2).
  void _rewriteLoopbackUrls(Directory staged) {
    for (final name in const ['opencode.jsonc', 'opencode.json']) {
      final file = File('${staged.path}/$name');
      if (!file.existsSync()) continue;
      final text = file.readAsStringSync();
      final updated = rewriteLoopbackUrls(text);
      if (updated != text) file.writeAsStringSync(updated);
    }
  }

  /// The textual rewrite behind [_rewriteLoopbackUrls]: every
  /// `http(s)://<loopback>` URL becomes `http(s)://host.docker.internal`,
  /// port and path kept. Exposed for tests.
  static String rewriteLoopbackUrls(String text) => text.replaceAllMapped(
    RegExp(r'(https?://)(?:localhost|127\.0\.0\.1|0\.0\.0\.0)(?=["/:]|$)'),
    (match) => '${match[1]}host.docker.internal',
  );

  Future<void> _copyStagedConfig(String container, Directory staged) async {
    // Per TOP-LEVEL entry, never per file: the container is created, not
    // started (no `docker exec`), and `docker cp` of a file into a
    // destination whose parent directory does not exist there fails, while a
    // directory copy creates its whole subtree in one call. A destination
    // that already exists (the wake re-copy, §6.2) makes a plain
    // `cp <src-dir> <dest>` LAND INSIDE it (`plugins/plugins/…`, verified
    // against docker 29.x) instead of merging — so directories ride as
    // `cp <src-dir>/. <dest>/`: the merge form, which also creates a
    // missing destination (the create path). Files copy plain (overwrite).
    for (final entry in staged.listSync(followLinks: false)) {
      final name = entry.path.split('/').last;
      final isDir = entry is Directory;
      await _runOrThrow([
        'cp',
        isDir ? '${entry.path}/.' : entry.path,
        '$container:/root/.config/opencode/$name${isDir ? '/' : ''}',
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

  /// Stage the container-local gh credentials (issue #120, spec §4): on a
  /// host whose gh keeps its token in the Secret-Service keyring, the
  /// read-only `~/.config/gh` mount carries only `hosts.yml` — no token —
  /// so every https push/`gh` call inside the orb dies (`could not read
  /// Username`), silently killing the return channel (§3). The bridge CAN
  /// reach the keyring, so it reads the host's token and stages a
  /// container-local gh config on the state-dir mount
  /// (`<stateRoot>/<id>/gh/hosts.yml` → `/root/.local/gh/hosts.yml`),
  /// which the entrypoint points `GH_CONFIG_DIR` at whenever it exists.
  /// One mechanism, no per-host branching: the mount stays mounted, the
  /// staged config simply wins (host-authoritative, re-staged at every
  /// create/wake/update — the token may have rotated). No host gh, no
  /// active github.com login, or no token: nothing is staged and the
  /// mount stays the surface (ssh remotes are unaffected either way — the
  /// mounted `~/.ssh` carries the key). The staged file carries a secret,
  /// so it rides the state dir: mode 600, deleted with the orb (its dir,
  /// spec §2.7). A successful stage clears the orb's stale `push-failed`
  /// marker: the marker said "the push is broken"; with the credentials
  /// refreshed that verdict is no longer known, and the next push re-marks
  /// it if it still fails (a start without credentials keeps the marker —
  /// it fixed nothing).
  Future<bool> _stageGhConfig(String id) async {
    final runner = gh;
    // No host gh at all: the ssh mount carries the push; nothing to stage
    // and nothing to blame on credentials (issue #145).
    if (runner == null) return false;
    String? login;
    String? token;
    String? failure;
    try {
      // The active github.com login (hosts.yml needs the user key, and
      // `gh auth token` alone does not say whose token it is).
      final status = await runner(['auth', 'status', '--json', 'hosts']);
      if (status.exitCode != 0) {
        failure = _ghFailureLine((
          status.exitCode,
          status.stdout,
          status.stderr,
        ), 'gh auth status');
      } else {
        final decoded = jsonDecode(status.stdout);
        final hosts = decoded is Map<String, Object?> ? decoded['hosts'] : null;
        final entries = hosts is Map<String, Object?>
            ? hosts['github.com']
            : null;
        if (entries is! List) {
          // A logged-out host: nothing to stage, and the orb will fail its
          // own probe anyway if it needs gh — say why (issue #145).
          failure = 'no github.com login on the host';
        } else {
          for (final entry in entries) {
            if (entry is Map<String, Object?> &&
                entry['active'] == true &&
                entry['state'] == 'success' &&
                entry['login'] is String) {
              login = entry['login'] as String;
              break;
            }
          }
          if (login == null) failure = 'no active github.com login on the host';
        }
        if (failure == null) {
          // Scope the read to the very login verified above: on a
          // multi-credential host, the unscoped `(default)` account is not
          // necessarily that login, and its token may be a stale one
          // GitHub rejects (issue #145, token the keyring returns).
          final result = await runner(['auth', 'token', '--user', login!]);
          if (result.exitCode == 0) {
            token = result.stdout.trim();
          } else {
            failure = _ghFailureLine((
              result.exitCode,
              result.stdout,
              result.stderr,
            ), 'gh auth token');
          }
        }
      }
    } on Object catch (error) {
      // No gh on the PATH anymore, or unreadable output: the mount stays
      // the surface (the create proceeds — an ssh remote still pushes).
      final reason = '$error'.trim().replaceAll(RegExp(r'\s+'), ' ');
      failure = 'the host gh could not be read: $reason';
    }
    // A token/login that is not a plain scalar is not a GitHub token /
    // login: stage nothing (the staged file is YAML the container reads).
    if (failure == null &&
        (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(token!) ||
            !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(login!))) {
      failure = 'the host gh token read back is not a token';
    }
    if (failure != null) {
      _markGhAuthFailed(id, failure);
      return false;
    }
    final dir = Directory('${stateRoot.path}/$id/gh')
      ..createSync(recursive: true);
    final hostsFile = File('${dir.path}/hosts.yml');
    // The gh hosts.yml shape (4-space indent).
    hostsFile.writeAsStringSync(
      'github.com:\n'
      '    users:\n'
      '        $login:\n'
      '            oauth_token: $token\n'
      '    user: $login\n',
    );
    _clearGhAuthFailure(id);
    try {
      Process.runSync('chmod', ['600', hostsFile.path]);
    } on ProcessException {
      // No chmod on the PATH: the file is written, permissions are best-
      // effort (same fallback as the Firebase service-account file).
    }
    final marker = File('${stateRoot.path}/$id/push-failed');
    try {
      if (marker.existsSync()) marker.deleteSync();
    } on FileSystemException {
      // A lingering marker only over-surfaces, never hides; the state
      // dir's own removal (the deletion) takes it with it.
    }
    return true;
  }

  /// The reason line of a failed host gh call (issue #145): its stderr's
  /// first non-empty line (gh writes the cause there, e.g. "The token in
  /// default is invalid."), else its stdout, else the step and the exit
  /// code — never an empty cause.
  static String _ghFailureLine(
    (int exitCode, String stdout, String stderr) result,
    String step,
  ) {
    for (final output in [result.$3, result.$2]) {
      for (final line in const LineSplitter().convert(output)) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) return trimmed;
      }
    }
    return '$step exited ${result.$1}';
  }

  /// Record that the orb's gh credentials could not be staged (issue #145):
  /// the cause on the state mount, host-side readable like `push-failed`
  /// (#120) so the list composes the row's `ghAuthFailed` flag — before the
  /// boot, so the boot report says so. Written even when the boot fails: the
  /// marker describes the credentials, not the boot.
  void _markGhAuthFailed(String id, String reason) {
    final marker = File('${stateRoot.path}/$id/gh-auth-failed');
    try {
      marker.parent.createSync(recursive: true);
      marker.writeAsStringSync(reason);
    } on FileSystemException {
      // No writable state dir: the create's own failures surface first.
      return;
    }
    final emitter = emit;
    if (emitter != null) {
      emitter(
        bridgeEvent(
          type: BridgeEventType.orbBoot,
          data: {'id': id, 'line': '[orb] gh auth: $reason'},
        ),
      );
    }
  }

  /// Clear [id]'s `gh-auth-failed` marker after a successful stage (issue
  /// #145): the #120/#149 rule — a marker describes the start that wrote it.
  void _clearGhAuthFailure(String id) {
    try {
      final marker = File('${stateRoot.path}/$id/gh-auth-failed');
      if (marker.existsSync()) marker.deleteSync();
    } on FileSystemException {
      // A lingering marker only over-surfaces, never hides.
    }
  }

  /// The post-boot in-container gh check (issue #145, spec §4). A staged
  /// `hosts.yml` merely existing is not proof: gh INSIDE the orb may still
  /// refuse GitHub — the token GitHub revoked after the bridge read it, or a
  /// config the container's gh does not resolve the way the host's does
  /// (measured on `orb` v0.1: the same well-formed file was "not logged into
  /// any GitHub hosts" from `docker exec`). So the proof is one cheap
  /// AUTHENTICATED call, made in the container with the config the agent will
  /// actually use: `gh api user`.
  ///
  /// `GH_CONFIG_DIR` must be passed explicitly: `docker exec` is not a child
  /// of the entrypoint, so it does not inherit the entrypoint's `export`
  /// (`smoke120_manual.dart:154` — an unpassed exec reads the tokenless mount
  /// and fails for every keyring host). The staged dir is the entrypoint's
  /// fixed `$STATE_DIR/gh` (`ORB_STATE_DIR` is never set by the bridge).
  ///
  /// Never throws and never fails the boot — the orb is a working workspace
  /// regardless: a refusal is reported (`ok: false`) and recorded on the
  /// state dir for the list and the boot log.
  Future<({bool ok, String? cause})> verifyGhAuth(
    String id,
    String container,
  ) async {
    final staged = File('${stateRoot.path}/$id/gh/hosts.yml');
    if (!staged.existsSync()) {
      // Nothing staged: the tokenless mount is the surface (an ssh remote
      // still pushes), and gh may legitimately have no API work to do.
      return (ok: true, cause: null);
    }
    DockerCliResult result;
    try {
      result = await run([
        'exec',
        '-e',
        'GH_CONFIG_DIR=$inContainerGhConfigDir',
        container,
        'gh',
        'api',
        'user',
        '--jq',
        '.login',
      ]);
    } on Object catch (error) {
      // The docker CLI itself refused: a warning, never a failed boot.
      result = DockerCliResult(exitCode: -1, stdout: '', stderr: '$error');
    }
    if (result.exitCode == 0 && result.stdout.trim().isNotEmpty) {
      _clearGhAuthFailure(id);
      return (ok: true, cause: null);
    }
    final cause = _ghFailureLine((
      result.exitCode,
      result.stdout,
      result.stderr,
    ), 'gh api user');
    _markGhAuthFailed(id, cause);
    return (ok: false, cause: cause);
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
        // The shell probe's failure is the boot's own reason (issue #149,
        // spec §6.8): a generic "exited during boot" would leave the caller
        // guessing why the orb it spawned can never do a code task.
        throw OrbBootError(
          id,
          noShellReason(log) ?? 'the orb container exited during boot',
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

  /// The post-boot provider-credential sync (issue #138, spec §6.7): the
  /// host's stored integration credentials are pushed into the orb's own
  /// opencode server (`POST /api/credential`), so an orb agent can reach
  /// the host's providers (the legacy `auth.json` copy no longer covers a
  /// v2 host, whose credentials live in the service's DB). Host-authoritative
  /// like §6.2 and §4 (re-synced on every create/wake/update; the host's
  /// value replaces the orb's after a stop/wake — the orb state dir's copy
  /// only survives an update re-create). An integration the orb already
  /// holds with the same value is skipped (idempotent). Every failure
  /// degrades to a boot-log warning: a credential-less orb is a degraded
  /// orb, not a failed boot (the host may simply have no shared service).
  Future<void> _syncHostCredentials(
    String id,
    String url,
    String password,
  ) async {
    final read = hostCredentials ?? _hostCredentialsFromDescriptor;
    List<OrbCredential> credentials;
    try {
      credentials = await read();
    } on Object catch (error) {
      _bootWarn(id, 'the host credentials could not be read ($error)');
      return;
    }
    if (credentials.isEmpty) return;
    final auth = 'Basic ${base64.encode(utf8.encode('opencode:$password'))}';
    try {
      final client = HttpClient();
      try {
        final existing = await _orbCredentials(client, url, auth);
        for (final credential in credentials) {
          if (existing[credential.integrationId] ==
              _credentialKey(credential.value)) {
            continue;
          }
          await _postOrbCredential(client, url, auth, credential);
        }
      } finally {
        client.close(force: true);
      }
    } on Object catch (error) {
      _bootWarn(id, 'the host credentials could not be synced ($error)');
    }
  }

  /// The orb's stored credentials as `integrationId -> canonical value key`
  /// (`GET /api/credential`, the same key-space the create payloads compare
  /// against). A failed read yields the empty map: every host credential is
  /// then (re-)posted.
  Future<Map<String, String>> _orbCredentials(
    HttpClient client,
    String url,
    String auth,
  ) async {
    try {
      final request = await client.getUrl(Uri.parse('$url/api/credential'));
      request.headers.set('Authorization', auth);
      final response = await request.close();
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) return {};
      final decoded = jsonDecode(body);
      final data = decoded is Map<String, Object?> ? decoded['data'] : null;
      if (data is! List) return {};
      return {
        for (final entry in data)
          if (entry is Map<String, Object?> &&
              entry['integrationID'] is String &&
              entry['value'] != null)
            entry['integrationID'] as String: _credentialKey(entry['value']),
      };
    } on Object {
      return {};
    }
  }

  /// Stores one credential in the orb (`POST /api/credential`, activated:
  /// a rotated host token replaces the orb's active credential, host-
  /// authoritative). A conflict (the id already exists) is the credential
  /// already there — accepted.
  Future<void> _postOrbCredential(
    HttpClient client,
    String url,
    String auth,
    OrbCredential credential,
  ) async {
    final request = await client.postUrl(Uri.parse('$url/api/credential'));
    request.headers.set('Authorization', auth);
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'integrationID': credential.integrationId,
        'value': credential.value,
        'activate': true,
        if (credential.label != null) 'label': credential.label,
      }),
    );
    final response = await request.close();
    await response.drain<void>();
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.conflict) {
      throw Exception(
        'POST /api/credential for ${credential.integrationId} answered '
        '${response.statusCode}',
      );
    }
  }

  /// The canonical key of a credential value JSON: a stable
  /// whitespace-free rendering, so the host's `GET` body and the payload the
  /// bridge posts back (and the orb re-serves) compare equal whatever
  /// spacing the server used.
  static String _credentialKey(Object? value) => _compactJson(value);

  /// A stable whitespace-free JSON rendering of a decoded value (map and
  /// list orders preserved as the server sent them).
  static String _compactJson(Object? value) {
    if (value is Map) {
      final entries = value.entries
          .map((e) => '${jsonEncode(e.key)}:${_compactJson(e.value)}')
          .join(',');
      return '{$entries}';
    }
    if (value is List) {
      return '[${value.map(_compactJson).join(',')}]';
    }
    return jsonEncode(value);
  }

  /// Reads the host's credentials through the shared-service descriptor
  /// (`~/.local/state/opencode/service.json`, the same source the sessions
  /// backend uses); no descriptor — no credentials (the orb boots as before
  /// the sync existed). The [hostCredentials] seam overrides it.
  Future<List<OrbCredential>> _hostCredentialsFromDescriptor() async {
    final file = File('$home/.local/state/opencode/service.json');
    if (!file.existsSync()) return const [];
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map<String, Object?>) return const [];
    final url = raw['url'];
    final password = raw['password'];
    if (url is! String || password is! String) return const [];
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('$url/api/credential'));
      request.headers.set(
        'Authorization',
        'Basic ${base64.encode(utf8.encode('opencode:$password'))}',
      );
      final response = await request.close();
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('GET /api/credential answered ${response.statusCode}');
      }
      final decoded = jsonDecode(body);
      final data = decoded is Map<String, Object?> ? decoded['data'] : null;
      if (data is! List) return const [];
      return [
        for (final entry in data)
          if (entry is Map<String, Object?> &&
              entry['integrationID'] is String &&
              entry['value'] is Map<String, Object?>)
            OrbCredential(
              integrationId: entry['integrationID'] as String,
              value: entry['value'] as Map<String, Object?>,
              label: entry['label'] is String ? entry['label'] as String : null,
            ),
      ];
    } finally {
      client.close(force: true);
    }
  }

  /// A sync failure as a boot-log warning (the OrbService's own line, not a
  /// container log line — the event shape `orb.boot` already carries).
  void _bootWarn(String id, String message) => emit?.call(
    bridgeEvent(
      type: BridgeEventType.orbBoot,
      data: {'id': id, 'line': '[orb] credential sync: $message'},
    ),
  );

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
      base: decoded['ocb.base'] as String?,
    );
  }

  /// The shell-probe failure reason of orb [id], read from the state mount's
  /// `no-shell` marker the entrypoint writes (spec §6.8, issue #149), or `null`
  /// when that boot passed the probe. A host-side read only — the marker is
  /// cleared by the next passing boot, exactly like `push-failed` (#120).
  String? _noShellMarker(String id) {
    final file = File('${stateRoot.path}/$id/no-shell');
    if (!file.existsSync()) return null;
    try {
      final reason = file.readAsStringSync().trim();
      return reason.isEmpty ? 'no usable shell' : reason;
    } on FileSystemException {
      // Unreadable for a moment (a boot rewriting it): no verdict beats a
      // wrong one, and the next list reads it again.
      return null;
    }
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
    base: record.base,
    pushFailing: record.pushFailing,
    ghAuthFailed: record.ghAuthFailed,
    bootReason: record.bootReason,
  );

  /// [record] with its boot-failure reason set (issue #149: the shell probe's
  /// `FATAL` line, read back from the container log).
  OrbRecord _withBootReason(OrbRecord record, String reason) => OrbRecord(
    id: record.id,
    name: record.name,
    project: record.project,
    branch: record.branch,
    state: record.state,
    created: record.created,
    url: record.url,
    pr: record.pr,
    base: record.base,
    pushFailing: record.pushFailing,
    ghAuthFailed: record.ghAuthFailed,
    bootReason: reason,
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
