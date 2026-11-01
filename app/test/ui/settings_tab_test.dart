import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/access/access_session.dart';
import 'package:opencodebridge/bridge/notify/firebase_service_account.dart';
import 'package:opencodebridge/access/token_store.dart';
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

  /// The last assisted-setup arguments, recorded by [setup].
  String? setupTunnel;
  String? setupHostname;
  String? setupCredentials;

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

  @override
  Future<void> login() async {
    actions.add('login');
    final error = reportError;
    if (error is Object) throw error;
  }

  @override
  Future<TunnelReport> setup(
    String tunnel,
    String hostname, [
    String? credentials,
  ]) async {
    actions.add('setup');
    setupTunnel = tunnel;
    setupHostname = hostname;
    setupCredentials = credentials;
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
    AccessSession? access,
    String? tunnelUrl,
    VoidCallback? onNotifyToggled,
    VoidCallback? onPushProjectCommitted,
    VoidCallback? onServiceAccountCommitted,
    String? serviceAccountPath,
  }) async {
    final settings = await AppSettings.load();
    if (tunnelUrl != null) settings.tunnelUrl = tunnelUrl;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsTab(
            settings: settings,
            mode: mode,
            localBridgeUri: localBridgeUri,
            tunnelClient: tunnelClient ?? FakeTunnelClient(),
            access: access,
            onNotifyToggled: onNotifyToggled,
            onPushProjectCommitted: onPushProjectCommitted,
            onServiceAccountCommitted: onServiceAccountCommitted,
            serviceAccountPath: serviceAccountPath,
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

      final field = find.byKey(const ValueKey('tunnel-url-field'));
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

      expect(find.byKey(const ValueKey('tunnel-url-field')), findsNothing);
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

      // About sits below the fold (the push setup grew the tab): scroll to it.
      await tester.dragUntilVisible(
        find.textContaining(kAppVersion),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(find.textContaining(kAppVersion), findsOneWidget);
    });
  });

  group('SettingsTab push (issue #24)', () {
    const String kGoodProjectJson = '''
        {
          "project_info": {
            "project_number": "123456789012",
            "project_id": "opencodebridge-test",
            "storage_bucket": "opencodebridge-test.appspot.com"
          },
          "client": [
            {
              "client_info": {
                "mobilesdk_app_id": "1:123456789012:android:abcdef123456",
                "android_client_info": {
                  "package_name": "com.example.opencodebridge"
                }
              },
              "oauth_client": [
                {
                  "client_id": "123456789012-xyz.apps.googleusercontent.com",
                  "client_type": 3
                }
              ],
              "api_key": [
                {
                  "current_key": "AIzaSyA-test-key"
                }
              ]
            }
          ]
        }
        ''';

    testWidgets('a toggle change re-registers (onNotifyToggled)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      var toggles = 0;
      final settings = await pumpSettings(
        tester,
        onNotifyToggled: () => toggles++,
      );

      await tester.tap(find.byKey(const ValueKey('notify-turn-ended')));
      await tester.pump();

      expect(settings.notifyTurnEnded, isTrue);
      expect(toggles, 1);
    });

    testWidgets('an invalid paste shows the problem and saves nothing', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      var commits = 0;
      final settings = await pumpSettings(
        tester,
        onPushProjectCommitted: () => commits++,
      );

      await tester.enterText(
        find.byKey(const ValueKey('push-project-field')),
        'not a json',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('push-project-save')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('push-project-save')));
      await tester.pump();

      expect(
        find.text('That is not a valid google-services.json.'),
        findsOneWidget,
      );
      expect(settings.firebaseProjectJson, '');
      expect(commits, 0);
    });

    testWidgets('a valid paste saves the project and commits', (tester) async {
      SharedPreferences.setMockInitialValues({});
      var commits = 0;
      final settings = await pumpSettings(
        tester,
        onPushProjectCommitted: () => commits++,
      );

      await tester.enterText(
        find.byKey(const ValueKey('push-project-field')),
        kGoodProjectJson,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('push-project-save')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('push-project-save')));
      await tester.pump();

      expect(settings.firebaseProjectJson, kGoodProjectJson.trim());
      expect(commits, 1);
      expect(
        find.text('Firebase project: opencodebridge-test.'),
        findsOneWidget,
      );
    });

    testWidgets('a saved project shows its project id on load', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'notify.firebaseProject': kGoodProjectJson,
      });
      await pumpSettings(tester);

      expect(
        find.text('Firebase project: opencodebridge-test.'),
        findsOneWidget,
      );
    });
  });

  group('SettingsTab service account (issue #24, server mode)', () {
    const String kAccountJson = '''
        {
          "type": "service_account",
          "project_id": "opencodebridge-test",
          "private_key": "-----BEGIN PRIVATE KEY-----\\nabc\\n-----END PRIVATE KEY-----\\n",
          "client_email": "svc@opencodebridge-test.iam.gserviceaccount.com",
          "client_id": "123"
        }
        ''';

    late Directory home;
    late String accountPath;

    setUp(() async {
      // The section reads and writes the app-owned file; point it at a temp
      // file (the tab's `serviceAccountPath` seam) instead of the real
      // `~/.config/opencodebridge/firebase/service-account.json`.
      home = await Directory.systemTemp.createTemp('opencodebridge-sa-ui');
      accountPath = '${home.path}/service-account.json';
    });

    tearDown(() async {
      await home.delete(recursive: true);
    });

    testWidgets('an unconfigured host shows not configured', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(
        tester,
        mode: AppMode.server,
        serviceAccountPath: accountPath,
      );

      expect(
        find.text('Service account: not configured.'),
        findsOneWidget,
      );
    });

    testWidgets('a valid paste installs the file and commits', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      var commits = 0;
      await pumpSettings(
        tester,
        mode: AppMode.server,
        onServiceAccountCommitted: () => commits++,
        serviceAccountPath: accountPath,
      );

      await tester.enterText(
        find.byKey(const ValueKey('service-account-field')),
        kAccountJson,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('service-account-save')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('service-account-save')));
      await tester.pump();

      final file = File(accountPath);
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), '${kAccountJson.trim()}\n');
      expect(commits, 1);
      expect(
        find.text('Service account: svc@opencodebridge-test.iam.gserviceaccount.com.'),
        findsOneWidget,
      );
      // The field clears after a save (the key stays in the file).
      expect(
        (tester.widget(find.byKey(const ValueKey('service-account-field')))
                as TextField)
            .controller
            ?.text,
        '',
      );
    });

    testWidgets('an invalid paste shows the problem and saves nothing', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      var commits = 0;
      await pumpSettings(
        tester,
        mode: AppMode.server,
        onServiceAccountCommitted: () => commits++,
        serviceAccountPath: accountPath,
      );

      await tester.enterText(
        find.byKey(const ValueKey('service-account-field')),
        'not a json',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('service-account-save')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('service-account-save')));
      await tester.pump();

      expect(
        find.text('That is not a valid service account JSON.'),
        findsOneWidget,
      );
      expect(File(accountPath).existsSync(), isFalse);
      expect(commits, 0);
    });

    testWidgets('an installed account shows its email on load', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      FirebaseServiceAccount.install(kAccountJson, path: accountPath);
      await pumpSettings(
        tester,
        mode: AppMode.server,
        serviceAccountPath: accountPath,
      );

      expect(
        find.text('Service account: svc@opencodebridge-test.iam.gserviceaccount.com.'),
        findsOneWidget,
      );
    });

    testWidgets('client mode shows no service account section', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettings(tester, mode: AppMode.client);

      expect(find.byKey(const ValueKey('service-account-field')), findsNothing);
      // The client side keeps the google-services.json field.
      expect(find.byKey(const ValueKey('push-project-field')), findsOneWidget);
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

    testWidgets('the login finishing re-fetches the tunnel status', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final tunnel = FakeTunnelClient()
        ..reportError = const TunnelClientError(401, 'unauthorized');
      final store = await AccessTokenStore.load();
      final access = AccessSession(
        tunnelBase: () => Uri.parse('https://tunnel.test/'),
        store: store,
      );
      await pumpSettings(
        tester,
        mode: AppMode.client,
        tunnelClient: tunnel,
        tunnelUrl: 'https://tunnel.test/',
        access: access,
      );

      // Before the token exists, the status is a 401 with a retry.
      expect(find.byKey(const ValueKey('tunnel-retry')), findsOneWidget);

      // The browser bounce brought the app to the foreground before the
      // token exchange finished; the login completes now: the status
      // re-fetches with the token.
      tunnel.reportError = null;
      tunnel.reportValue = _kUpReport;
      store.save(
        'tunnel.test',
        AccessLoginRecord(
          clientId: 'c1',
          accessToken: 'tok',
          refreshToken: 'rtok',
          accessTokenExpiresAt: DateTime.now().add(const Duration(hours: 1)),
        ),
      );
      await access.restore();
      await tester.pump();

      expect(find.text('Tunnel up'), findsOneWidget);
    });
  });

  group('SettingsTab assisted setup (issue #34)', () {
    const String kSetupCredentialsJson =
        '{"TunnelID":"11111111-2222-3333-4444-555555555555","APIKey":"secret"}';

    testWidgets('server mode with a down tunnel offers the assisted setup', (
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

      expect(find.byKey(const ValueKey('tunnel-setup')), findsOneWidget);
      expect(find.text('Set up the tunnel'), findsOneWidget);
    });

    testWidgets('client mode does not offer the assisted setup', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'host.tunnelUrl': 'https://bridge.example.com/',
      });
      final tunnel = FakeTunnelClient()..reportValue = _kDownReport;
      await pumpSettings(tester, mode: AppMode.client, tunnelClient: tunnel);

      expect(find.text('Tunnel down'), findsOneWidget);
      expect(find.byKey(const ValueKey('tunnel-setup')), findsNothing);
      expect(find.text('Set up the tunnel'), findsNothing);
    });

    testWidgets('an up tunnel needs no setup', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final tunnel = FakeTunnelClient()..reportValue = _kUpReport;
      await pumpSettings(
        tester,
        mode: AppMode.server,
        localBridgeUri: Uri.parse('http://127.0.0.1:48201/'),
        tunnelClient: tunnel,
      );

      expect(find.byKey(const ValueKey('tunnel-setup')), findsNothing);
    });

    testWidgets(
      'the wizard collects the three inputs and shows the manual steps',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final tunnel = FakeTunnelClient()..reportValue = _kDownReport;
        await pumpSettings(
          tester,
          mode: AppMode.server,
          localBridgeUri: Uri.parse('http://127.0.0.1:48201/'),
          tunnelClient: tunnel,
        );
        await tester.tap(find.byKey(const ValueKey('tunnel-setup')));
        await tester.pump();

        expect(find.byKey(const ValueKey('setup-tunnel-name')), findsOneWidget);
        expect(find.byKey(const ValueKey('setup-hostname')), findsOneWidget);
        expect(find.byKey(const ValueKey('setup-credentials')), findsOneWidget);
        expect(find.byKey(const ValueKey('setup-submit')), findsOneWidget);
        expect(find.byKey(const ValueKey('setup-cancel')), findsOneWidget);

        // A valid hostname plus credentials reveals the manual steps.
        await tester.enterText(
          find.byKey(const ValueKey('setup-hostname')),
          'bridge.example.com',
        );
        await tester.enterText(
          find.byKey(const ValueKey('setup-credentials')),
          '{"TunnelID":"11111111-2222-3333-4444-555555555555",'
          '"APIKey":"secret","OwnerEmail":"user@example.com"}',
        );
        await tester.pump();

        expect(
          find.textContaining(
            'bridge.example.com → 11111111-2222-3333-4444-555555555555.cfargotunnel.com',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining('Self-hosted app for https://bridge.example.com'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'without credentials the login offer shows and drives the login',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final tunnel = FakeTunnelClient()..reportValue = _kDownReport;
        await pumpSettings(
          tester,
          mode: AppMode.server,
          localBridgeUri: Uri.parse('http://127.0.0.1:48201/'),
          tunnelClient: tunnel,
        );
        await tester.tap(find.byKey(const ValueKey('tunnel-setup')));
        await tester.pump();

        // No credentials pasted: the app-driven login offer shows.
        expect(find.byKey(const ValueKey('setup-login')), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('setup-login')));
        await tester.pump();

        expect(tunnel.actions, contains('login'));
        expect(find.textContaining('Logged in to Cloudflare'), findsOneWidget);

        // Pasting credentials hides the login offer.
        await tester.enterText(
          find.byKey(const ValueKey('setup-credentials')),
          kSetupCredentialsJson,
        );
        await tester.pump();
        expect(find.byKey(const ValueKey('setup-login')), findsNothing);
      },
    );

    testWidgets(
      'an invalid tunnel name shows the app-side error and does not submit',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final tunnel = FakeTunnelClient()..reportValue = _kDownReport;
        await pumpSettings(
          tester,
          mode: AppMode.server,
          localBridgeUri: Uri.parse('http://127.0.0.1:48201/'),
          tunnelClient: tunnel,
        );
        await tester.tap(find.byKey(const ValueKey('tunnel-setup')));
        await tester.pump();

        await tester.enterText(
          find.byKey(const ValueKey('setup-tunnel-name')),
          'has space',
        );
        await tester.enterText(
          find.byKey(const ValueKey('setup-hostname')),
          'bridge.example.com',
        );
        await tester.enterText(
          find.byKey(const ValueKey('setup-credentials')),
          kSetupCredentialsJson,
        );
        await tester.ensureVisible(find.byKey(const ValueKey('setup-submit')));
        await tester.tap(find.byKey(const ValueKey('setup-submit')));
        await tester.pump();

        expect(
          find.textContaining('the tunnel name is invalid'),
          findsOneWidget,
        );
        expect(tunnel.actions, isNot(contains('setup')));
      },
    );

    testWidgets('a valid setup submits and the tab adopts the fresh report', (
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
      await tester.tap(find.byKey(const ValueKey('tunnel-setup')));
      await tester.pump();

      tunnel.reportValue = _kUpReport;
      await tester.enterText(
        find.byKey(const ValueKey('setup-tunnel-name')),
        'my-tunnel',
      );
      await tester.enterText(
        find.byKey(const ValueKey('setup-hostname')),
        'bridge.example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('setup-credentials')),
        kSetupCredentialsJson,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('setup-submit')));
      await tester.tap(find.byKey(const ValueKey('setup-submit')));
      await tester.pumpAndSettle();

      expect(tunnel.actions, ['setup']);
      expect(tunnel.setupTunnel, 'my-tunnel');
      expect(tunnel.setupHostname, 'bridge.example.com');
      expect(tunnel.setupCredentials, kSetupCredentialsJson);
      // The dialog is gone; the tab shows the fresh report.
      expect(find.byKey(const ValueKey('setup-submit')), findsNothing);
      expect(find.text('Tunnel up'), findsOneWidget);
    });

    testWidgets('a bridge 400 shows the bridge details', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final tunnel = FakeTunnelClient()..reportValue = _kDownReport;
      await pumpSettings(
        tester,
        mode: AppMode.server,
        localBridgeUri: Uri.parse('http://127.0.0.1:48201/'),
        tunnelClient: tunnel,
      );
      await tester.tap(find.byKey(const ValueKey('tunnel-setup')));
      await tester.pump();

      tunnel.reportError = const TunnelClientError(
        400,
        '{"error":"invalid_body","details":"the credentials carry no API key or token"}',
      );
      await tester.enterText(
        find.byKey(const ValueKey('setup-tunnel-name')),
        'my-tunnel',
      );
      await tester.enterText(
        find.byKey(const ValueKey('setup-hostname')),
        'bridge.example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('setup-credentials')),
        kSetupCredentialsJson,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('setup-submit')));
      await tester.tap(find.byKey(const ValueKey('setup-submit')));
      await tester.pump();

      expect(
        find.text('the credentials carry no API key or token'),
        findsOneWidget,
      );
      // The dialog stays open for a retry.
      expect(find.byKey(const ValueKey('setup-submit')), findsOneWidget);
    });
  });
}
