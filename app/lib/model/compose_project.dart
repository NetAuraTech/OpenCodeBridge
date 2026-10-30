// The compose contract shared by the bridge (which discovers the compose
// files in the repos opencode lists, and drives `docker compose`) and the app
// (which renders the compose section of the Docker tab). A `ComposeProject`
// is one docker-compose file found in one repo; its `services` are the
// containers it can create, each with its live state when it has been created.
import 'container.dart';

/// The action to take on a compose project or one of its services
/// (`POST /api/docker/compose/{id}/action`).
enum ComposeAction {
  /// Create the services if needed and start them (`docker compose up -d`).
  up('up'),

  /// Stop the running services, keeping their containers (`docker compose stop`).
  stop('stop');

  const ComposeAction(this.wire);

  /// The wire value on the bridge contract.
  final String wire;

  /// Parse the bridge contract's `action` value. Like
  /// [DockerAction.fromWire], an unknown value is a client error: it throws
  /// [ArgumentError] for the bridge to map to a 400.
  static ComposeAction fromWire(Object? value) => switch (value) {
    'up' => ComposeAction.up,
    'stop' => ComposeAction.stop,
    _ => throw ArgumentError.value(value, 'action', 'must be up or stop'),
  };
}

/// One service of a compose project. A service that has never been created
/// has [state] `null` (it is creatable but has no container yet); once
/// created it carries the docker state of its container.
class ComposeService {
  const ComposeService({
    required this.name,
    required this.state,
    this.image,
    this.container,
  });

  /// The service name, as declared in the compose file (e.g. `web`).
  final String name;

  /// The docker state of the service's container, or `null` when the service
  /// has never been created.
  final DockerState? state;

  /// The image, when known (from the live container; `null` when the service
  /// has never been created).
  final String? image;

  /// The created container's name (e.g. `proj-web-1`), or `null` when the
  /// service has never been created.
  final String? container;

  /// True once the service has a container (created, running, or exited).
  bool get isCreated => state != null;

  /// True while the service's container is running.
  bool get isRunning => state == DockerState.running;

  Map<String, Object?> toJson() => {
    'name': name,
    'state': state?.wire,
    'image': image,
    'container': container,
  };

  factory ComposeService.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    final state = map['state'];
    final image = map['image'];
    final container = map['container'];
    return ComposeService(
      name: map['name'] as String? ?? '',
      state: state is String && state.isNotEmpty
          ? DockerState.fromWire(state)
          : null,
      image: image is String && image.isNotEmpty ? image : null,
      container: container is String && container.isNotEmpty ? container : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ComposeService &&
      other.name == name &&
      other.state == state &&
      other.image == image &&
      other.container == container;

  @override
  int get hashCode => Object.hash(name, state, image, container);

  @override
  String toString() =>
      'ComposeService(name: $name, state: ${state?.wire}, image: $image, container: $container)';
}

/// One detected docker-compose project: the compose file found in one of the
/// repos opencode lists, its creatable services, and their live state.
class ComposeProject {
  const ComposeProject({
    required this.id,
    required this.project,
    required this.path,
    required this.composeFile,
    required this.services,
  });

  /// The single-segment address of the project on the action endpoint: the
  /// project directory URL-encoded (a path segment, so no raw `/`).
  final String id;

  /// The compose project name (the directory's basename, as `docker compose`
  /// derives it).
  final String project;

  /// The repo's canonical directory, where the compose file lives.
  final String path;

  /// The absolute path of the compose file.
  final String composeFile;

  /// The creatable services, in the compose file's order, each with its live
  /// state (or `null` state when never created).
  final List<ComposeService> services;

  /// True while at least one service is running.
  bool get anyRunning => services.any((s) => s.isRunning);

  /// True while at least one service is not running.
  bool get anyNotRunning => services.any((s) => !s.isRunning);

  Map<String, Object?> toJson() => {
    'id': id,
    'project': project,
    'path': path,
    'composeFile': composeFile,
    'services': [for (final s in services) s.toJson()],
  };

  factory ComposeProject.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    final services = map['services'];
    return ComposeProject(
      id: map['id'] as String? ?? '',
      project: map['project'] as String? ?? '',
      path: map['path'] as String? ?? '',
      composeFile: map['composeFile'] as String? ?? '',
      services: services is List
          ? [for (final s in services) ComposeService.fromJson(s)]
          : const [],
    );
  }

  /// The address of a compose project from its directory (a single, `/`-free
  /// path segment, so it rides the action path like a container name).
  static String encodeId(String path) => Uri.encodeComponent(path);

  /// The directory behind a compose project's address.
  static String decodeId(String id) => Uri.decodeComponent(id);

  @override
  bool operator ==(Object other) =>
      other is ComposeProject &&
      other.id == id &&
      other.project == project &&
      other.path == path &&
      other.composeFile == composeFile &&
      _sameServices(services, other.services);

  static bool _sameServices(List<ComposeService> a, List<ComposeService> b) =>
      a.length == b.length &&
      Iterable<bool>.generate(a.length, (i) => a[i] == b[i]).every((e) => e);

  @override
  int get hashCode => Object.hash(id, project, path, composeFile, services);

  @override
  String toString() =>
      'ComposeProject(project: $project, path: $path, services: ${services.length})';
}
