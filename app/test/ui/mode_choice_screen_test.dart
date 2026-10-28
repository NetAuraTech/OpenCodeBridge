import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/app_mode.dart';
import 'package:opencodebridge/settings/app_settings.dart';
import 'package:opencodebridge/ui/mode_choice_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppMode? groupValue(WidgetTester tester) => tester
    .widget<RadioGroup<AppMode>>(find.byType(RadioGroup<AppMode>))
    .groupValue;

void main() {
  group('ModeChoiceScreen', () {
    testWidgets('defaults to server when no mode was chosen before', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      await tester.pumpWidget(
        MaterialApp(
          home: ModeChoiceScreen(settings: settings, onSelected: (m) {}),
        ),
      );
      expect(groupValue(tester), AppMode.server);
    });

    testWidgets('preselects the persisted mode', (tester) async {
      SharedPreferences.setMockInitialValues(const {
        AppSettings.keyLastMode: 'client',
      });
      final settings = await AppSettings.load();
      await tester.pumpWidget(
        MaterialApp(
          home: ModeChoiceScreen(settings: settings, onSelected: (m) {}),
        ),
      );
      expect(groupValue(tester), AppMode.client);
    });

    testWidgets('Start persists the chosen mode and reports it', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      AppMode? reported;
      await tester.pumpWidget(
        MaterialApp(
          home: ModeChoiceScreen(
            settings: settings,
            onSelected: (m) => reported = m,
          ),
        ),
      );

      // Switch to client, then start.
      await tester.tap(find.text('Client'));
      await tester.pump();
      await tester.tap(find.text('Start'));
      await tester.pump();

      expect(reported, AppMode.client);
      expect(settings.lastMode, AppMode.client);
      expect((await AppSettings.load()).lastMode, AppMode.client);
    });

    testWidgets('shows the server start error and keeps the screen', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      AppMode? reported;
      await tester.pumpWidget(
        MaterialApp(
          home: ModeChoiceScreen(
            settings: settings,
            onSelected: (m) => reported = m,
            error: 'port 48201 is already in use',
          ),
        ),
      );
      expect(find.text('port 48201 is already in use'), findsOneWidget);
      expect(reported, isNull);
    });
  });
}
