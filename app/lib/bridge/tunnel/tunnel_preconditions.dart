import 'dart:convert';
import 'dart:io';

import '../sessions/paths.dart';
import 'cloudflared_binary.dart';
import 'cloudflared_config.dart';
import '../../model/tunnel_report.dart';

/// One setup step that is not met, as the guided setup reports it.
class MissingStep {
  const MissingStep({required this.id, required this.message});

  /// A [TunnelSetupStep] id.
  final String id;

  /// The human-readable explanation, shown as-is.
  final String message;
}

/// The outcome of a precondition pass.
class PreconditionResult {
  const PreconditionResult({required this.missing, required this.config});

  /// The setup steps that are not met, in check order.
  final List<MissingStep> missing;

  /// The parsed app-owned config, when it is in place.
  final ParsedCloudflaredConfig? config;

  bool get allMet => missing.isEmpty;
}

/// Whether the ingress hostname resolves at all (the DNS route exists).
typedef DnsResolver = Future<bool> Function(String hostname);

/// What an unauthenticated request to the tunnel hostname shows.
enum AccessVerdict {
  /// Cloudflare Access challenged the request (an Access application is
  /// enforcing on the hostname).
  enforcing,

  /// The request reached the origin without a challenge: the tunnel is
  /// open to the internet.
  open,

  /// The hostname could not be reached (no DNS route, no network, …).
  unreachable,
}

/// Probes what an unauthenticated request to `https://<hostname>/` shows.
typedef AccessProbe = Future<AccessVerdict> Function(String hostname);

/// The default [AccessProbe]: an unauthenticated GET of the hostname.
///
/// A challenge (a redirect to the Access login, or a Cloudflare Access
/// error) means Access is enforcing. A 2xx answer means the request reached
/// the origin without a challenge — the dangerous case.
Future<AccessVerdict> accessProbe(String hostname) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.getUrl(Uri.https(hostname, '/'));
    final response = await request.close().timeout(const Duration(seconds: 10));
    try {
      final status = response.statusCode;
      final location = response.headers.value(HttpHeaders.locationHeader) ?? '';
      await response.drain<void>();
      // A 2xx answer reached the origin without a challenge: the tunnel is
      // open. A 401/403, or a redirect to the Access login path, is
      // Cloudflare Access challenging the request. (The bridge itself never
      // answers 401/403, so those cannot come from the origin.)
      if (status < 300) return AccessVerdict.open;
      if (status == 401 || status == 403) return AccessVerdict.enforcing;
      if (status == 302 && location.contains('/cdn-cgi/access/')) {
        return AccessVerdict.enforcing;
      }
      return AccessVerdict.open;
    } finally {
      client.close(force: true);
    }
  } catch (_) {
    return AccessVerdict.unreachable;
  }
}

/// Verifies every tunnel precondition (issue #22, ADR-0002): the app-owned
/// config, the tunnel credentials, the app-managed binary, the DNS route,
/// and Cloudflare Access — reporting the steps that are not met.
class TunnelPreconditionChecker {
  TunnelPreconditionChecker({
    required this.binary,
    required this.configFile,
    required this.bridgePort,
    this._dnsResolves = _hostDnsResolves,
    this._accessProbe = accessProbe,
  });

  /// The app-managed binary (verified by ensuring the pinned version).
  final CloudflaredBinary binary;

  /// The app-owned config file.
  final CloudflaredConfigFile configFile;

  /// The port the bridge listens on: the config's ingress service must
  /// point at it.
  final int bridgePort;

  final DnsResolver _dnsResolves;
  final AccessProbe _accessProbe;

  /// Run every check; the result lists the steps that are not met.
  Future<PreconditionResult> check() async {
    final missing = <MissingStep>[];
    ParsedCloudflaredConfig? config;
    try {
      config = configFile.read();
    } on CloudflaredConfigError catch (e) {
      missing.add(
        MissingStep(
          id: TunnelSetupStep.config,
          message: 'the tunnel config is invalid: ${e.message}',
        ),
      );
    }
    if (config == null &&
        !missing.any((step) => step.id == TunnelSetupStep.config)) {
      missing.add(
        const MissingStep(
          id: TunnelSetupStep.config,
          message: 'the app-owned config is missing: write ~/.config/opencodebridge/cloudflared.yml',
        ),
      );
    }
    if (config != null &&
        (config.serviceHost != '127.0.0.1' ||
            config.servicePort != bridgePort)) {
      missing.add(
        MissingStep(
          id: TunnelSetupStep.config,
          message:
              'the config routes to ${config.serviceHost}:${config.servicePort}; '
              'the bridge listens on 127.0.0.1:$bridgePort',
        ),
      );
    }
    if (config != null && !_credentialsMet(config.credentialsFile)) {
      missing.add(
        MissingStep(
          id: TunnelSetupStep.credentials,
          message:
              'the tunnel credentials are missing or invalid: '
              '${config.credentialsFile}',
        ),
      );
    }
    try {
      await binary.ensure();
    } catch (e) {
      missing.add(
        MissingStep(
          id: TunnelSetupStep.binary,
          message: 'the cloudflared binary could not be installed: $e',
        ),
      );
    }
    if (config != null) {
      final hostname = config.hostname;
      var resolves = false;
      try {
        resolves = await _dnsResolves(hostname);
      } catch (_) {
        resolves = false;
      }
      if (!resolves) {
        missing.add(
          MissingStep(
            id: TunnelSetupStep.dnsRoute,
            message:
                'the DNS route is missing: $hostname does not resolve '
                '(route it to the tunnel)',
          ),
        );
      } else {
        var verdict = AccessVerdict.unreachable;
        try {
          verdict = await _accessProbe(hostname);
        } catch (_) {
          verdict = AccessVerdict.unreachable;
        }
        if (verdict != AccessVerdict.enforcing) {
          missing.add(
            MissingStep(
              id: TunnelSetupStep.access,
              message: verdict == AccessVerdict.open
                  ? 'Cloudflare Access is not enforcing on https://$hostname: '
                        'the tunnel would be open to the internet'
                  : 'https://$hostname is not reachable (create the Access '
                        'application for the hostname)',
            ),
          );
        }
      }
    }
    return PreconditionResult(missing: missing, config: config);
  }

  /// The credentials file exists and carries a `TunnelID`.
  bool _credentialsMet(String credentialsFile) {
    final file = File(_expandHome(credentialsFile));
    if (!file.existsSync()) return false;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map<String, Object?> &&
          (decoded['TunnelID'] as String? ?? '').isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Expands a leading `~` to the home directory: cloudflared itself
  /// expands `~` in `credentials-file`, so the checker probes the same
  /// path (issue #34).
  static String _expandHome(String path) {
    if (path == '~') return homeDirectory();
    if (!path.startsWith('~/')) return path;
    final rest = path.substring(2);
    final home = homeDirectory();
    return home == '/' ? '/$rest' : '$home/$rest';
  }
}

/// The default [DnsResolver]: the hostname resolves to at least one
/// address.
Future<bool> _hostDnsResolves(String hostname) async {
  try {
    final addresses = await InternetAddress.lookup(hostname);
    return addresses.isNotEmpty;
  } catch (_) {
    return false;
  }
}
