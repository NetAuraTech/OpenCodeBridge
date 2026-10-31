import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/tunnel/cloudflared_binary.dart';
import 'package:opencodebridge/bridge/tunnel/cloudflared_config.dart';
import 'package:opencodebridge/bridge/tunnel/tunnel_preconditions.dart';
import 'package:opencodebridge/model/tunnel_report.dart';

const String _kCredentialsUuid = '11111111-2222-3333-4444-555555555555';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('opencodebridge-tunnel');
  });

  tearDown(() async {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> writeBinary() async {
    await File('${dir.path}/cloudflared').writeAsString('the binary');
    await File('${dir.path}/version')
        .writeAsString(CloudflaredBinary.pinnedVersion);
  }

  Future<CloudflaredConfigFile> writeConfig({String? source}) async {
    final file = File('${dir.path}/cloudflared.yml');
    await file.writeAsString(
      source ??
          'tunnel: my-tunnel\n'
              'credentials-file: ${dir.path}/$_kCredentialsUuid.json\n'
              'ingress:\n'
              '  - hostname: bridge.example.com\n'
              '    service: http://127.0.0.1:48201\n',
    );
    return CloudflaredConfigFile(file: file);
  }

  Future<void> writeCredentials() async {
    await File('${dir.path}/$_kCredentialsUuid.json')
        .writeAsString('{"TunnelID": "$_kCredentialsUuid"}');
  }

  TunnelPreconditionChecker checker({
    required CloudflaredConfigFile configFile,
    Future<bool> Function(String)? dnsResolves,
    Future<AccessVerdict> Function(String)? accessProbe,
  }) {
    return TunnelPreconditionChecker(
      binary: CloudflaredBinary(
        dir: Directory(dir.path),
        resolveArch: () async => 'amd64',
        downloader: (Uri url, File target) async {},
      ),
      configFile: configFile,
      bridgePort: 48201,
      dnsResolves: dnsResolves ?? ((String host) async => true),
      accessProbe:
          accessProbe ?? (String host) async => AccessVerdict.enforcing,
    );
  }

  group('TunnelPreconditionChecker.check', () {
    test('every precondition met: allMet with the parsed config', () async {
      await writeBinary();
      final config = await writeConfig();
      await writeCredentials();
      final check = await checker(configFile: config).check();

      expect(check.allMet, isTrue);
      expect(check.missing, isEmpty);
      expect(check.config?.hostname, 'bridge.example.com');
      expect(check.config?.servicePort, 48201);
    });

    test('the missing config is reported', () async {
      await writeBinary();
      await writeCredentials();
      final config = CloudflaredConfigFile(
        file: File('${dir.path}/cloudflared.yml'),
      );
      final check = await checker(configFile: config).check();

      expect(check.allMet, isFalse);
      expect(check.missing.map((s) => s.id), [TunnelSetupStep.config]);
      expect(check.missing.first.message, contains('cloudflared.yml'));
    });

    test('the invalid config is reported', () async {
      await writeBinary();
      await writeCredentials();
      final config = await writeConfig(source: 'tunnel: [unclosed\n');
      final check = await checker(configFile: config).check();

      expect(check.allMet, isFalse);
      expect(check.missing.map((s) => s.id), [TunnelSetupStep.config]);
    });

    test('a config routing away from the bridge is reported', () async {
      await writeBinary();
      await writeCredentials();
      final config = await writeConfig(
        source:
            'tunnel: my-tunnel\n'
            'credentials-file: ${dir.path}/$_kCredentialsUuid.json\n'
            'ingress:\n'
            '  - hostname: bridge.example.com\n'
            '    service: http://127.0.0.1:9999\n',
      );
      final check = await checker(configFile: config).check();

      expect(check.allMet, isFalse);
      expect(check.missing.map((s) => s.id), [TunnelSetupStep.config]);
      expect(check.missing.first.message, contains('9999'));
    });

    test('the missing credentials are reported', () async {
      await writeBinary();
      final config = await writeConfig();
      final check = await checker(configFile: config).check();

      expect(check.allMet, isFalse);
      expect(check.missing.map((s) => s.id), [TunnelSetupStep.credentials]);
    });

    test('the binary that cannot be installed is reported', () async {
      final config = await writeConfig();
      await writeCredentials();
      final check = await TunnelPreconditionChecker(
        binary: CloudflaredBinary(
          dir: Directory(dir.path),
          resolveArch: () async => 'amd64',
          downloader: (Uri url, File target) async =>
              throw const SocketException('no network'),
        ),
        configFile: config,
        bridgePort: 48201,
        dnsResolves: (String host) async => true,
        accessProbe: (String host) async => AccessVerdict.enforcing,
      ).check();

      expect(check.allMet, isFalse);
      expect(check.missing.map((s) => s.id), [TunnelSetupStep.binary]);
    });

    test('the missing DNS route is reported', () async {
      await writeBinary();
      final config = await writeConfig();
      await writeCredentials();
      final check = await checker(
        configFile: config,
        dnsResolves: (String host) async => false,
      ).check();

      expect(check.allMet, isFalse);
      expect(check.missing.map((s) => s.id), [TunnelSetupStep.dnsRoute]);
      expect(check.missing.first.message, contains('bridge.example.com'));
    });

    test('an open tunnel (no Access) is reported', () async {
      await writeBinary();
      final config = await writeConfig();
      await writeCredentials();
      final check = await checker(
        configFile: config,
        accessProbe: (String host) async => AccessVerdict.open,
      ).check();

      expect(check.allMet, isFalse);
      expect(check.missing.map((s) => s.id), [TunnelSetupStep.access]);
      expect(check.missing.first.message, contains('open'));
    });

    test('an unreachable hostname is reported', () async {
      await writeBinary();
      final config = await writeConfig();
      await writeCredentials();
      final check = await checker(
        configFile: config,
        accessProbe: (String host) async => AccessVerdict.unreachable,
      ).check();

      expect(check.allMet, isFalse);
      expect(check.missing.map((s) => s.id), [TunnelSetupStep.access]);
    });
  });
}
