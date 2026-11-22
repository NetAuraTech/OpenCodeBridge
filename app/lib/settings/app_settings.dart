import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_mode.dart';
import '../bridge/afk/afk_settings.dart';

/// Persisted app settings, backed by [SharedPreferences].
///
/// The scaffold persists: the last launch mode (so it is preselected at the
/// next desktop launch), the client-mode tunnel URL, the theme choice
/// (issue #49), the sessions sidebar's collapsed choice (issue #132), the
/// push-event toggles (which become live with the push ticket), and the
/// AFK agent's settings (spec #407, T1: the per-repo arming set, the
/// parallel-orbs cap, and the model).
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
  static const String _keyNotifyAfkRun = 'notify.afkRun';
  static const String _keyFirebaseProject = 'notify.firebaseProject';
  static const String _keySoundEvents = 'sound.events';
  static const String _keyAfkArmedRepos = 'afk.armedRepos';
  static const String _keyAfkParallelOrbs = 'afk.parallelOrbs';
  static const String _keyAfkModel = 'afk.model';

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

  /// Push toggle: an AFK run reached one of its two "look now" moments (its
  /// PR opened, or it failed terminally — spec #376, T5). Off by default,
  /// like the other push kinds, and **distinct from the AFK arming toggle**:
  /// an armed-but-silenced system is a legitimate state (you can arm the
  /// agent and still switch off its pings while you watch the Orbs tab).
  bool get notifyAfkRun => _prefs.getBool(_keyNotifyAfkRun) ?? false;

  set notifyAfkRun(bool value) => _prefs.setBool(_keyNotifyAfkRun, value);

  /// The desktop session-sound toggle (issue #246): on by default, so a
  /// fresh install plays the sounds until the user turns them off. Desktop
  /// only — the app never plays the sounds on Android (FCM push covers
  /// those moments there), so the toggle is a no-op off desktop.
  bool get soundEvents => _prefs.getBool(_keySoundEvents) ?? true;

  set soundEvents(bool value) => _prefs.setBool(_keySoundEvents, value);

  // --- The AFK agent (spec #407, T1: per-repo arming) ----------------------
  //
  // The server-mode "AFK agent" section: the per-repo arming (the set of
  // armed `owner/repo` identities — arming itself arrives per-project in a
  // later ticket, the app persists the set here under `afk.armedRepos`), the
  // parallel-orbs cap (1–10, default 5), and the model (free text
  // `provider/model[#variant]`, empty = no pin = the service's default). All
  // persisted in this store under the `afk.` namespace and restored at
  // launch; the in-process bridge is handed them at startup and on change.
  // An empty armed set is the inert state.

  /// The AFK arming: the set of armed repo identities (`owner/repo`),
  /// persisted as a JSON list under `afk.armedRepos`. A fresh install is the
  /// empty set (inert — no polling, no feed, no admission); a corrupt or
  /// non-list value degrades to the empty set (tolerant read, never a throw).
  Set<String> get afkArmedRepos {
    final raw = _prefs.getString(_keyAfkArmedRepos);
    if (raw == null) return const {};
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const {};
    }
    if (decoded is! List) return const {};
    return decoded.whereType<String>().toSet();
  }

  set afkArmedRepos(Set<String> value) {
    if (value.isEmpty) {
      _prefs.remove(_keyAfkArmedRepos);
    } else {
      _prefs.setString(_keyAfkArmedRepos, jsonEncode(value.toList()));
    }
  }

  /// The AFK parallel-orbs cap (1–10, default 5). Validated at the bounds; a
  /// stored value outside the range degrades to the default.
  int get afkParallelOrbs {
    final value =
        _prefs.getInt(_keyAfkParallelOrbs) ?? AfkSettings.defaultParallelOrbs;
    if (value < AfkSettings.minParallelOrbs ||
        value > AfkSettings.maxParallelOrbs) {
      return AfkSettings.defaultParallelOrbs;
    }
    return value;
  }

  set afkParallelOrbs(int value) => _prefs.setInt(_keyAfkParallelOrbs, value);

  /// The AFK model: free text `provider/model[#variant]`, empty = no pin =
  /// the service's default. A blank value is stored as empty.
  String get afkModel => _prefs.getString(_keyAfkModel) ?? '';

  set afkModel(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      _prefs.remove(_keyAfkModel);
    } else {
      _prefs.setString(_keyAfkModel, trimmed);
    }
  }

  /// The AFK settings composed for the bridge (the value handed in-process at
  /// startup and on change): the per-repo arming, the cap, and the model.
  AfkSettings get afk => AfkSettings(
    armedRepos: afkArmedRepos,
    parallelOrbs: afkParallelOrbs,
    model: afkModel,
  );

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
