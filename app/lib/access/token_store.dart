import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The persisted Cloudflare Access login for one tunnel host (issue #23):
/// the dynamically registered client and the opaque token pair, so a
/// restart within the grant session does not force a re-login.
class AccessLoginRecord {
  const AccessLoginRecord({
    required this.clientId,
    required this.accessToken,
    required this.refreshToken,
    required this.accessTokenExpiresAt,
  });

  /// The client id from the dynamic registration (RFC 8707).
  final String clientId;

  final String accessToken;

  /// `null` when the token endpoint did not grant one (then the login ends
  /// with the access token's expiry, not the grant session's).
  final String? refreshToken;

  final DateTime accessTokenExpiresAt;

  Map<String, Object?> toJson() => {
    'version': 1,
    'clientId': clientId,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'accessTokenExpiresAt': accessTokenExpiresAt.millisecondsSinceEpoch,
  };

  static AccessLoginRecord? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    if (raw['version'] != 1) return null;
    final clientId = raw['clientId'];
    final accessToken = raw['accessToken'];
    final expiresAt = raw['accessTokenExpiresAt'];
    if (clientId is! String || accessToken is! String) return null;
    if (expiresAt is! int) return null;
    final refreshToken = raw['refreshToken'];
    return AccessLoginRecord(
      clientId: clientId,
      accessToken: accessToken,
      refreshToken: refreshToken is String ? refreshToken : null,
      accessTokenExpiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt),
    );
  }
}

/// Persists the Access login records, one per tunnel host, in
/// [SharedPreferences] (the same store as the rest of the client settings).
class AccessTokenStore {
  AccessTokenStore(this._prefs);

  static const String _keyPrefix = 'access.login.';

  final SharedPreferences _prefs;

  /// Loads the store from the platform [SharedPreferences].
  static Future<AccessTokenStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AccessTokenStore(prefs);
  }

  /// The login for [tunnelHost], or `null` when this host is not logged in.
  AccessLoginRecord? recordFor(String tunnelHost) {
    final raw = _prefs.getString(_keyFor(tunnelHost));
    if (raw == null) return null;
    return AccessLoginRecord.fromJson(jsonDecode(raw));
  }

  void save(String tunnelHost, AccessLoginRecord record) =>
      _prefs.setString(_keyFor(tunnelHost), jsonEncode(record.toJson()));

  void delete(String tunnelHost) => _prefs.remove(_keyFor(tunnelHost));

  static String _keyFor(String tunnelHost) => '$_keyPrefix$tunnelHost';
}
