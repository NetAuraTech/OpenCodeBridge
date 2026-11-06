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
  /// spec §2.10.2/§9.4), `broken:workspace`, `broken:state`, or `orphan`.
  final String state;

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

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'project': project,
    'branch': branch,
    'state': state,
    'created': created,
    if (url != null) 'url': url,
    if (pr != null) 'pr': pr!.toJson(),
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
      other.pr == pr;

  @override
  int get hashCode =>
      Object.hash(id, name, project, branch, state, created, url, pr);

  @override
  String toString() => 'OrbRecord(id: $id, name: $name, state: $state)';
}
