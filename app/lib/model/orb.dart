// The orb-list contract shared by the bridge (which serves it) and the app
// (which renders it as the Orbs tab's cards).

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
  /// `broken:workspace`, `broken:state`, or `orphan`.
  final String state;

  /// The creation timestamp, ISO 8601 (label `ocb.created`).
  final String created;

  /// The per-orb service URL (`http://127.0.0.1:<ephemeral-port>`); present
  /// only for a running orb (the host port is ephemeral, spec §2.9).
  final String? url;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'project': project,
    'branch': branch,
    'state': state,
    'created': created,
    if (url != null) 'url': url,
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
      other.url == url;

  @override
  int get hashCode =>
      Object.hash(id, name, project, branch, state, created, url);

  @override
  String toString() => 'OrbRecord(id: $id, name: $name, state: $state)';
}
