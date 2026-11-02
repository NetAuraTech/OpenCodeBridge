// The home-list contract shared by the bridge (which composes it) and the
// app (which renders it). One `Session` row is what `GET /api/sessions`
// returns per session (spec §5 endpoint 1, §6): the identity, the project
// grouping, and the freshness facts.

/// A project, the unit the home list groups sessions by (spec §5, §6).
class SessionProject {
  const SessionProject({required this.id, required this.name});

  final String id;

  /// Display name; the bridge derives it from the service project list.
  final String name;

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  factory SessionProject.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    return SessionProject(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SessionProject && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'SessionProject(id: $id, name: $name)';
}

/// One session row of the home list (spec §5 endpoint 1, §6).
class Session {
  const Session({
    required this.id,
    required this.title,
    required this.project,
    required this.created,
    required this.location,
    required this.active,
  });

  final String id;
  final String title;
  final SessionProject project;

  /// Epoch millis, from the service's session `time.created`.
  final int created;

  /// The working directory, the service's session `location.directory`.
  final String location;

  /// True when the session is in the service's active list (agent working).
  final bool active;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'project': project.toJson(),
    'created': created,
    'location': location,
    'active': active,
  };

  factory Session.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    return Session(
      id: map['id'] as String? ?? '',
      title: map['title'] as String? ?? '',
      project: SessionProject.fromJson(map['project']),
      created: (map['created'] as num?)?.toInt() ?? 0,
      location: map['location'] as String? ?? '',
      active: map['active'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Session &&
      other.id == id &&
      other.title == title &&
      other.project == project &&
      other.created == created &&
      other.location == location &&
      other.active == active;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    project,
    created,
    location,
    active,
  );

  @override
  String toString() =>
      'Session(id: $id, title: $title, project: $project, created: $created, location: $location, active: $active)';
}
