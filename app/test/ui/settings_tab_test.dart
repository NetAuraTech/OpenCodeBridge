import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/app_info.dart';
import 'package:opencodebridge/app_mode.dart';
import 'package:opencodebridge/settings/app_settings.dart';
import 'package:opencodebridge/ui/settings_tab.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<AppSettings> pumpSettings(
    WidgetTester tester, {
    AppMode mode = AppMode.client,
    Uri? localBridgeUri,
  }) async {
    final settings = await AppSettings.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsTab(
            settings: settings,
            mode: mode,
            localBridgeUri: localBridgeUri,
          ),
        ),
      ),
    );
    await tester.pump();
    return settings;
  }

  group('SettingsTab', () {
    testWidgets('client mode: shows and persists the tunnel url', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final settings = await pumpSettings(tester, mode: AppMode.client);

      final field = find.byType(TextField);
      expect(field, findsOneWidget);

      await tester.enterText(field, 'https://bridge.example.com');
      expect(settings.tunnelUrl, 'https://bridge.example.com');
      expect(
        (await AppSettings.load()).tunnelUrl,
        'https://bridge.example.com',
      );
    });

    testWidgets('server mode: shows the local bridge, no url field', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final uri = Uri.parse('http://127.0.0.1:48201/');
      await pumpSettings(tester, mode: AppMode.server, localBridgeUri: uri);

      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('http://127.0.0.1:48201/'), findsOneWidget);
    });

    testWidgets('notification toggles persist', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = await pumpSettings(tester, mode: AppMode.client);

      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      expect(settings.notifyPermissionAsked, isTrue);
      expect(settings.notifyTurnEnded, isFalse);

      await tester.tap(find.byType(Switch).at(1));
      await tester.pump();
      expect(settings.notifyTurnEnded, isTrue);
    });

    testWidgets('shows the app version', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester, mode: AppMode.client);
      expect(find.textContaining(kAppVersion), findsOneWidget);
    });
  });
}
