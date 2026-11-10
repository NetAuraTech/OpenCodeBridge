import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_mode.dart';

/// Persisted app settings, backed by [SharedPreferences].
///
/// The scaffold persists: the last launch mode (so it is preselected at the
/// next desktop launch), the client-mode tunnel URL, the theme choice
/// (issue #49), the sessions sidebar's collapsed choice (issue #132), and
/// the three push-event toggles (which become live with the push ticket).
class AppSettings {
  AppSettings._(this._prefs);

  /// Preference key for the last launch mode. Exposed so tests can seed it.
  static const String keyLastMode = 'app.lastMode';
  static const String keyThemeMode = 'app.themeMode';
  static const String _keyTunnelUrl = 'host.tunnelUrl';
  static const String _keySidebarCollapsed = 'sessions.sidebarCollapsed';
  static const String _keyNotifyPermission = 'notify.permissionAsked';
  static const String _keyNotifyTurnEnded = 'notify.turnEnded';
  static const String _keyNotifyDocker = 'notify.dockerContainer';
  static const String _keyFirebaseProject = 'notify.firebaseProject';

  final SharedPreferences _prefs;

  /// Loads settings from the platform [SharedPreferences] store.
  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings._(prefs);
  }

  /// The mode selected at the previous desktop launch, for preselection.
  AppMode? get lastMode {
    final value = _prefs.getString(keyLastMode);
    if (value == null) return null;
    return AppMode.values.byName(value);
  }

  set lastMode(AppMode? mode) {
    if (mode == null) {
      _prefs.remove(keyLastMode);
    } else {
      _prefs.setString(keyLastMode, mode.name);
    }
  }

  /// The app's theme (issue #49): Light, Dark, or System (follow the OS).
  /// Persisted like the other settings and restored at the next launch;
  /// until the user chooses, the app stays Light as it always has.
  ThemeMode get themeMode {
    final value = _prefs.getString(keyThemeMode) ?? 'light';
    return ThemeMode.values.byName(value);
  }

  set themeMode(ThemeMode mode) => _prefs.setString(keyThemeMode, mode.name);

  /// The sessions sidebar's collapsed choice (issue #132): persisted like the
  /// other settings and restored at the next launch; until the user toggles
  /// it, the sidebar starts expanded as it always has.
  bool get sessionsSidebarCollapsed =>
      _prefs.getBool(_keySidebarCollapsed) ?? false;

  set sessionsSidebarCollapsed(bool collapsed) =>
      _prefs.setBool(_keySidebarCollapsed, collapsed);

  /// The tunnel URL the client mode connects to (spec: Settings).
  String get tunnelUrl => _prefs.getString(_keyTunnelUrl) ?? '';

  set tunnelUrl(String url) => _prefs.setString(_keyTunnelUrl, url);

  /// Push toggle: permission requested.
  bool get notifyPermissionAsked =>
      _prefs.getBool(_keyNotifyPermission) ?? false;

  set notifyPermissionAsked(bool value) =>
      _prefs.setBool(_keyNotifyPermission, value);

  /// Push toggle: turn ended (success or error).
  bool get notifyTurnEnded => _prefs.getBool(_keyNotifyTurnEnded) ?? false;

  set notifyTurnEnded(bool value) => _prefs.setBool(_keyNotifyTurnEnded, value);

  /// Push toggle: docker container stopped or crashed.
  bool get notifyDockerContainer => _prefs.getBool(_keyNotifyDocker) ?? false;

  set notifyDockerContainer(bool value) =>
      _prefs.setBool(_keyNotifyDocker, value);

  /// The Firebase project's `google-services.json` (issue #24, pasted in
  /// Settings): the FCM token's setup step. `''` when not set yet.
  String get firebaseProjectJson => _prefs.getString(_keyFirebaseProject) ?? '';

  set firebaseProjectJson(String json) {
    if (json.trim().isEmpty) {
      _prefs.remove(_keyFirebaseProject);
    } else {
      _prefs.setString(_keyFirebaseProject, json);
    }
  }
}
