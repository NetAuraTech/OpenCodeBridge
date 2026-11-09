// The orb-list contract shared by the bridge (which serves it) and the app
// (which renders it as the Orbs tab's cards).

/// The open-PR state of one orb's branch (issue #96, spec §9.1). Fetched
/// from GitHub through the host `gh` CLI and carried on the orb list only
/// when the caller asks for it (`GET /api/orbs?pr=1`).
class OrbPr {
  const OrbPr({required this.state, required this.url});

  /// The PR state as GitHub reports it for the orb's head ref:
  /// `open`, `merged`, or `closed`.
  final String state;

  /// The PR's web URL (the badge links to it).
  final String url;

  /// Whether the PR is still open (the badge renders only then).
  bool get isOpen => state == 'open';

  Map<String, Object?> toJson() => {'state': state, 'url': url};

  factory OrbPr.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    return OrbPr(
      state: map['state'] as String? ?? '',
      url: map['url'] as String? ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OrbPr && other.state == state && other.url == url;

  @override
  int get hashCode => Object.hash(state, url);

  @override
  String toString() => 'OrbPr(state: $state, url: $url)';
}

/// One orb, a row of the orb list. The record is derived from the
/// `ocb.*` Docker labels (spec §2.1) — there is no registry file.
class OrbRecord {
  const OrbRecord({
    required this.id,
    required this.name,
    required this.project,
    required this.branch,
    required this.state,
    required this.created,
    this.url,
    this.pr,
    this.base,
    this.pushFailing = false,
    this.ghAuthFailed,
    this.bootReason,
  });

  /// The technical identifier (label `ocb.id`): names the branch, the
  /// volumes, and the state dir.
  final String id;

  /// The user-facing handle, unique within the project (label `ocb.name`).
  final String name;

  /// The project identifier as the bridge knows it (label `ocb.project`).
  final String project;

  /// The one-branch-per-orb branch (label `ocb.branch`), `orb/<id>`.
  final String branch;

  /// The composed state (spec §2.2): `running`, `stopped`,
  /// `cleanup_pending:<reason>` (a stopped orb the automated lifecycle
  /// pass surfaced as a guard-blocked auto-delete candidate, issue #101,
  /// spec §2.10.2/§9.4), `broken:workspace`, `broken:state`, `broken:shell`
  /// (the boot failed at the shell probe — the agent could not run a
  /// command, issue #149, spec §6.8), or `orphan`.
  final String state;

  /// Why the orb is broken, when its boot said so on the container log
  /// (issue #149): the boot's fatal line, verbatim — the refusal reason the
  /// `orb_wait` result and the card carry ("spawned, works nowhere" is said
  /// with the cause). `null` for a healthy row and for a broken row whose
  /// boot never logged a reason (a missing volume/dir says itself).
  final String? bootReason;

  /// Whether the orb's boot failed at the shell probe (issue #149, spec
  /// §6.8): its agent cannot run a command, so no code task can land — it is
  /// never surfaced as `running`/`ready`, and the spawn surface refuses it
  /// with the [bootReason].
  bool get hasNoShell => state == 'broken:shell';

  /// Whether this is a stopped orb under the badge: plain `stopped`, or
  /// `cleanup_pending:<reason>` — the same container state, the lifecycle
  /// pass's marker composing a surfaced variant of it. The Wake/Update/
  /// Force-delete actions treat the two alike.
  bool get isStoppedLike =>
      state == 'stopped' || state.startsWith('cleanup_pending');

  /// The creation timestamp, ISO 8601 (label `ocb.created`).
  final String created;

  /// The per-orb service URL (`http://127.0.0.1:<ephemeral-port>`); present
  /// only for a running orb (the host port is ephemeral, spec §2.9).
  final String? url;

  /// The PR of the orb's branch, when the list was fetched with `pr=1` and
  /// one exists (issue #96); `null` when not requested or none found.
  final OrbPr? pr;

  /// The branch the clone started from (label `ocb.base`, issue #100, spec
  /// §3.3): the seed's branch for a seeded orb — the PR stacks on it.
  /// `null` for an unseeded orb (its PR base is the remote's default).
  final String? base;

  /// Whether the orb's post-commit push to the remote is failing (issue
  /// #120): the branch is not reaching GitHub, so the return channel
  /// (§3.1/§3.2 — seed, PR, the deletion guard's pushed side) silently
  /// degrades. Composed from the state dir's `push-failed` marker, written
  /// by the orb's post-commit hook.
  final bool pushFailing;

  /// The cause of the orb's gh authentication failure (issue #145), read
  /// from the state dir's `gh-auth-failed` marker the bridge writes when it
  /// cannot stage usable gh credentials for the start; `null` when the
  /// staging succeeded (or the host has no gh at all — the ssh mount then
  /// still pushes, nothing to blame on credentials). The agent's every API
  /// call would answer 401: the card says why instead.
  final String? ghAuthFailed;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'project': project,
    'branch': branch,
    'state': state,
    'created': created,
    if (url != null) 'url': url,
    if (pr != null) 'pr': pr!.toJson(),
    if (base != null) 'base': base,
    if (pushFailing) 'pushFailing': true,
    if (ghAuthFailed != null) 'ghAuthFailed': ghAuthFailed,
    if (bootReason != null) 'bootReason': bootReason,
  };

  factory OrbRecord.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    return OrbRecord(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      project: map['project'] as String? ?? '',
      branch: map['branch'] as String? ?? '',
      state: map['state'] as String? ?? '',
      created: map['created'] as String? ?? '',
      url: map['url'] as String?,
      pr: map['pr'] == null ? null : OrbPr.fromJson(map['pr']),
      base: map['base'] as String?,
      pushFailing: map['pushFailing'] == true,
      ghAuthFailed: map['ghAuthFailed'] as String?,
      bootReason: map['bootReason'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OrbRecord &&
      other.id == id &&
      other.name == name &&
      other.project == project &&
      other.branch == branch &&
      other.state == state &&
      other.created == created &&
      other.url == url &&
      other.pr == pr &&
      other.base == base &&
      other.pushFailing == pushFailing &&
      other.ghAuthFailed == ghAuthFailed &&
      other.bootReason == bootReason;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    project,
    branch,
    state,
    created,
    url,
    pr,
    base,
    pushFailing,
    ghAuthFailed,
    bootReason,
  );

  @override
  String toString() =>
      'OrbRecord(id: $id, name: $name, state: $state'
      '${bootReason == null ? '' : ', reason: $bootReason'})';
}
