import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/app_mode.dart';
import 'package:opencodebridge/client/connection_monitor.dart';
import 'package:opencodebridge/settings/app_settings.dart';
import 'package:opencodebridge/ui/home_shell.dart';
import 'package:opencodebridge/ui/orbs_tab.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('HomeShell', () {
    testWidgets('shows the 4-tab IA with Sessions default', (tester) async {
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

      // The four tab labels.
      expect(find.text('Sessions'), findsWidgets);
      expect(find.text('Orbs'), findsWidgets);
      expect(find.text('Docker'), findsWidgets);
      expect(find.text('Settings'), findsWidgets);

      // The Orbs tab (issue #96) sits in the stack behind the Sessions
      // tab; the IndexedStack keeps the unselected tabs offstage, so the
      // finder looks past the Offstage.
      expect(find.byType(OrbsTab, skipOffstage: false), findsOneWidget);

      // The shell has no app bar (the "OpenCodeBridge" header was dropped):
      // the bridge status indicator moved to the footer, right of the
      // Settings item — inside the bar, vertically centred on it (the
      // 80 px bar's centre is y=560 on the 800x600 test surface, the dot's
      // centre 8 + 10 px from the right edge: the indicator is 12 px wide
      // with a 4 px side margin, positioned 8 px from the screen edge).
      expect(find.byType(AppBar), findsNothing);
      final dot = tester.getCenter(
        find.byKey(const Key('connection-indicator-dot')),
      );
      expect(dot.dy, closeTo(560, 1));
      expect(dot.dx, closeTo(782, 1));

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

      // Switch to the Settings tab. The Theme section (issue #49) grew
      // the tab, so the Notifications section sits below the fold: scroll
      // to it.
      await tester.tap(find.text('Settings').last);
      await tester.pump();
      await tester.dragUntilVisible(
        find.text('Notifications'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(find.text('Notifications'), findsOneWidget);

      monitor.dispose();
    });
  });
}
