// The project-list contract shared by the bridge (which serves it) and the
// app (which renders it as the new-session picker's rows) (spec §5,
// fill-in †).

/// One project, a row of the new-session project picker.
class Project {
  const Project({
    required this.id,
    required this.name,
    required this.canonical,
  });

  /// The bridge's project id (what the app sends as `project` to create).
  final String id;

  /// Display name.
  final String name;

  /// The canonical directory; a new session's PTY is created here.
  final String canonical;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'canonical': canonical,
  };

  factory Project.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    return Project(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      canonical: map['canonical'] as String? ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Project &&
      other.id == id &&
      other.name == name &&
      other.canonical == canonical;

  @override
  int get hashCode => Object.hash(id, name, canonical);

  @override
  String toString() => 'Project(id: $id, name: $name, canonical: $canonical)';
}
