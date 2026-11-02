import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/app.dart';
import 'package:opencodebridge/app_mode.dart';
import 'package:opencodebridge/bridge/bridge_server.dart';
import 'package:opencodebridge/settings/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('OpenCodeBridgeApp', () {
    testWidgets(
      'desktop launch shows the mode choice; client Start opens the shell',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        SharedPreferences.setMockInitialValues({});

        await tester.pumpWidget(const OpenCodeBridgeApp());
        await tester.pump(); // settings load

        // The mode choice is shown at every desktop launch.
        expect(find.text('How do you want to run?'), findsOneWidget);

        // Choose client and start: no tunnel URL yet -> disconnected shell.
        await tester.tap(find.text('Client'));
        await tester.pump();
        await tester.tap(find.text('Start'));
        await tester.pump();

        expect(find.text('Sessions'), findsWidgets);
        expect(find.text('Docker'), findsWidgets);
        expect(find.text('Settings'), findsWidgets);

        // The mode is persisted for the next launch.
        expect((await AppSettings.load()).lastMode, AppMode.client);

        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets('desktop server Start reports a port conflict, stays put', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});

      // Hold the bridge port, as a second server-mode instance would.
      late final HttpServer blocker;
      await tester.runAsync(() async {
        blocker = await HttpServer.bind('127.0.0.1', BridgeServer.defaultPort);
      });

      await tester.pumpWidget(const OpenCodeBridgeApp());
      await tester.pump(); // settings load

      // Server is the first-launch preselection; press Start directly.
      await tester.tap(find.text('Start'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();

      // The mode screen is still up, with the error, no shell.
      expect(find.text('How do you want to run?'), findsOneWidget);
      expect(find.textContaining('Could not start the bridge'), findsOneWidget);

      await tester.runAsync(() => blocker.close(force: true).then((_) {}));
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('android launches straight into client mode', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(const OpenCodeBridgeApp());
      await tester.pump(); // settings load

      expect(find.text('How do you want to run?'), findsNothing);
      expect(find.text('Sessions'), findsWidgets);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets(
      'the Settings Theme choice re-themes the app live and persists',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        SharedPreferences.setMockInitialValues({});

        await tester.pumpWidget(const OpenCodeBridgeApp());
        await tester.pump(); // settings load

        // Client mode, no tunnel URL yet -> the shell, in Light (the
        // first-launch default).
        await tester.tap(find.text('Client'));
        await tester.pump();
        await tester.tap(find.text('Start'));
        await tester.pump();

        expect(
          Theme.of(tester.element(find.text('Sessions'))).brightness,
          Brightness.light,
        );

        // Settings: the Theme section is first, with the three choices.
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('Settings'),
          ),
        );
        await tester.pump();
        expect(find.text('Light'), findsOneWidget);
        expect(find.text('Dark'), findsOneWidget);
        expect(find.text('System'), findsOneWidget);
        expect(find.text('Follow the OS'), findsOneWidget);

        // Pick Dark: the whole app re-themes live, no restart...
        await tester.tap(find.text('Dark'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          Theme.of(tester.element(find.text('Sessions'))).brightness,
          Brightness.dark,
        );
        // ...and the choice is persisted for the next launch.
        expect((await AppSettings.load()).themeMode, ThemeMode.dark);

        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets('the System theme follows the OS brightness while running', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({
        AppSettings.keyThemeMode: 'system',
      });
      addTearDown(
        () => tester.platformDispatcher.clearPlatformBrightnessTestValue(),
      );

      await tester.pumpWidget(const OpenCodeBridgeApp());
      await tester.pump(); // settings load

      await tester.tap(find.text('Client'));
      await tester.pump();
      await tester.tap(find.text('Start'));
      await tester.pump();

      // System follows the OS: light while the OS is light...
      expect(
        Theme.of(tester.element(find.text('Sessions'))).brightness,
        Brightness.light,
      );

      // ...and an OS change re-themes the running app live. The first
      // frame picks up the new brightness (the theme change starts), the
      // next advances the re-theme animation to completion.
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        Theme.of(tester.element(find.text('Sessions'))).brightness,
        Brightness.dark,
      );

      debugDefaultTargetPlatformOverride = null;
    });
  });
}
