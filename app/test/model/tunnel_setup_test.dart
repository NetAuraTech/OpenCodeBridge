import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/model/tunnel_setup.dart';

const String _kUuid = '11111111-2222-3333-4444-555555555555';

void main() {
  group('normalizeTunnelName', () {
    test('trims a valid name', () {
      expect(normalizeTunnelName('  my-tunnel '), 'my-tunnel');
    });

    test('is missing when null or empty', () {
      for (final value in [null, '', '   ']) {
        expect(
          () => normalizeTunnelName(value),
          throwsA(
            isA<TunnelSetupError>().having(
              (e) => e.message,
              'message',
              'the tunnel name is missing',
            ),
          ),
        );
      }
    });

    test('rejects names with invalid characters or over the length', () {
      expect(
        () => normalizeTunnelName('my tunnel'),
        throwsA(
          isA<TunnelSetupError>().having(
            (e) => e.message,
            'message',
            contains('"my tunnel"'),
          ),
        ),
      );
      expect(
        () => normalizeTunnelName('a' * 64),
        throwsA(isA<TunnelSetupError>()),
      );
    });
  });

  group('normalizeHostname', () {
    test('trims and lowercases a valid hostname', () {
      expect(normalizeHostname('  Bridge.Example.COM '), 'bridge.example.com');
    });

    test('is missing when null or empty', () {
      for (final value in [null, '', '  ']) {
        expect(
          () => normalizeHostname(value),
          throwsA(
            isA<TunnelSetupError>().having(
              (e) => e.message,
              'message',
              'the public hostname is missing',
            ),
          ),
        );
      }
    });

    test('rejects non-hostnames', () {
      for (final value in [
        'bridge_example.com', // underscores are not DNS
        'example', // a single label
        'bridge.example.com.', // a trailing dot
        '-bridge.example.com',
      ]) {
        expect(
          () => normalizeHostname(value),
          throwsA(
            isA<TunnelSetupError>().having(
              (e) => e.message,
              'message',
              contains('"$value"'),
            ),
          ),
        );
      }
    });
  });

  group('TunnelCredentials.parse', () {
    test('parses the pasted credentials', () {
      final credentials = TunnelCredentials.parse(
        '  {\n'
        '    "OwnerID": "owner",\n'
        '    "TunnelID": "$_kUuid",\n'
        '    "APIKey": "key",\n'
        '    "OwnerEmail": "user@example.com"\n'
        '  }\n',
      );

      expect(credentials.tunnelId, _kUuid);
      expect(
        credentials.source,
        '{\n'
        '    "OwnerID": "owner",\n'
        '    "TunnelID": "$_kUuid",\n'
        '    "APIKey": "key",\n'
        '    "OwnerEmail": "user@example.com"\n'
        '  }',
      );
      expect(credentials.ownerEmail, 'user@example.com');
      expect(credentials.accountId, isNull);
    });

    test('keeps the account id, when present', () {
      final credentials = TunnelCredentials.parse(
        '{"TunnelID": "$_kUuid", "APIKey": "key", '
        '"OwnerAccountID": "ab12cd"}',
      );

      expect(credentials.accountId, 'ab12cd');
    });

    test('accepts the APIToken and AccessToken token fields', () {
      expect(
        TunnelCredentials.parse('{"TunnelID": "$_kUuid", "APIToken": "t"}')
            .tunnelId,
        _kUuid,
      );
      expect(
        TunnelCredentials.parse('{"TunnelID": "$_kUuid", "AccessToken": "t"}')
            .tunnelId,
        _kUuid,
      );
    });

    test('accepts the TunnelSecret field cloudflared 2026.10.7 writes', () {
      // The pinned cloudflared's `tunnel create` writes this shape: no
      // APIKey, the secret lives in TunnelSecret.
      final credentials = TunnelCredentials.parse(
        '{"AccountTag": "139fab53aa401f1bf73e2cdd94a85abe", '
        '"TunnelSecret": "secret", '
        '"TunnelID": "$_kUuid", '
        '"Endpoint": ""}',
      );

      expect(credentials.tunnelId, _kUuid);
    });

    test('lowercases the TunnelID', () {
      final uppercase = _kUuid.toUpperCase();
      expect(
        TunnelCredentials.parse('{"TunnelID": "$uppercase", "APIKey": "key"}')
            .tunnelId,
        _kUuid,
      );
    });

    test('is missing when the paste is null or empty', () {
      for (final value in [null, '', '  ']) {
        expect(
          () => TunnelCredentials.parse(value),
          throwsA(
            isA<TunnelSetupError>().having(
              (e) => e.message,
              'message',
              contains('the credentials are missing'),
            ),
          ),
        );
      }
    });

    test('rejects non-JSON and non-object JSON', () {
      expect(
        () => TunnelCredentials.parse('{nope'),
        throwsA(
          isA<TunnelSetupError>().having(
            (e) => e.message,
            'message',
            'the credentials are not valid JSON',
          ),
        ),
      );
      expect(
        () => TunnelCredentials.parse('["TunnelID"]'),
        throwsA(
          isA<TunnelSetupError>().having(
            (e) => e.message,
            'message',
            'the credentials are not a JSON object',
          ),
        ),
      );
    });

    test('rejects a missing or non-UUID TunnelID', () {
      expect(
        () => TunnelCredentials.parse('{"APIKey": "key"}'),
        throwsA(
          isA<TunnelSetupError>().having(
            (e) => e.message,
            'message',
            'the credentials carry no TunnelID',
          ),
        ),
      );
      expect(
        () => TunnelCredentials.parse('{"TunnelID": "nope", "APIKey": "key"}'),
        throwsA(
          isA<TunnelSetupError>().having(
            (e) => e.message,
            'message',
            contains('not a UUID: nope'),
          ),
        ),
      );
    });

    test('rejects an empty API key or token', () {
      for (final token in [
        '"APIKey": ""',
        '"APIKey": "  "',
        '"TunnelSecret": ""',
      ]) {
        expect(
          () => TunnelCredentials.parse('{"TunnelID": "$_kUuid", $token}'),
          throwsA(
            isA<TunnelSetupError>().having(
              (e) => e.message,
              'message',
              contains('no API key or token'),
            ),
          ),
        );
      }
    });
  });

  group('the displayed values', () {
    test('cfargotunnelTarget', () {
      expect(cfargotunnelTarget(_kUuid), '$_kUuid.cfargotunnel.com');
    });

    test('dnsCnameLine', () {
      expect(
        dnsCnameLine('bridge.example.com', _kUuid),
        'bridge.example.com → $_kUuid.cfargotunnel.com',
      );
    });

    test('accessAppSpec grants the owner email when present', () {
      expect(
        accessAppSpec('bridge.example.com', ownerEmail: 'user@example.com'),
        'Self-hosted app for https://bridge.example.com '
        'with an email policy allowing user@example.com',
      );
      expect(
        accessAppSpec('bridge.example.com'),
        'Self-hosted app for https://bridge.example.com '
        'with an email policy for your Cloudflare account',
      );
    });

    test('dashboardDeepLink is account-scoped when possible', () {
      expect(
        dashboardDeepLink('dns/records', accountId: 'ab12cd'),
        'https://dash.cloudflare.com/ab12cd/dns/records',
      );
      expect(dashboardDeepLink('access/apps'), 'https://dash.cloudflare.com/');
    });
  });
}
