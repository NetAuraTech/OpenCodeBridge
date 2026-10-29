/// Reachability status of one component as reported by the bridge health
/// endpoint (`GET /api/health`).
enum ComponentStatus {
  /// The component is reachable and answering.
  ok,

  /// The component is configured but does not answer.
  unreachable,

  /// The component is not configured yet (scaffold phase).
  notConfigured,
}

extension ComponentStatusJson on ComponentStatus {
  String toWire() => switch (this) {
    ComponentStatus.ok => 'ok',
    ComponentStatus.unreachable => 'unreachable',
    ComponentStatus.notConfigured => 'not_configured',
  };

  static ComponentStatus fromWire(Object? value) => switch (value) {
    'ok' => ComponentStatus.ok,
    'unreachable' => ComponentStatus.unreachable,
    _ => ComponentStatus.notConfigured,
  };
}

/// The payload of `GET /api/health`: the reachability of the bridge itself,
/// the opencode service, and Docker. Drives the discreet connection indicator
/// in the app.
class HealthReport {
  const HealthReport({
    required this.bridge,
    required this.opencode,
    required this.docker,
  });

  final ComponentStatus bridge;
  final ComponentStatus opencode;
  final ComponentStatus docker;

  Map<String, Object?> toJson() => {
    'bridge': bridge.toWire(),
    'opencode': opencode.toWire(),
    'docker': docker.toWire(),
  };

  factory HealthReport.fromJson(Map<String, Object?> json) => HealthReport(
    bridge: ComponentStatusJson.fromWire(json['bridge']),
    opencode: ComponentStatusJson.fromWire(json['opencode']),
    docker: ComponentStatusJson.fromWire(json['docker']),
  );

  @override
  bool operator ==(Object other) =>
      other is HealthReport &&
      other.bridge == bridge &&
      other.opencode == opencode &&
      other.docker == docker;

  @override
  int get hashCode => Object.hash(bridge, opencode, docker);

  @override
  String toString() =>
      'HealthReport(bridge: ${bridge.toWire()}, opencode: ${opencode.toWire()}, docker: ${docker.toWire()})';
}
