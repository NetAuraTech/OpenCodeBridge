import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/app_info.dart';
import 'package:opencodebridge/app_mode.dart';
import 'package:opencodebridge/client/tunnel_client.dart';
import 'package:opencodebridge/model/tunnel_report.dart';
import 'package:opencodebridge/settings/app_settings.dart';
import 'package:opencodebridge/ui/settings_tab.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A scripted [TunnelClient] for the tab tests.
class FakeTunnelClient extends TunnelClient {
  FakeTunnelClient() : super(Uri.parse('http://bridge.test/'));

  TunnelReport? reportValue;
  Object? reportError;
  final List<String> actions = [];

  @override
  Future<TunnelReport> report() async {
    final error = reportError;
    if (error is Object) throw error;
    return reportValue!;
  }

  @override
  Future<TunnelReport> check() async {
    actions.add('check');
    final error = reportError;
    if (error is Object) throw error;
    return reportValue!;
  }

  @override
  Future<TunnelReport> start() async {
    actions.add('start');
    final error = reportError;
    if (error is Object) throw error;
    return reportValue!;
  }
}

const TunnelReport _kUpReport = TunnelReport(
  status: TunnelStatus.up,
  running: true,
  registeredConnections: 2,
  metricsPort: 20241,
  hostname: 'bridge.example.com',
);

const TunnelReport _kDownReport = TunnelReport(
  status: TunnelStatus.down,
  running: false,
  registeredConnections: 0,
  missing: ['config', 'dns_route'],
  missingDetails: [
    'the app-owned config is missing: write ~/.config/opencodebridge/cloudflared.yml',
    'the DNS route for bridge.example.com is not in place',
  ],
);

void main() {
  Future<AppSettings> pumpSettings(
    WidgetTester tester, {
    AppMode mode = AppMode.client,
    Uri? localBridgeUri,
    FakeTunnelClient? tunnelClient,
  }) async {
    final settings = await AppSettings.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsTab(
            settings: settings,
            mode: mode,
            localBridgeUri: localBridgeUri,
            tunnelClient: tunnelClient ?? FakeTunnelClient(),
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

  group('SettingsTab tunnel section', () {
    testWidgets('a tunnel up shows the status, the host, and the edge count', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final tunnel = FakeTunnelClient()..reportValue = _kUpReport;
      await pumpSettings(
        tester,
        mode: AppMode.server,
        localBridgeUri: Uri.parse('http://127.0.0.1:48201/'),
        tunnelClient: tunnel,
      );

      expect(find.byKey(const ValueKey('tunnel-status')), findsOneWidget);
      expect(find.text('Tunnel up'), findsOneWidget);
      expect(find.text('bridge.example.com'), findsOneWidget);
      expect(find.textContaining('2 edge connections'), findsOneWidget);
      // An up tunnel needs no actions.
      expect(find.text('Check now'), findsNothing);
      expect(find.text('Start tunnel'), findsNothing);
    });

    testWidgets('a tunnel down lists the missing steps and the actions', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final tunnel = FakeTunnelClient()..reportValue = _kDownReport;
      await pumpSettings(
        tester,
        mode: AppMode.server,
        localBridgeUri: Uri.parse('http://127.0.0.1:48201/'),
        tunnelClient: tunnel,
      );

      expect(find.text('Tunnel down'), findsOneWidget);
      expect(
        find.textContaining(
          'the app-owned config is missing: write '
          '~/.config/opencodebridge/cloudflared.yml',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'the DNS route for bridge.example.com is not in place',
        ),
        findsOneWidget,
      );
      expect(find.text('Check now'), findsOneWidget);
      expect(find.text('Start tunnel'), findsOneWidget);
    });

    testWidgets('the manual start asks the bridge and shows the new report', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final tunnel = FakeTunnelClient()..reportValue = _kDownReport;
      await pumpSettings(
        tester,
        mode: AppMode.server,
        localBridgeUri: Uri.parse('http://127.0.0.1:48201/'),
        tunnelClient: tunnel,
      );

      tunnel.reportValue = _kUpReport;
      await tester.tap(find.byKey(const ValueKey('tunnel-start')));
      await tester.pump();

      expect(tunnel.actions, ['start']);
      expect(find.text('Tunnel up'), findsOneWidget);
      expect(find.text('Check now'), findsNothing);
    });

    testWidgets('a bridge without a tunnel says so', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final tunnel = FakeTunnelClient()
        ..reportValue = const TunnelReport(
          status: TunnelStatus.notConfigured,
          running: false,
          registeredConnections: 0,
        );
      await pumpSettings(
        tester,
        mode: AppMode.server,
        localBridgeUri: Uri.parse('http://127.0.0.1:48201/'),
        tunnelClient: tunnel,
      );

      expect(find.text('This host does not run a tunnel.'), findsOneWidget);
    });

    testWidgets('an unreachable bridge offers a retry', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final tunnel = FakeTunnelClient()
        ..reportError = const TunnelClientError(0, 'refused');
      await pumpSettings(
        tester,
        mode: AppMode.server,
        localBridgeUri: Uri.parse('http://127.0.0.1:48201/'),
        tunnelClient: tunnel,
      );

      expect(find.text('Cannot reach the bridge.'), findsOneWidget);

      tunnel.reportError = null;
      tunnel.reportValue = _kUpReport;
      await tester.tap(find.byKey(const ValueKey('tunnel-retry')));
      await tester.pump();
      expect(find.text('Tunnel up'), findsOneWidget);
    });

    testWidgets('client mode without a tunnel url has no tunnel section', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final tunnel = FakeTunnelClient()..reportValue = _kUpReport;
      await pumpSettings(tester, mode: AppMode.client, tunnelClient: tunnel);

      expect(find.text('No bridge configured.'), findsOneWidget);
      expect(tunnel.actions, isEmpty);
    });
  });
}
