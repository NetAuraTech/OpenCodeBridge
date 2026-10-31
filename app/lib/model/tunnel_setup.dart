import 'dart:convert';

/// The app-side and bridge-side validation of the assisted tunnel setup
/// (issue #34): the three wizard inputs (tunnel name, public hostname,
/// credentials JSON) and the parsed credentials.
///
/// The app validates the inputs before the round trip (clear error
/// messages in the wizard); the bridge validates them again at
/// `POST /api/tunnel/setup` (it is the sole file owner, ADR-0003).

/// An invalid assisted-setup input, with the message shown to the user
/// as-is (the wizard's error line, the bridge's 400 details).
class TunnelSetupError implements Exception {
  const TunnelSetupError(this.message);

  /// The human-readable explanation, shown as-is.
  final String message;

  @override
  String toString() => 'TunnelSetupError: $message';
}

/// The app-owned files could not be written (issue #34).
class TunnelSetupWriteError implements Exception {
  const TunnelSetupWriteError(this.message);

  /// The human-readable explanation, shown as-is.
  final String message;

  @override
  String toString() => 'TunnelSetupWriteError: $message';
}

/// The tunnel credentials: the content of the credentials file
/// `~/.cloudflared/<uuid>.json` that `cloudflared tunnel create <NAME>`
/// writes, pasted into the wizard.
class TunnelCredentials {
  const TunnelCredentials({
    required this.tunnelId,
    required this.source,
    this.ownerEmail,
    this.accountId,
  });

  /// The tunnel UUID, from `TunnelID` (lowercased 8-4-4-4-12 form).
  final String tunnelId;

  /// The pasted credentials, as trimmed: written verbatim to
  /// `~/.cloudflared/<uuid>.json` (the bridge is the sole file owner).
  final String source;

  /// `OwnerEmail` when present: the Cloudflare account email the Access
  /// application's email policy grants.
  final String? ownerEmail;

  /// `OwnerAccountID` when present: the Cloudflare account id, for the
  /// dashboard deep link.
  final String? accountId;

  /// Parse and validate the pasted credentials.
  ///
  /// [TunnelSetupError] when the source is not valid JSON, not a JSON
  /// object, carries no `TunnelID` UUID, or no API key/token.
  factory TunnelCredentials.parse(String? source) {
    if (source == null || source.trim().isEmpty) {
      throw const TunnelSetupError(
        'the credentials are missing: paste the content of the '
        '~/.cloudflared/<uuid>.json file that `cloudflared tunnel create` '
        'wrote',
      );
    }
    final trimmed = source.trim();
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      throw const TunnelSetupError('the credentials are not valid JSON');
    }
    final map = decoded is Map<String, Object?>
        ? decoded
        : throw const TunnelSetupError(
            'the credentials are not a JSON object',
          );
    final tunnelId = map['TunnelID'];
    if (tunnelId is! String || tunnelId.trim().isEmpty) {
      throw const TunnelSetupError('the credentials carry no TunnelID');
    }
    if (!TunnelCredentials._uuid.hasMatch(tunnelId.trim())) {
      throw TunnelSetupError(
        'the TunnelID in the credentials is not a UUID: ${tunnelId.trim()}',
      );
    }
    if (!_hasToken(map)) {
      throw const TunnelSetupError(
        'the credentials carry no API key or token (expected a non-empty '
        'APIKey or APIToken field)',
      );
    }
    return TunnelCredentials(
      tunnelId: tunnelId.trim().toLowerCase(),
      source: trimmed,
      ownerEmail: _stringOrEmpty(map['OwnerEmail']),
      accountId: _stringOrEmpty(map['OwnerAccountID']),
    );
  }

  static final RegExp _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  static bool _hasToken(Map<String, Object?> map) {
    for (final field in ['APIKey', 'APIToken', 'AccessToken']) {
      final value = map[field];
      if (value is String && value.trim().isNotEmpty) return true;
    }
    return false;
  }

  static String? _stringOrEmpty(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;
}

final RegExp _kTunnelName = RegExp(r'^[A-Za-z0-9._-]{1,63}$');

final RegExp _kHostname = RegExp(
  r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$',
);

/// Normalize the wizard's tunnel name (issue #34): the name chosen at
/// `cloudflared tunnel create <NAME>`.
///
/// [TunnelSetupError] when it is missing or not a valid tunnel name
/// (letters, digits, dots, dashes, underscores; 1–63 characters).
String normalizeTunnelName(String? value) {
  if (value == null || value.trim().isEmpty) {
    throw const TunnelSetupError('the tunnel name is missing');
  }
  final name = value.trim();
  if (!_kTunnelName.hasMatch(name)) {
    throw TunnelSetupError(
      'the tunnel name is invalid: "$name" (letters, digits, dots, dashes, '
      'and underscores, up to 63 characters)',
    );
  }
  return name;
}

/// Normalize the wizard's public hostname (issue #34): the ingress
/// hostname, e.g. `bridge.example.com`.
///
/// [TunnelSetupError] when it is missing or not a DNS hostname (lowercased
/// on success).
String normalizeHostname(String? value) {
  if (value == null || value.trim().isEmpty) {
    throw const TunnelSetupError('the public hostname is missing');
  }
  final host = value.trim().toLowerCase();
  if (!_kHostname.hasMatch(host)) {
    throw TunnelSetupError(
      'the public hostname is invalid: "$value" (expected a DNS hostname '
      'like bridge.example.com)',
    );
  }
  return host;
}

/// The CNAME target of the tunnel's DNS route (issue #34): the public
/// hostname routes to `<tunnel-uuid>.cfargotunnel.com`.
String cfargotunnelTarget(String tunnelId) =>
    '${tunnelId.toLowerCase()}.cfargotunnel.com';

/// The exact DNS route to create in the dashboard (issue #34), as the
/// wizard displays it: `<hostname> → <tunnel-uuid>.cfargotunnel.com`.
String dnsCnameLine(String hostname, String tunnelId) =>
    '$hostname → ${cfargotunnelTarget(tunnelId)}';

/// The Access application spec to create in the dashboard for [hostname]
/// (issue #34): a self-hosted app with an email policy. When the
/// credentials carry the account email ([ownerEmail]), the policy grants
/// it; otherwise the user grants their own Cloudflare account email.
String accessAppSpec(String hostname, {String? ownerEmail}) =>
    'Self-hosted app for https://$hostname with an email policy '
    '${ownerEmail == null ? "for your Cloudflare account" : "allowing $ownerEmail"}';

/// The Cloudflare dashboard deep link for a manual setup step (issue
/// #34): the account-scoped short form (e.g.
/// `https://dash.cloudflare.com/<accountId>/dns/records`), the dashboard
/// root when the credentials carry no account id.
String dashboardDeepLink(String path, {String? accountId}) =>
    accountId == null
        ? 'https://dash.cloudflare.com/'
        : 'https://dash.cloudflare.com/$accountId/$path';
