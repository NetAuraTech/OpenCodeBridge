import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/tunnel/cloudflared_config.dart';

void main() {
  group('ParsedCloudflaredConfig.parse', () {
    test('parses a valid tunnel config', () {
      final config = ParsedCloudflaredConfig.parse('''
tunnel: my-tunnel
credentials-file: /home/user/.cloudflared/11111111-2222-3333-4444-555555555555.json
ingress:
  - hostname: bridge.example.com
    service: http://127.0.0.1:48201
''');
      expect(config.tunnel, 'my-tunnel');
      expect(
        config.credentialsFile,
        '/home/user/.cloudflared/11111111-2222-3333-4444-555555555555.json',
      );
      expect(config.hostname, 'bridge.example.com');
      expect(config.serviceHost, '127.0.0.1');
      expect(config.servicePort, 48201);
    });

    test('missing tunnel is invalid', () {
      expect(
        () => ParsedCloudflaredConfig.parse('credentials-file: x\n'),
        throwsA(isA<CloudflaredConfigError>()),
      );
    });

    test('missing credentials-file is invalid', () {
      expect(
        () => ParsedCloudflaredConfig.parse('tunnel: t\n'),
        throwsA(isA<CloudflaredConfigError>()),
      );
    });

    test('missing ingress is invalid', () {
      expect(
        () => ParsedCloudflaredConfig.parse('tunnel: t\ncredentials-file: c\n'),
        throwsA(isA<CloudflaredConfigError>()),
      );
    });

    test('a bad service is invalid', () {
      expect(
        () => ParsedCloudflaredConfig.parse(
          'tunnel: t\n'
          'credentials-file: c\n'
          'ingress:\n'
          '  - hostname: h\n'
          '    service: not-a-uri\n',
        ),
        throwsA(isA<CloudflaredConfigError>()),
      );
    });

    test('a service without a port is invalid', () {
      expect(
        () => ParsedCloudflaredConfig.parse(
          'tunnel: t\n'
          'credentials-file: c\n'
          'ingress:\n'
          '  - hostname: h\n'
          '    service: http://127.0.0.1\n',
        ),
        throwsA(isA<CloudflaredConfigError>()),
      );
    });

    test('no ingress entry with a hostname and a service is invalid', () {
      expect(
        () => ParsedCloudflaredConfig.parse(
          'tunnel: t\n'
          'credentials-file: c\n'
          'ingress:\n'
          '  - service: http://127.0.0.1:48201\n',
        ),
        throwsA(isA<CloudflaredConfigError>()),
      );
    });

    test('not a mapping is invalid', () {
      expect(
        () => ParsedCloudflaredConfig.parse('- just\n- a list\n'),
        throwsA(isA<CloudflaredConfigError>()),
      );
    });

    test('not YAML is invalid', () {
      expect(
        () => ParsedCloudflaredConfig.parse('tunnel: [unclosed\n'),
        throwsA(isA<CloudflaredConfigError>()),
      );
    });
  });

  group('CloudflaredConfigFile', () {
    test('read() is null when the file is missing', () {
      final config = CloudflaredConfigFile(
        file: File('/nonexistent/cloudflared.yml'),
      );
      expect(config.read(), isNull);
    });

    test('read() parses a valid file in place', () {
      final config = CloudflaredConfigFile(
        file: File('/nonexistent/cloudflared.yml'),
      );
      expect(config.file.path, '/nonexistent/cloudflared.yml');
    });
  });
}
