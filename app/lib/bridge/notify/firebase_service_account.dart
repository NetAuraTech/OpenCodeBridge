import 'dart:convert';
import 'dart:io';

import '../sessions/paths.dart';

/// The bridge's Firebase service account (issue #24, the setup step): the
/// JSON file the Firebase Console download, app-owned at
/// `~/.config/opencodebridge/firebase/service-account.json`, overridable
/// with an explicit path or the `GOOGLE_APPLICATION_CREDENTIALS`
/// environment variable (Google's standard, shared with the Admin SDK's
/// own discovery).
class FirebaseServiceAccount {
  const FirebaseServiceAccount({
    required this.rawJson,
    required this.projectId,
    required this.email,
    required this.privateKey,
  });

  /// The file's raw JSON, kept whole: the fallback sender (issue #24)
  /// feeds it to `googleapis_auth`' `ServiceAccountCredentials.fromJson`,
  /// which needs fields the parsed view does not carry (`type`,
  /// `client_id`).
  final String rawJson;

  /// The Firebase project id (`project_id`).
  final String projectId;

  /// The service account's email (`client_email`).
  final String email;

  /// The PEM-encoded private key (`private_key`).
  final String privateKey;

  /// The environment variable naming an alternative credential file.
  static const String envVar = 'GOOGLE_APPLICATION_CREDENTIALS';

  /// The app-owned default path.
  static String defaultPath() =>
      '${homeDirectory()}/.config/opencodebridge/firebase/service-account.json';

  /// The credential file path: [explicitPath] (tests, a future setup
  /// wizard), else the `GOOGLE_APPLICATION_CREDENTIALS` environment
  /// variable, else the app-owned default.
  static String resolvePath({
    String? explicitPath,
    Map<String, String>? environment,
  }) {
    final env = environment ?? Platform.environment;
    return explicitPath ?? env[envVar] ?? defaultPath();
  }

  /// Loads the service account at [path], or `null` when the file is
  /// missing or not a valid service account JSON. A `null` result leaves
  /// push disabled (the setup step not done) without affecting the rest of
  /// the bridge.
  static FirebaseServiceAccount? tryLoad({String? path}) {
    final file = File(path ?? resolvePath());
    if (!file.existsSync()) return null;
    try {
      return fromJsonString(file.readAsStringSync());
    } catch (_) {
      return null;
    }
  }

  /// Parses one service account JSON, or `null` when it is not one.
  static FirebaseServiceAccount? fromJsonString(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    final projectId = decoded['project_id'];
    final email = decoded['client_email'];
    final privateKey = decoded['private_key'];
    if (projectId is! String || projectId.isEmpty) return null;
    if (email is! String || email.isEmpty) return null;
    if (privateKey is! String || privateKey.isEmpty) return null;
    return FirebaseServiceAccount(
      rawJson: raw,
      projectId: projectId,
      email: email,
      privateKey: privateKey,
    );
  }
}
