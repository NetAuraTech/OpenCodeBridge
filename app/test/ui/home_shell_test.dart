import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:opencodebridge/app_mode.dart';
import 'package:opencodebridge/client/connection_monitor.dart';
import 'package:opencodebridge/notify/deep_link.dart';
import 'package:opencodebridge/notify/notification_service.dart';
import 'package:opencodebridge/settings/app_settings.dart';
import 'package:opencodebridge/ui/deep_link_target.dart';
import 'package:opencodebridge/ui/home_shell.dart';
import 'package:opencodebridge/ui/orbs_tab.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app's deep-link wiring (issue #287), as a widget: the app holds a
/// [DeepLinkTarget] (the stable owner) and feeds it from the service's
/// tapped-link stream (`deepLinks.listen(target.apply)`), cancelling the
/// feed on dispose. Owned by a widget (not the test body) because a
/// test-body subscription to the service's live broadcast stream trips the
/// `flutter_test` harness at teardown; the original stream-subscribing shell
/// owned its subscription the same way.
class _FeedWiring extends StatefulWidget {
  const _FeedWiring({
    required this.service,
    required this.target,
    required this.child,
  });

  final NotificationService service;
  final DeepLinkTarget target;
  final Widget child;

  @override
  State<_FeedWiring> createState() => _FeedWiringState();
}

class _FeedWiringState extends State<_FeedWiring> {
  StreamSubscription<DeepLink>? _feed;

  @override
  void initState() {
    super.initState();
    _feed = widget.service.deepLinks.listen(widget.target.apply);
  }

  @override
  void dispose() {
    _feed?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

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

    testWidgets('remounts with the same notification service deep-link '
        'target without crashing', (tester) async {
      // The bug seen on a real device (the red screen after the Cloudflare
      // Access login): the shell's deep-link stream came from the
      // NotificationService, and a remounted shell (a rebuild that
      // unmounts and re-inflates the HomeShell) re-listened the same stream
      // object in `initState`. The stream had to be re-listenable, or the
      // second `listen` threw `Bad state: Stream has already been listened
      // to.` and the whole tree was replaced by the red error screen.
      // (issue #287) The one-shot now lives on a [DeepLinkTarget] the app
      // holds across remounts: the shell re-reads the model on the mount
      // and re-attaches to it — a re-attach can never throw.
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      final monitor = ConnectionMonitor(probe: (Uri uri) async => false);
      monitor.connect(() => Uri.parse('http://127.0.0.1:1/api/health'));
      // A real service (no `start()`, so no FCM / no timers) whose tapped
      // links feed the model, as the app wires it.
      final notifications = NotificationService(
        settings: settings,
        bridgeBase: Uri.parse('http://127.0.0.1:1/'),
      );
      final deepLinks = DeepLinkTarget();

      Widget pumpShell() => MaterialApp(
        home: _FeedWiring(
          service: notifications,
          target: deepLinks,
          child: HomeShell(
            monitor: monitor,
            settings: settings,
            mode: AppMode.client,
            deepLinks: deepLinks,
          ),
        ),
      );

      // First mount: the shell attaches to the model.
      await tester.pumpWidget(pumpShell());
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Sessions'), findsWidgets);

      // Unmount, then remount the shell with the very same model (the
      // service is still in hand). Without the stable owner this was the
      // red error screen.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(pumpShell());
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Sessions'), findsWidgets);

      await tester.pumpWidget(const SizedBox());
      monitor.dispose();
    });

    testWidgets('an external deep link opens the URL in the browser and '
        'clears the one-shot (spec #376, T5)', (tester) async {
      // The AFK run's PR push deep-links to the PR's GitHub URL — an external
      // link opened in the browser, not a tab. The shell (the deep-link
      // target's tab-switching owner) hands the URL to the injected opener
      // and clears the one-shot so a later identical link is a new event.
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      final monitor = ConnectionMonitor(probe: (Uri uri) async => false);
      monitor.connect(() => Uri.parse('http://127.0.0.1:1/api/health'));
      final deepLinks = DeepLinkTarget();
      final opened = <Uri>[];

      await tester.pumpWidget(
        MaterialApp(
          home: HomeShell(
            monitor: monitor,
            settings: settings,
            mode: AppMode.client,
            deepLinks: deepLinks,
            onExternalOpen: (url) async => opened.add(url),
          ),
        ),
      );
      await tester.pump();

      // No target yet: nothing opened.
      expect(opened, isEmpty);

      // A tapped PR push: an external link (the PR's GitHub URL).
      const pr = 'https://github.com/o/r/pull/41';
      deepLinks.apply(DeepLink.external(pr));
      await tester.pump();

      // The URL was handed to the external opener, and the one-shot is
      // cleared (so a later identical link is a new event).
      expect(opened, [Uri.parse(pr)]);
      expect(deepLinks.target, isNull);

      await tester.pumpWidget(const SizedBox());
      monitor.dispose();
    });

    testWidgets('an external deep link without an opener is ignored (no '
        'throw)', (tester) async {
      // No external opener wired (a build path without one): the external
      // target is still consumed, but the open is a no-op.
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      final monitor = ConnectionMonitor(probe: (Uri uri) async => false);
      monitor.connect(() => Uri.parse('http://127.0.0.1:1/api/health'));
      final deepLinks = DeepLinkTarget();

      await tester.pumpWidget(
        MaterialApp(
          home: HomeShell(
            monitor: monitor,
            settings: settings,
            mode: AppMode.client,
            deepLinks: deepLinks,
          ),
        ),
      );
      await tester.pump();

      deepLinks.apply(DeepLink.external('https://github.com/o/r/pull/41'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(deepLinks.target, isNull);

      await tester.pumpWidget(const SizedBox());
      monitor.dispose();
    });

    testWidgets('a deep link survives a shell remount with the same '
        'service', (tester) async {
      // The one-shot lives on a [DeepLinkTarget] the app holds across
      // remounts (issue #287): a link delivered through the service while
      // the shell is up must not be dropped when the shell is unmounted and
      // remounted with the same service — the remounted shell re-reads the
      // model (landing on the right tab) and the model still carries the
      // target for its tab to open on its next load.
      SharedPreferences.setMockInitialValues({});
      final settings = await AppSettings.load();
      final monitor = ConnectionMonitor(probe: (Uri uri) async => false);
      monitor.connect(() => Uri.parse('http://127.0.0.1:1/api/health'));
      final notifications = NotificationService(
        settings: settings,
        bridgeBase: Uri.parse('http://127.0.0.1:1/'),
      );
      final deepLinks = DeepLinkTarget();

      Widget pumpShell() => MaterialApp(
        home: _FeedWiring(
          service: notifications,
          target: deepLinks,
          child: HomeShell(
            monitor: monitor,
            settings: settings,
            mode: AppMode.client,
            deepLinks: deepLinks,
          ),
        ),
      );

      int selectedTab() => tester
          .widget<NavigationBar>(find.byType(NavigationBar))
          .selectedIndex;

      // The shell is up (the Sessions tab by default). A tapped
      // notification targeting a container is delivered through the service
      // (the feed applies it to the model, the shell switches the tab).
      await tester.pumpWidget(pumpShell());
      await tester.pump();
      expect(selectedTab(), 0);
      notifications.openForTest(
        RemoteMessage(
          data: {'link': DeepLink.containerUri('probe').toString()},
        ),
      );
      await tester.pump();
      await tester.pump();

      // The shell switched to the Docker tab for the container target, and
      // the model carries it.
      expect(selectedTab(), 2);
      expect(deepLinks.target, DeepLink.container('probe'));

      // Unmount, then remount the shell with the same service (and the
      // model the app holds with it): no dropped link, no red screen.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(pumpShell());
      await tester.pump();
      expect(tester.takeException(), isNull);

      // The remounted shell re-read the model (its tab is back on Docker)
      // and the target is still on it for the tab to open.
      expect(selectedTab(), 2);
      expect(deepLinks.target, DeepLink.container('probe'));

      await tester.pumpWidget(const SizedBox());
      monitor.dispose();
    });
  });
}
