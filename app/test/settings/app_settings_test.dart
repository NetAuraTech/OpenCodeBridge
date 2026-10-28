import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/app_mode.dart';
import 'package:opencodebridge/settings/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('defaults: no mode yet, no tunnel url, no push enabled', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    expect(settings.lastMode, isNull);
    expect(settings.tunnelUrl, '');
    expect(settings.notifyPermissionAsked, isFalse);
    expect(settings.notifyTurnEnded, isFalse);
    expect(settings.notifyDockerContainer, isFalse);
  });

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
}
