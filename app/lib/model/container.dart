// The Docker contract shared by the bridge (which composes it from the host
// docker CLI) and the app (which renders the Docker tab, issue #21). One
// `DockerContainer` row is what `GET /api/docker/containers` returns per
// container: the name, the image, the state, and the uptime. Containers are
// addressed by name everywhere (the actions and the logs endpoints).

/// The state of one container, the docker CLI's `State` field of
/// `docker ps`. Drives the row's badge and the detail screen's actions.
enum DockerState {
  /// Created but never started (also the tolerant default for unknown wire
  /// values).
  created('created'),

  /// The main process is running.
  running('running'),

  /// The main process is suspended.
  paused('paused'),

  /// Being restarted (an `on-failure`-style restart policy kicked in).
  restarting('restarting'),

  /// The main process exited (cleanly or not).
  exited('exited'),

  /// Being removed.
  removing('removing'),

  /// An unrecoverable failure of the main process.
  dead('dead');

  const DockerState(this.wire);

  /// The wire value on the bridge contract.
  final String wire;

  /// Tolerant wire parse: anything unknown is [DockerState.created].
  static DockerState fromWire(Object? value) => switch (value) {
    'running' => DockerState.running,
    'paused' => DockerState.paused,
    'restarting' => DockerState.restarting,
    'exited' => DockerState.exited,
    'removing' => DockerState.removing,
    'dead' => DockerState.dead,
    _ => DockerState.created,
  };
}

/// The action to take on one container (issue #21,
/// `POST /api/docker/containers/{name}/action`).
enum DockerAction {
  start('start'),
  stop('stop'),
  restart('restart');

  const DockerAction(this.wire);

  /// The wire value on the bridge contract.
  final String wire;

  /// Parse the bridge contract's `action` value. Unlike the tolerant
  /// [DockerState.fromWire], this reads a user decision: an unknown value is
  /// a client error, so it throws [ArgumentError] for the bridge to map to a
  /// 400.
  static DockerAction fromWire(Object? value) => switch (value) {
    'start' => DockerAction.start,
    'stop' => DockerAction.stop,
    'restart' => DockerAction.restart,
    _ => throw ArgumentError.value(
      value,
      'action',
      'must be start, stop, or restart',
    ),
  };
}

/// One row of the container list (issue #21).
class DockerContainer {
  const DockerContainer({
    required this.name,
    required this.image,
    required this.state,
    required this.uptime,
  });

  /// The container name; the address of the container on the actions and
  /// logs endpoints.
  final String name;

  /// The image, e.g. `nginx:latest`.
  final String image;

  /// The docker CLI's state.
  final DockerState state;

  /// How long the container has been running (the docker CLI's
  /// `RunningFor`), or `null` when it is not running.
  final String? uptime;

  Map<String, Object?> toJson() => {
    'name': name,
    'image': image,
    'state': state.wire,
    'uptime': uptime,
  };

  factory DockerContainer.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    final uptime = map['uptime'];
    return DockerContainer(
      name: map['name'] as String? ?? '',
      image: map['image'] as String? ?? '',
      state: DockerState.fromWire(map['state']),
      uptime: uptime is String && uptime.isNotEmpty ? uptime : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DockerContainer &&
      other.name == name &&
      other.image == image &&
      other.state == state &&
      other.uptime == uptime;

  @override
  int get hashCode => Object.hash(name, image, state, uptime);

  @override
  String toString() =>
      'DockerContainer(name: $name, image: $image, state: ${state.wire}, uptime: $uptime)';
}
