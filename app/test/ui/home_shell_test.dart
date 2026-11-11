import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/app_mode.dart';
import 'package:opencodebridge/client/connection_monitor.dart';
import 'package:opencodebridge/notify/notification_service.dart';
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

    testWidgets('remounts with the same notification service deep-link stream '
        'without crashing', (tester) async {
      // The bug seen on a real device (the red screen after the Cloudflare
      // Access login): the shell's deep-link stream came from the
      // NotificationService, and a remounted shell (a rebuild that
      // unmounts and re-inflates the HomeShell) re-listens the same stream
      // object in `initState`. The stream must be re-listenable, or the
      // second `listen` throws `Bad state: Stream has already been listened
      // to.` and the whole tree is replaced by the red error screen.
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      final monitor = ConnectionMonitor(probe: (Uri uri) async => false);
      monitor.connect(() => Uri.parse('http://127.0.0.1:1/api/health'));
      // A real service (no `start()`, so no FCM / no timers) whose
      // `deepLinks` is the stream the shell listens to.
      final notifications = NotificationService(
        settings: settings,
        bridgeBase: Uri.parse('http://127.0.0.1:1/'),
      );

      Widget pumpShell() => MaterialApp(
        home: HomeShell(
          monitor: monitor,
          settings: settings,
          mode: AppMode.client,
          deepLinks: notifications.deepLinks,
        ),
      );

      // First mount: the shell subscribes.
      await tester.pumpWidget(pumpShell());
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Sessions'), findsWidgets);

      // Unmount, then remount the shell with the very same stream object
      // (the service is still in hand). Without the re-listenable stream
      // this throws and the tree is replaced by the red error screen.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(pumpShell());
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Sessions'), findsWidgets);

      await tester.pumpWidget(const SizedBox());
      monitor.dispose();
    });
  });
}
