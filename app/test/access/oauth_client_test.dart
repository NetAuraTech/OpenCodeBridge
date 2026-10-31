import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/access/oauth_client.dart';

void main() {
  late HttpServer server;
  late Uri base;
  late Map<String, Object?> registrationBody;
  late Map<String, String?> lastForm;
  var registrationEnabled = true;
  var tokenResponse = <String, Object?>{
    'access_token': 'oauth:opaque-1',
    'refresh_token': 'refresh-1',
    'expires_in': 900,
  };
  var tokenStatus = HttpStatus.ok;

  setUp(() async {
    registrationEnabled = true;
    lastForm = {};
    tokenResponse = <String, Object?>{
      'access_token': 'oauth:opaque-1',
      'refresh_token': 'refresh-1',
      'expires_in': 900,
    };
    tokenStatus = HttpStatus.ok;
    server = await HttpServer.bind('127.0.0.1', 0);
    final host = '127.0.0.1:${server.port}';
    base = Uri.parse('http://$host/');

    server.listen((req) async {
      final path = req.uri.path;
      final response = req.response..headers.contentType = ContentType.json;
      if (path == '/.well-known/oauth-authorization-server') {
        response
          ..statusCode = HttpStatus.ok
          ..write(
            jsonEncode({
              'authorization_endpoint': 'http://$host/authorize',
              'token_endpoint': 'http://$host/token',
              if (registrationEnabled)
                'registration_endpoint': 'http://$host/register',
            }),
          );
      } else if (path == '/register') {
        final raw = await _read(req);
        final decoded = jsonDecode(raw);
        registrationBody = decoded is Map<String, Object?>
            ? decoded
            : <String, Object?>{};
        response
          ..statusCode = HttpStatus.created
          ..write(jsonEncode({'client_id': 'dyn-client-1'}));
      } else if (path == '/token') {
        final raw = await _read(req);
        lastForm = Uri.splitQueryString(raw);
        if (lastForm['grant_type'] == 'authorization_code' &&
            lastForm['code'] != 'good-code') {
          response
            ..statusCode = HttpStatus.badRequest
            ..write(jsonEncode({'error': 'invalid_grant'}));
          await response.close();
          return;
        }
        response
          ..statusCode = tokenStatus
          ..write(jsonEncode(tokenResponse));
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  group('discover', () {
    test('reads the endpoints from the well-known document', () async {
      final metadata = await AccessOAuthClient(base).discover();
      expect(metadata.authorizationEndpoint.path, '/authorize');
      expect(metadata.tokenEndpoint.path, '/token');
      expect(metadata.registrationEndpoint?.path, '/register');
    });

    test('without a registration endpoint it is null', () async {
      registrationEnabled = false;
      final metadata = await AccessOAuthClient(base).discover();
      expect(metadata.registrationEndpoint, isNull);
    });

    test(
      'a tunnel that is not an Access app throws a friendly error',
      () async {
        await server.close(force: true);
        final plain = await HttpServer.bind('127.0.0.1', 0);
        plain.listen((req) async {
          // An Access-protected hostname without Managed OAuth redirects
          // non-browser clients to its login page; the followed answer is
          // a non-JSON HTML page.
          req.response
            ..statusCode = HttpStatus.ok
            ..write('<html>login</html>');
          await req.response.close();
        });
        try {
          await expectLater(
            () =>
                AccessOAuthClient(Uri.parse('http://127.0.0.1:${plain.port}/'))
                    .discover(),
            throwsA(
              isA<OAuthError>().having(
                (e) => e.code,
                'code',
                'discovery_failed',
              ),
            ),
          );
        } finally {
          await plain.close(force: true);
        }
      },
    );
  });

  group('registerClient (RFC 8707)', () {
    test('posts the loopback redirect and returns the client id', () async {
      final id = await AccessOAuthClient(base)
          .registerClient('http://127.0.0.1:54321/callback');
      expect(id, 'dyn-client-1');
      expect(registrationBody['client_name'], 'OpenCodeBridge');
      expect(registrationBody['redirect_uris'], [
        'http://127.0.0.1:54321/callback',
      ]);
      expect(registrationBody['grant_types'], [
        'authorization_code',
        'refresh_token',
      ]);
      expect(registrationBody['response_types'], ['code']);
      expect(registrationBody['token_endpoint_auth_method'], 'none');
      expect(registrationBody['resource'], base.toString());
    });

    test('throws when registration is unavailable', () async {
      registrationEnabled = false;
      await expectLater(
        () => AccessOAuthClient(base).registerClient('http://127.0.0.1:1/cb'),
        throwsA(
          isA<OAuthError>().having(
            (e) => e.code,
            'code',
            'registration_unavailable',
          ),
        ),
      );
    });
  });

  group('authorizationUrl', () {
    test('carries code grant params plus the anti-CSRF state', () async {
      final client = AccessOAuthClient(base);
      await client.discover();
      final url = client.authorizationUrl(
        'dyn-client-1',
        'http://127.0.0.1:54321/callback',
        'state-xyz',
      );
      expect(url.path, '/authorize');
      expect(url.queryParameters['response_type'], 'code');
      expect(url.queryParameters['client_id'], 'dyn-client-1');
      expect(
        url.queryParameters['redirect_uri'],
        'http://127.0.0.1:54321/callback',
      );
      expect(url.queryParameters['state'], 'state-xyz');
    });

    test('carries the S256 PKCE challenge and the RFC 8707 resource', () async {
      final client = AccessOAuthClient(base);
      await client.discover();
      final url = client.authorizationUrl(
        'dyn-client-1',
        'http://127.0.0.1:54321/callback',
        'state-xyz',
      );
      final challenge = url.queryParameters['code_challenge'];
      expect(challenge, isNotNull);
      expect(challenge, isNot(startsWith('-')));
      expect(challenge, isNot(startsWith('_')));
      expect(url.queryParameters['code_challenge_method'], 'S256');
      expect(url.queryParameters['resource'], base.toString());
    });
  });

  group('exchangeCode / refresh', () {
    test('exchanges the code for the opaque pair', () async {
      final client = AccessOAuthClient(base);
      await client.discover();
      client.authorizationUrl(
        'dyn-client-1',
        'http://127.0.0.1:54321/callback',
        'state-xyz',
      );
      final tokens = await client.exchangeCode(
        'dyn-client-1',
        'good-code',
        'http://127.0.0.1:54321/callback',
      );
      expect(tokens.accessToken, 'oauth:opaque-1');
      expect(tokens.refreshToken, 'refresh-1');
      expect(tokens.expiresIn, const Duration(seconds: 900));
      expect(lastForm['grant_type'], 'authorization_code');
      expect(lastForm['code'], 'good-code');
    });

    test('presents the PKCE verifier that mints the challenge', () async {
      final client = AccessOAuthClient(base);
      await client.discover();
      final url = client.authorizationUrl(
        'dyn-client-1',
        'http://127.0.0.1:54321/callback',
        'state-xyz',
      );
      await client.exchangeCode(
        'dyn-client-1',
        'good-code',
        'http://127.0.0.1:54321/callback',
      );
      final verifier = lastForm['code_verifier'];
      expect(verifier, isNotNull);
      expect(
        base64UrlEncode(sha256.convert(verifier!.codeUnits).bytes)
            .replaceAll('=', ''),
        url.queryParameters['code_challenge'],
      );
    });

    test('without a started flow the exchange throws', () async {
      final client = AccessOAuthClient(base);
      await client.discover();
      expect(
        () => client.exchangeCode(
          'dyn-client-1',
          'good-code',
          'http://127.0.0.1:1/cb',
        ),
        throwsStateError,
      );
    });

    test('a bad code is an invalid_grant OAuthError', () async {
      final client = AccessOAuthClient(base);
      await client.discover();
      client.authorizationUrl(
        'dyn-client-1',
        'http://127.0.0.1:54321/callback',
        'state-xyz',
      );
      await expectLater(
        () => client.exchangeCode(
          'dyn-client-1',
          'wrong',
          'http://127.0.0.1:1/cb',
        ),
        throwsA(
          isA<OAuthError>().having((e) => e.code, 'code', 'invalid_grant'),
        ),
      );
    });

    test('refresh posts the refresh token and returns a new pair', () async {
      tokenResponse = <String, Object?>{
        'access_token': 'oauth:opaque-2',
        'refresh_token': 'refresh-2',
        'expires_in': 900,
      };
      final tokens = await AccessOAuthClient(base)
          .refresh('dyn-client-1', 'refresh-1');
      expect(tokens.accessToken, 'oauth:opaque-2');
      expect(tokens.refreshToken, 'refresh-2');
      expect(lastForm['grant_type'], 'refresh_token');
      expect(lastForm['refresh_token'], 'refresh-1');
    });

    test('an ended grant session (invalid_grant) is an OAuthError', () async {
      tokenStatus = HttpStatus.badRequest;
      tokenResponse = <String, Object?>{
        'error': 'invalid_grant',
        'error_description': 'grant session ended',
      };
      await expectLater(
        () => AccessOAuthClient(base).refresh('dyn-client-1', 'refresh-1'),
        throwsA(
          isA<OAuthError>()
              .having((e) => e.code, 'code', 'invalid_grant')
              .having((e) => e.grantEnded, 'grantEnded', isTrue),
        ),
      );
    });
  });

  group('AccessTokens.isExpired', () {
    final acquired = DateTime(2026, 10, 31, 12, 0, 0);

    test('expires after the declared lifetime', () {
      final tokens = AccessTokens(
        accessToken: 'a',
        refreshToken: 'r',
        expiresIn: const Duration(minutes: 15),
        acquiredAt: acquired,
      );
      expect(
        tokens.isExpired(acquired.add(const Duration(minutes: 14))),
        isFalse,
      );
      expect(
        tokens.isExpired(acquired.add(const Duration(minutes: 15))),
        isTrue,
      );
    });

    test('the 30s default skew refreshes early', () {
      final tokens = AccessTokens(
        accessToken: 'a',
        refreshToken: 'r',
        expiresIn: const Duration(minutes: 15),
        acquiredAt: acquired,
      );
      expect(
        tokens.isExpired(
          acquired.add(const Duration(minutes: 14, seconds: 35)),
        ),
        isTrue,
      );
      expect(
        tokens.isExpired(
          acquired.add(const Duration(minutes: 14, seconds: 20)),
        ),
        isFalse,
      );
    });
  });
}

Future<String> _read(HttpRequest request) async {
  final bytes = <int>[];
  await for (final chunk in request) {
    bytes.addAll(chunk);
  }
  return const Utf8Decoder().convert(bytes);
}
