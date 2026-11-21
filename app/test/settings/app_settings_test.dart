import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/app_mode.dart';
import 'package:opencodebridge/bridge/afk/afk_settings.dart' as afk;
import 'package:opencodebridge/settings/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'defaults: no mode yet, no tunnel url, no push enabled, sounds on',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      expect(settings.lastMode, isNull);
      expect(settings.tunnelUrl, '');
      expect(settings.notifyPermissionAsked, isFalse);
      expect(settings.notifyTurnEnded, isFalse);
      expect(settings.notifyDockerContainer, isFalse);
      // The AFK run's own push toggle (spec #376, T5) defaults off, like the
      // other push kinds.
      expect(settings.notifyAfkRun, isFalse);
      // The desktop session-sound toggle (issue #246) defaults on: a fresh
      // install plays the sounds until the user turns them off.
      expect(settings.soundEvents, isTrue);
    },
  );

  test('the AFK run push toggle (spec #376, T5) defaults off and persists, '
      'distinct from the arming toggle', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    expect(settings.notifyAfkRun, isFalse);

    settings.notifyAfkRun = true;
    final reloaded = await AppSettings.load();
    expect(reloaded.notifyAfkRun, isTrue);

    // Armed-but-silenced is legitimate: the arming toggle and the push
    // toggle are independent.
    reloaded.afkEnabled = true;
    reloaded.notifyAfkRun = false;
    final again = await AppSettings.load();
    expect(again.afkEnabled, isTrue);
    expect(again.notifyAfkRun, isFalse);
  });

  test(
    'the desktop sound toggle defaults on and persists (issue #246)',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      expect(settings.soundEvents, isTrue);

      settings.soundEvents = false;
      expect((await AppSettings.load()).soundEvents, isFalse);

      (await AppSettings.load()).soundEvents = true;
      expect((await AppSettings.load()).soundEvents, isTrue);
    },
  );

  test('persists the last mode for the next launch', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    settings.lastMode = AppMode.client;

    final reloaded = await AppSettings.load();
    expect(reloaded.lastMode, AppMode.client);
  });

  test('clears the last mode when set to null', () async {
    SharedPreferences.setMockInitialValues({AppSettings.keyLastMode: 'client'});
    final settings = await AppSettings.load();
    settings.lastMode = null;

    final reloaded = await AppSettings.load();
    expect(reloaded.lastMode, isNull);
  });

  test('persists the tunnel url', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    settings.tunnelUrl = 'https://bridge.example.com';

    final reloaded = await AppSettings.load();
    expect(reloaded.tunnelUrl, 'https://bridge.example.com');
  });

  test('persists the three notification toggles independently', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    settings.notifyPermissionAsked = true;
    settings.notifyTurnEnded = true;

    final reloaded = await AppSettings.load();
    expect(reloaded.notifyPermissionAsked, isTrue);
    expect(reloaded.notifyTurnEnded, isTrue);
    expect(reloaded.notifyDockerContainer, isFalse);

    reloaded.notifyDockerContainer = true;
    expect((await AppSettings.load()).notifyDockerContainer, isTrue);
  });

  test(
    'theme mode defaults to light (the app was light until the choice existed)',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      expect(settings.themeMode, ThemeMode.light);
    },
  );

  test('persists the theme mode for the next launch', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    settings.themeMode = ThemeMode.dark;

    final reloaded = await AppSettings.load();
    expect(reloaded.themeMode, ThemeMode.dark);

    reloaded.themeMode = ThemeMode.system;
    expect((await AppSettings.load()).themeMode, ThemeMode.system);
  });

  group('AFK agent settings (spec #376, T1)', () {
    test(
      'defaults: off, cap 5, model empty (a fresh install is inert)',
      () async {
        SharedPreferences.setMockInitialValues({});
        final settings = await AppSettings.load();
        expect(settings.afkEnabled, isFalse);
        expect(settings.afkParallelOrbs, 5);
        expect(settings.afkModel, '');
        expect(
          settings.afk,
          const afk.AfkSettings(enabled: false, parallelOrbs: 5, model: ''),
        );
      },
    );

    test(
      'each AFK setting persists across an app restart (round-trip)',
      () async {
        SharedPreferences.setMockInitialValues({});
        final settings = await AppSettings.load();
        settings.afkEnabled = true;
        settings.afkParallelOrbs = 7;
        settings.afkModel = 'zhipu/glm-4.7';

        final reloaded = await AppSettings.load();
        expect(reloaded.afkEnabled, isTrue);
        expect(reloaded.afkParallelOrbs, 7);
        expect(reloaded.afkModel, 'zhipu/glm-4.7');
      },
    );

    test('the cap persists at its bounds (1 and 10)', () async {
      SharedPreferences.setMockInitialValues({});
      (await AppSettings.load()).afkParallelOrbs = 1;
      expect((await AppSettings.load()).afkParallelOrbs, 1);

      (await AppSettings.load()).afkParallelOrbs = 10;
      expect((await AppSettings.load()).afkParallelOrbs, 10);
    });

    test(
      'a stored cap outside the bounds degrades to the default (5)',
      () async {
        SharedPreferences.setMockInitialValues({'afk.parallelOrbs': 0});
        expect((await AppSettings.load()).afkParallelOrbs, 5);

        SharedPreferences.setMockInitialValues({'afk.parallelOrbs': 11});
        expect((await AppSettings.load()).afkParallelOrbs, 5);
      },
    );

    test(
      'a blank model is stored as empty (inherit the service default)',
      () async {
        SharedPreferences.setMockInitialValues({});
        (await AppSettings.load()).afkModel = '   ';
        expect((await AppSettings.load()).afkModel, '');
      },
    );

    test('the afk value composes the bridge settings', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      settings.afkEnabled = true;
      settings.afkParallelOrbs = 3;
      settings.afkModel = 'a/b#v';
      expect(
        settings.afk,
        const afk.AfkSettings(enabled: true, parallelOrbs: 3, model: 'a/b#v'),
      );
    });
  });

  test('sessions sidebar starts expanded (issue #132)', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    expect(settings.sessionsSidebarCollapsed, isFalse);
  });

  test('persists the collapsed sessions sidebar for the next launch', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    settings.sessionsSidebarCollapsed = true;

    final reloaded = await AppSettings.load();
    expect(reloaded.sessionsSidebarCollapsed, isTrue);

    reloaded.sessionsSidebarCollapsed = false;
    expect((await AppSettings.load()).sessionsSidebarCollapsed, isFalse);
  });
}
