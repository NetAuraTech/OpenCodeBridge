/// The tunnel status as reported by the bridge's tunnel endpoints.
enum TunnelStatus {
  /// The tunnel is up: the cloudflared child runs and holds registered
  /// connections to the Cloudflare edge.
  up,

  /// The tunnel is down: the setup is incomplete (see
  /// [TunnelReport.missing]), cloudflared runs but is not connected to the
  /// edge, or the capped auto-respawn has been exhausted.
  down,

  /// This host does not run a tunnel (the bridge has no tunnel support).
  notConfigured,
}

extension TunnelStatusJson on TunnelStatus {
  String toWire() => switch (this) {
    TunnelStatus.up => 'up',
    TunnelStatus.down => 'down',
    TunnelStatus.notConfigured => 'not_configured',
  };

  static TunnelStatus fromWire(Object? value) => switch (value) {
    'up' => TunnelStatus.up,
    'not_configured' => TunnelStatus.notConfigured,
    _ => TunnelStatus.down,
  };
}

/// The guided-setup step ids, in the order the guided setup shows them
/// (one-time manual setup, issue #22).
class TunnelSetupStep {
  const TunnelSetupStep._();

  /// The tunnel has not been created yet (no `~/.cloudflared/<uuid>.json`).
  static const String credentials = 'credentials';

  /// The app-owned config `~/.config/opencodebridge/cloudflared.yml` is
  /// missing or invalid.
  static const String config = 'config';

  /// The DNS route of the ingress hostname has not been created.
  static const String dnsRoute = 'dns_route';

  /// The Cloudflare Access application for the hostname has not been
  /// created (or is not enforcing).
  static const String access = 'access';

  /// The app-managed cloudflared binary is unavailable (download failed).
  static const String binary = 'binary';

  /// Every step, in display order.
  static const List<String> all = [
    credentials,
    config,
    dnsRoute,
    access,
    binary,
  ];
}

/// The payload of the bridge's tunnel endpoints (`GET /api/tunnel`, and the
/// `POST /api/tunnel/check` / `POST /api/tunnel/start` responses).
class TunnelReport {
  const TunnelReport({
    required this.status,
    required this.running,
    required this.registeredConnections,
    this.metricsPort,
    this.hostname,
    this.missing = const [],
    this.missingDetails = const [],
  });

  /// The tunnel status.
  final TunnelStatus status;

  /// Whether the cloudflared child process runs. Together with
  /// [registeredConnections] this is what distinguishes "cloudflared runs"
  /// from "actually connected to the edge".
  final bool running;

  /// The registered connections to the Cloudflare edge, from the child's
  /// `--metrics` scrape; > 0 means the tunnel is connected.
  final int registeredConnections;

  /// The child's metrics port (the primary, or the fallback), `null` when
  /// no child has been spawned yet.
  final int? metricsPort;

  /// The ingress hostname from the app-owned config, `null` when the
  /// config is not available.
  final String? hostname;

  /// The ids of the setup steps that are not met ([TunnelSetupStep]).
  final List<String> missing;

  /// The human-readable explanation of each missing step (parallel to
  /// [missing]).
  final List<String> missingDetails;

  Map<String, Object?> toJson() => {
    'status': status.toWire(),
    'running': running,
    'connections': registeredConnections,
    'port': metricsPort,
    'hostname': hostname,
    'missing': missing,
    'details': missingDetails,
  };

  factory TunnelReport.fromJson(Object? json) {
    final map = json is Map<String, Object?> ? json : const <String, Object?>{};
    final missing = map['missing'];
    final details = map['details'];
    return TunnelReport(
      status: TunnelStatusJson.fromWire(map['status']),
      running: map['running'] == true,
      registeredConnections: (map['connections'] as num?)?.toInt() ?? 0,
      metricsPort: map['port'] is int ? map['port'] as int : null,
      hostname: map['hostname'] is String ? map['hostname'] as String : null,
      missing: missing is List
          ? missing.whereType<String>().toList()
          : const [],
      missingDetails: details is List
          ? details.whereType<String>().toList()
          : const [],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TunnelReport &&
      other.status == status &&
      other.running == running &&
      other.registeredConnections == registeredConnections &&
      other.metricsPort == metricsPort &&
      other.hostname == hostname &&
      _same(other.missing, missing) &&
      _same(other.missingDetails, missingDetails);

  static bool _same(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    status,
    running,
    registeredConnections,
    metricsPort,
    hostname,
    Object.hashAll(missing),
    Object.hashAll(missingDetails),
  );

  @override
  String toString() =>
      'TunnelReport(${status.toWire()}, running: $running, '
      'connections: $registeredConnections, port: $metricsPort, '
      'hostname: $hostname, missing: $missing)';
}
