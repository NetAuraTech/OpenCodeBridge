import 'dart:convert';
import 'dart:io';

import '../../model/tunnel_setup.dart';
import 'cloudflared_config.dart';
import 'tunnel_cli.dart';
import 'tunnel_supervisor.dart';

/// The assisted tunnel setup (issue #34, ADR-0003): the bridge, the sole
/// file owner, writes the app-owned tunnel files from the wizard's input —
/// the pasted credentials verbatim, or the credentials the app-driven
/// `cloudflared tunnel create` writes (issue #37), and the generated config
/// the user never writes — then re-runs the precondition pass and, when
/// every step is met, (re)starts the tunnel child. Idempotent: re-running
/// overwrites the app-owned files with the same result.
class TunnelSetup {
  TunnelSetup({
    required this.supervisor,
    required this.bridgePort,
    required this.cli,
    required this.credentialsDir,
    CloudflaredConfigFile? configFile,
  }) : _configFile = configFile ?? CloudflaredConfigFile();

  /// The tunnel supervisor the fresh files feed (its precondition pass and
  /// its child).
  final TunnelSupervisor supervisor;

  /// The port the bridge listens on: the generated config's ingress
  /// service points at it.
  final int bridgePort;

  /// The app-driven cloudflared CLI (issue #37): creates the tunnel when
  /// the wizard carries no pasted credentials.
  final TunnelCli cli;

  /// The directory cloudflared writes its credentials to: `~/.cloudflared`
  /// on the host, the injected temp directory in tests.
  final Directory credentialsDir;
  final CloudflaredConfigFile _configFile;

  /// The payload of `POST /api/tunnel/setup`: the JSON body
  /// `{"tunnel": "<name>", "hostname": "<host>", "credentials": "<json>"}`.
  /// [credentials] is optional: when absent, the bridge drives
  /// `cloudflared tunnel create <tunnel>` (the Cloudflare login is
  /// required) and uses the credentials file the CLI writes.
  ///
  /// [TunnelSetupError] on an invalid payload (the files are not touched);
  /// [TunnelSetupCreateError] when the app-driven create fails;
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
    final credentialsSource = payload['credentials'] is String
        ? payload['credentials'] as String
        : null;

    TunnelCredentials credentials;
    var fromPaste = false;
    if (credentialsSource != null && credentialsSource.trim().isNotEmpty) {
      credentials = TunnelCredentials.parse(credentialsSource);
      fromPaste = true;
    } else {
      credentials = await _createCredentials(tunnel);
    }

    await _writeFiles(
      tunnel: tunnel,
      hostname: hostname,
      credentials: credentials,
      fromPaste: fromPaste,
    );
    await supervisor.applySetup();
  }

  /// Drives `cloudflared tunnel create <tunnel>` and returns the parsed
  /// credentials of the file the CLI wrote (issue #37).
  Future<TunnelCredentials> _createCredentials(String tunnel) async {
    final dir = credentialsDir;
    final before = _credentialFiles(dir);
    final run = await cli.createTunnel(tunnel);
    if (!run.success) {
      throw TunnelSetupCreateError(
        'the tunnel could not be created: ${run.firstOutputLine.isEmpty ? "the Cloudflare login is missing or expired" : run.firstOutputLine}',
      );
    }
    final fresh = _credentialFiles(dir).difference(before).singleOrNull;
    if (fresh == null) {
      throw const TunnelSetupCreateError(
        'the tunnel create reported success but wrote no credentials file',
      );
    }
    return TunnelCredentials.parse(await File(fresh).readAsString());
  }

  /// The credentials file paths in [dir] (`<uuid>.json`), empty when the
  /// directory does not exist yet.
  Set<String> _credentialFiles(Directory dir) {
    if (!dir.existsSync()) return <String>{};
    return dir
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.path)
        .toSet();
  }

  /// Writes the app-owned files (issue #34): the pasted credentials verbatim
  /// at `~/.cloudflared/<uuid>.json` (the app-driven create already wrote
  /// it), and the generated config at `~/.config/opencodebridge/cloudflared.yml`.
  Future<void> _writeFiles({
    required String tunnel,
    required String hostname,
    required TunnelCredentials credentials,
    required bool fromPaste,
  }) async {
    try {
      final credentialsPath =
          '${credentialsDir.path}/${credentials.tunnelId}.json';
      if (fromPaste) {
        await credentialsDir.create(recursive: true);
        await File(credentialsPath).writeAsString(credentials.source);
      }
      await _configFile.file.parent.create(recursive: true);
      await _configFile.file.writeAsString(
        TunnelSetup.renderConfig(
          tunnel: tunnel,
          // The path the credentials live at: the checker probes it, and
          // cloudflared resolves absolute and `~` paths alike.
          credentialsFile: credentialsPath,
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
