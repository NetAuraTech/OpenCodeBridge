import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/app_mode.dart';
import 'package:opencodebridge/client/connection_monitor.dart';
import 'package:opencodebridge/settings/app_settings.dart';
import 'package:opencodebridge/ui/home_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('HomeShell', () {
    testWidgets('shows the 3-tab IA with Sessions default', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      final monitor = ConnectionMonitor(probe: (Uri uri) async => false);
      monitor.connect(() => Uri.parse('http://127.0.0.1:1/api/health'));

      await tester.pumpWidget(
        MaterialApp(
          home: HomeShell(
            monitor: monitor,
            settings: settings,
            mode: AppMode.client,
          ),
        ),
      );
      await tester.pump();

      // The three tab labels.
      expect(find.text('Sessions'), findsWidgets);
      expect(find.text('Docker'), findsWidgets);
      expect(find.text('Settings'), findsWidgets);

      // The Sessions tab is the default body; without a tunnel URL it
      // points at Settings.
      expect(
        find.text('No bridge configured. Set the tunnel URL in Settings.'),
        findsOneWidget,
      );

      // Switch to the Docker tab; without a tunnel URL it points at
      // Settings like the Sessions tab does.
      await tester.tap(find.text('Docker').last);
      await tester.pump();
      expect(
        find.text('No bridge configured. Set the tunnel URL in Settings.'),
        findsOneWidget,
      );

      // Switch to the Settings tab.
      await tester.tap(find.text('Settings').last);
      await tester.pump();
      expect(find.text('Notifications'), findsOneWidget);

      monitor.dispose();
    });
  });
}
