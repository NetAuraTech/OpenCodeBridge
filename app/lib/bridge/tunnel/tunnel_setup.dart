import 'dart:convert';
import 'dart:io';

import '../../model/tunnel_setup.dart';
import '../sessions/paths.dart';
import 'cloudflared_config.dart';
import 'tunnel_supervisor.dart';

/// The assisted tunnel setup (issue #34, ADR-0003): the bridge, the sole
/// file owner, writes the app-owned tunnel files from the wizard's input —
/// the pasted credentials verbatim, and the generated config the user never
/// writes — then re-runs the precondition pass and, when every step is met,
/// (re)starts the tunnel child. Idempotent: re-running overwrites the
/// app-owned files with the same result.
class TunnelSetup {
  TunnelSetup({
    required this.supervisor,
    required this.bridgePort,
    this._credentialsDir,
    CloudflaredConfigFile? configFile,
  }) : _configFile = configFile ?? CloudflaredConfigFile();

  /// The tunnel supervisor the fresh files feed (its precondition pass and
  /// its child).
  final TunnelSupervisor supervisor;

  /// The port the bridge listens on: the generated config's ingress
  /// service points at it.
  final int bridgePort;

  final Directory? _credentialsDir;
  final CloudflaredConfigFile _configFile;

  /// The credentials directory: `~/.cloudflared` (the default
  /// cloudflared credentials path), overridable for tests.
  Directory get _credentialsDirEffective =>
      _credentialsDir ?? Directory('${homeDirectory()}/.cloudflared');

  /// The payload of `POST /api/tunnel/setup`: the JSON body
  /// `{"tunnel": "<name>", "hostname": "<host>", "credentials": "<json>"}`.
  ///
  /// [TunnelSetupError] on an invalid payload (the files are not touched);
  /// [TunnelSetupWriteError] when the app-owned files cannot be written.
  Future<void> apply(String body) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const TunnelSetupError('the setup payload is not valid JSON');
    }
    final payload = decoded is Map<String, Object?>
        ? decoded
        : throw const TunnelSetupError(
            'the setup payload is not a JSON object',
          );
    final tunnel = normalizeTunnelName(
      payload['tunnel'] is String ? payload['tunnel'] as String : null,
    );
    final hostname = normalizeHostname(
      payload['hostname'] is String ? payload['hostname'] as String : null,
    );
    final credentialsSource = payload['credentials'];
    final credentials = TunnelCredentials.parse(
      credentialsSource is String ? credentialsSource : null,
    );

    await _writeFiles(
      tunnel: tunnel,
      hostname: hostname,
      credentials: credentials,
    );
    await supervisor.applySetup();
  }

  /// Writes the two app-owned files (issue #34): the pasted credentials
  /// verbatim at `~/.cloudflared/<uuid>.json`, and the generated config at
  /// `~/.config/opencodebridge/cloudflared.yml`.
  Future<void> _writeFiles({
    required String tunnel,
    required String hostname,
    required TunnelCredentials credentials,
  }) async {
    try {
      final credentialsDir = _credentialsDirEffective;
      await credentialsDir.create(recursive: true);
      final credentialsFile = File(
        '${credentialsDir.path}/${credentials.tunnelId}.json',
      );
      await credentialsFile.writeAsString(credentials.source);
      await _configFile.file.parent.create(recursive: true);
      await _configFile.file.writeAsString(
        TunnelSetup.renderConfig(
          tunnel: tunnel,
          // The path the credentials were actually written to: the checker
          // probes it, and cloudflared resolves absolute and `~` paths alike.
          credentialsFile: credentialsFile.path,
          hostname: hostname,
          bridgePort: bridgePort,
        ),
      );
    } catch (e) {
      throw TunnelSetupWriteError('the tunnel files could not be written: $e');
    }
  }

  /// The generated app-owned config (issue #34): the user never writes
  /// YAML. The ingress routes the public hostname to the bridge's loopback
  /// port, after the catch-all cloudflared requires.
  static String renderConfig({
    required String tunnel,
    required String credentialsFile,
    required String hostname,
    required int bridgePort,
  }) =>
      'tunnel: $tunnel\n'
      'credentials-file: $credentialsFile\n'
      'ingress:\n'
      '  - hostname: $hostname\n'
      '    service: http://127.0.0.1:$bridgePort\n'
      '  - service: http_status:404\n';
}
