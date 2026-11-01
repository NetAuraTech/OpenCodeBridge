import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';

/// The Firebase project's app configuration (issue #24, the app-side setup
/// step): the `google-services.json` the Firebase Console downloads for this
/// app's Android package, which the user pastes into Settings. Parsed at
/// runtime, so one build works with any project and switching projects is a
/// Settings edit, not a rebuild.
class FirebaseProject {
  const FirebaseProject(this.options);

  /// The options the app's [Firebase.initializeApp] (via
  /// `package:firebase_core`) takes to collect the FCM token.
  final FirebaseOptions options;

  /// Parses [raw] as a `google-services.json`, or `null` when it is not one
  /// (any malformed entry leaves push unconfigured; the Settings tab shows
  /// the field as not set).
  static FirebaseProject? parse(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw.trim());
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;

    final projectInfo = decoded['project_info'];
    String? projectId;
    String? senderId;
    if (projectInfo is Map<String, Object?>) {
      projectId = _asNonEmptyString(projectInfo['project_id']);
      // `project_number` is the FCM sender id; it is a string in the
      // Console's export but normalize a numeric form too.
      senderId = _asNonEmptyString(projectInfo['project_number']);
    }

    final clients = decoded['client'];
    Map<String, Object?>? client;
    if (clients is List) {
      // The Android entry: the one that carries `android_client_info`.
      for (final entry in clients) {
        if (entry is Map<String, Object?> &&
            entry['client_info'] is Map<String, Object?> &&
            (entry['client_info']
                    as Map<String, Object?>)['android_client_info']
                is Map<String, Object?>) {
          client = entry;
          break;
        }
      }
    }
    if (client == null) return null;
    final clientInfo = client['client_info'] as Map<String, Object?>;
    final appId = clientInfo['mobilesdk_app_id'];

    Object? apiKey;
    final keys = client['api_key'];
    if (keys is List) {
      for (final entry in keys) {
        if (entry is Map<String, Object?>) {
          apiKey = entry['current_key'];
          break;
        }
      }
    }

    Object? androidClientId;
    final oauthClients = client['oauth_client'];
    if (oauthClients is List) {
      for (final entry in oauthClients) {
        if (entry is Map<String, Object?> && entry['client_type'] == 3) {
          androidClientId = entry['client_id'];
          break;
        }
      }
    }

    final appIdString = _asNonEmptyString(appId);
    final apiKeyString = _asNonEmptyString(apiKey);
    if (projectId == null) return null;
    if (senderId == null) return null;
    if (appIdString == null) return null;
    if (apiKeyString == null) return null;
    // `androidClientId` (the `client_type: 3` oauth client) is present in
    // every Console export but is optional for FCM; use it when there is one.
    return FirebaseProject(
      FirebaseOptions(
        apiKey: apiKeyString,
        appId: appIdString,
        messagingSenderId: senderId,
        projectId: projectId,
        androidClientId: _asNonEmptyString(androidClientId),
      ),
    );
  }

  /// The value as a non-empty string, or `null`; numeric values (a JSON
  /// number) are stringified.
  static String? _asNonEmptyString(Object? value) {
    if (value is String) return value.isEmpty ? null : value;
    if (value is num) return value.toString();
    return null;
  }
}
