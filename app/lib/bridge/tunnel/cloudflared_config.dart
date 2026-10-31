import 'dart:io';

import 'package:yaml/yaml.dart';

import '../sessions/paths.dart';

/// The app-owned tunnel config, `~/.config/opencodebridge/cloudflared.yml`
/// (ADR-0002): written by the user once during the guided setup, spawned
/// with `--config`, isolated from the default cloudflared paths. The app
/// verifies it at server-mode start and on every recheck.
class CloudflaredConfigFile {
  CloudflaredConfigFile({File? file})
    : file = file ?? CloudflaredConfigFile.host();

  /// The app-owned config file.
  final File file;

  /// The host path: `~/.config/opencodebridge/cloudflared.yml`.
  static File host() =>
      File('${homeDirectory()}/.config/opencodebridge/cloudflared.yml');

  /// The parsed config, or `null` when the file is missing.
  ///
  /// [CloudflaredConfigError] when the file exists but is not a valid
  /// tunnel config.
  ParsedCloudflaredConfig? read() {
    if (!file.existsSync()) return null;
    return ParsedCloudflaredConfig.parse(file.readAsStringSync());
  }
}

/// One parsed app-owned tunnel config.
class ParsedCloudflaredConfig {
  const ParsedCloudflaredConfig({
    required this.tunnel,
    required this.credentialsFile,
    required this.hostname,
    required this.serviceHost,
    required this.servicePort,
  });

  /// The `tunnel:` field: the tunnel name or uuid passed to `tunnel run`.
  final String tunnel;

  /// The `credentials-file:` field: `~/.cloudflared/<uuid>.json`.
  final String credentialsFile;

  /// The ingress hostname: the DNS name routed to the tunnel.
  final String hostname;

  /// The ingress service host (expected `127.0.0.1`).
  final String serviceHost;

  /// The ingress service port (expected the bridge port).
  final int servicePort;

  /// Parse the YAML source.
  ///
  /// Throws [CloudflaredConfigError] when the source is not a valid tunnel
  /// config (missing `tunnel`, `credentials-file`, or a `hostname` +
  /// `service` ingress entry).
  factory ParsedCloudflaredConfig.parse(String source) {
    final Object? doc;
    try {
      doc = loadYaml(source);
    } catch (_) {
      throw const CloudflaredConfigError('not valid YAML');
    }
    final map = doc is Map
        ? doc
        : throw const CloudflaredConfigError('not a mapping');
    final tunnel = map['tunnel'];
    if (tunnel is! String || tunnel.trim().isEmpty) {
      throw const CloudflaredConfigError('missing tunnel');
    }
    final credentialsFile = map['credentials-file'];
    if (credentialsFile is! String || credentialsFile.trim().isEmpty) {
      throw const CloudflaredConfigError('missing credentials-file');
    }
    final ingress = map['ingress'];
    if (ingress is! List) {
      throw const CloudflaredConfigError('missing ingress');
    }
    for (final entry in ingress) {
      if (entry is! Map) continue;
      final hostname = entry['hostname'];
      final service = entry['service'];
      if (hostname is! String || hostname.trim().isEmpty) continue;
      if (service is! String) continue;
      final uri = Uri.tryParse(service);
      if (uri == null || !uri.hasPort) {
        throw CloudflaredConfigError('bad service "$service"');
      }
      return ParsedCloudflaredConfig(
        tunnel: tunnel.trim(),
        credentialsFile: credentialsFile.trim(),
        hostname: hostname.trim(),
        serviceHost: uri.host,
        servicePort: uri.port,
      );
    }
    throw const CloudflaredConfigError(
      'no ingress entry with a hostname and a service',
    );
  }
}

/// The app-owned config exists but is not a valid tunnel config.
class CloudflaredConfigError implements Exception {
  const CloudflaredConfigError(this.message);

  final String message;

  @override
  String toString() => 'CloudflaredConfigError: $message';
}
