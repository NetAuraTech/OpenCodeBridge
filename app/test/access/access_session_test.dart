import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/access/access_session.dart';
import 'package:opencodebridge/access/oauth_client.dart';
import 'package:opencodebridge/access/token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late HttpServer server;
  late Uri base;
  late AccessTokenStore store;
  Uri? authorizeUrl;
  var browserStateSuffix = '';

  setUp(() async {
    authorizeUrl = null;
    browserStateSuffix = '';
    SharedPreferences.setMockInitialValues({});
    store = AccessTokenStore(await SharedPreferences.getInstance());
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
              'registration_endpoint': 'http://$host/register',
            }),
          );
      } else if (path == '/register') {
        await _read(req);
        response
          ..statusCode = HttpStatus.created
          ..write(jsonEncode({'client_id': 'dyn-client-1'}));
      } else if (path == '/token') {
        final form = Uri.splitQueryString(await _read(req));
        if (form['grant_type'] == 'authorization_code') {
          if (form['code'] != 'good-code') {
            response
              ..statusCode = HttpStatus.badRequest
              ..write(jsonEncode({'error': 'invalid_grant'}));
          } else {
            response
              ..statusCode = HttpStatus.ok
              ..write(
                jsonEncode({
                  'access_token': 'oauth:opaque-1',
                  'refresh_token': 'refresh-1',
                  'expires_in': 900,
                }),
              );
          }
        } else if (form['grant_type'] == 'refresh_token') {
          if (form['refresh_token'] == 'refresh-dead') {
            response
              ..statusCode = HttpStatus.badRequest
              ..write(
                jsonEncode({
                  'error': 'invalid_grant',
                  'error_description': 'ended',
                }),
              );
          } else {
            response
              ..statusCode = HttpStatus.ok
              ..write(
                jsonEncode({
                  'access_token': 'oauth:opaque-2',
                  'refresh_token': 'refresh-2',
                  'expires_in': 900,
                }),
              );
          }
        } else {
          response
            ..statusCode = HttpStatus.badRequest
            ..write(jsonEncode({'error': 'unsupported_grant_type'}));
        }
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  /// Simulates the user's browser: captures the IdP login URL, then
  /// performs the redirect back to the loopback with the code and state.
  Future<void> fakeBrowser(Uri url) async {
    authorizeUrl = url;
    final redirect = Uri.parse(url.queryParameters['redirect_uri']!).replace(
      queryParameters: {
        'code': 'good-code',
        'state': url.queryParameters['state']! + browserStateSuffix,
      },
    );
    final http = HttpClient();
    final request = await http.getUrl(redirect);
    final response = await request.close();
    await response.drain<void>();
    http.close(force: true);
  }

  AccessLoginRecord record({
    String accessToken = 'oauth:old',
    String? refreshToken = 'refresh-1',
    Duration age = const Duration(minutes: 1),
    Duration lifetime = const Duration(minutes: 15),
  }) => AccessLoginRecord(
    clientId: 'dyn-client-1',
    accessToken: accessToken,
    refreshToken: refreshToken,
    accessTokenExpiresAt: DateTime.now().subtract(age).add(lifetime),
  );

  test('restore: no persisted record stays logged out', () async {
    final session = AccessSession(
      tunnelBase: () => base,
      store: store,
      openBrowser: fakeBrowser,
    );
    await session.restore();
    expect(session.state, AccessLoginState.loggedOut);
  });

  test('restore: an unexpired record logs in without a browser', () async {
    store.save(base.host, record(age: const Duration(seconds: 30)));
    final session = AccessSession(
      tunnelBase: () => base,
      store: store,
      openBrowser: fakeBrowser,
    );
    await session.restore();
    expect(session.state, AccessLoginState.loggedIn);
    expect(await session.authorizationHeader(), 'Bearer oauth:old');
  });

  test('restore: an expired record without a refresh token logs out', () async {
    store.save(
      base.host,
      record(refreshToken: null, age: const Duration(minutes: 16)),
    );
    final session = AccessSession(
      tunnelBase: () => base,
      store: store,
      openBrowser: fakeBrowser,
    );
    await session.restore();
    expect(session.state, AccessLoginState.loggedOut);
    expect(store.recordFor(base.host), isNull);
  });

  test(
    'restore: an expired record with a refresh token stays logged in',
    () async {
      store.save(base.host, record(age: const Duration(minutes: 16)));
      final session = AccessSession(
        tunnelBase: () => base,
        store: store,
        openBrowser: fakeBrowser,
      );
      await session.restore();
      expect(session.state, AccessLoginState.loggedIn);
    },
  );

  test(
    'connect: the full browser flow logs in and persists the record',
    () async {
      final session = AccessSession(
        tunnelBase: () => base,
        store: store,
        openBrowser: fakeBrowser,
      );
      await session.connect();

      expect(session.state, AccessLoginState.loggedIn);
      expect(await session.authorizationHeader(), 'Bearer oauth:opaque-1');

      // The browser was pointed at the IdP with the registered client.
      final url = authorizeUrl!;
      expect(url.path, '/authorize');
      expect(url.queryParameters['client_id'], 'dyn-client-1');
      expect(
        url.queryParameters['redirect_uri'],
        startsWith('http://127.0.0.1:'),
      );
      expect(url.queryParameters['state'], isNotEmpty);

      // The record persists for the next app start.
      final record = store.recordFor(base.host)!;
      expect(record.clientId, 'dyn-client-1');
      expect(record.accessToken, 'oauth:opaque-1');
      expect(record.refreshToken, 'refresh-1');
    },
  );

  test('connect: a mismatched state rejects the redirect', () async {
    browserStateSuffix = '-tampered';
    final session = AccessSession(
      tunnelBase: () => base,
      store: store,
      openBrowser: fakeBrowser,
    );
    await expectLater(
      () => session.connect(),
      throwsA(
        isA<OAuthError>().having((e) => e.code, 'code', 'state_mismatch'),
      ),
    );
    expect(session.state, AccessLoginState.loggedOut);
    expect(store.recordFor(base.host), isNull);
  });

  test('the silent refresh runs proactively before the expiry', () async {
    store.save(
      base.host,
      record(age: const Duration(minutes: 14, seconds: 35)),
    );
    final session = AccessSession(
      tunnelBase: () => base,
      store: store,
      openBrowser: fakeBrowser,
    );
    await session.restore();
    expect(await session.authorizationHeader(), 'Bearer oauth:opaque-2');
    expect(store.recordFor(base.host)!.accessToken, 'oauth:opaque-2');
  });

  test('a 401 (forceRefresh) refreshes even an unexpired token', () async {
    store.save(base.host, record(age: const Duration(seconds: 30)));
    final session = AccessSession(
      tunnelBase: () => base,
      store: store,
      openBrowser: fakeBrowser,
    );
    await session.restore();
    expect(
      await session.authorizationHeader(forceRefresh: true),
      'Bearer oauth:opaque-2',
    );
  });

  test('an ended grant session logs out and drops the record', () async {
    store.save(base.host, record(refreshToken: 'refresh-dead'));
    final session = AccessSession(
      tunnelBase: () => base,
      store: store,
      openBrowser: fakeBrowser,
    );
    await session.restore();
    expect(await session.authorizationHeader(forceRefresh: true), isNull);
    expect(session.state, AccessLoginState.loggedOut);
    expect(store.recordFor(base.host), isNull);
  });

  test('logout drops the record and logs out', () async {
    store.save(base.host, record(age: const Duration(seconds: 30)));
    final session = AccessSession(
      tunnelBase: () => base,
      store: store,
      openBrowser: fakeBrowser,
    );
    await session.restore();
    await session.logout();
    expect(session.state, AccessLoginState.loggedOut);
    expect(store.recordFor(base.host), isNull);
    expect(await session.authorizationHeader(), isNull);
  });

  test('listeners see the connect transitions', () async {
    final session = AccessSession(
      tunnelBase: () => base,
      store: store,
      openBrowser: fakeBrowser,
    );
    final seen = <AccessLoginState>[];
    session.addListener((state) => seen.add(state));
    await session.connect();
    expect(seen, [AccessLoginState.connecting, AccessLoginState.loggedIn]);
  });

  test(
    'connect reads the tunnel base at call time, not construction',
    () async {
      var current = Uri.parse('http://127.0.0.1:1/'); // a dead endpoint
      final session = AccessSession(
        tunnelBase: () => current,
        store: store,
        openBrowser: fakeBrowser,
      );
      // The user commits the URL before clicking Connect.
      current = base;
      await session.connect();
      expect(session.state, AccessLoginState.loggedIn);
      expect(store.recordFor(base.host), isNotNull);
    },
  );
}

Future<String> _read(HttpRequest request) async {
  final bytes = <int>[];
  await for (final chunk in request) {
    bytes.addAll(chunk);
  }
  return const Utf8Decoder().convert(bytes);
}
