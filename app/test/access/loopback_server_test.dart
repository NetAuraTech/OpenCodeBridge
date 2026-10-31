import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/access/loopback_server.dart';

void main() {
  group('OAuthLoopbackServer', () {
    late OAuthLoopbackServer server;
    late Uri callback;

    setUp(() async {
      server = await OAuthLoopbackServer.start();
      callback = server.redirectUri;
    });

    tearDown(() async {
      await server.close();
    });

    test('exposes the loopback redirect URI at an ephemeral port', () {
      expect(callback.scheme, 'http');
      expect(callback.host, '127.0.0.1');
      expect(callback.port, greaterThan(0));
      expect(callback.path, '/callback');
    });

    test('captures the code and state from the IdP redirect', () async {
      final wait = server.waitForRedirect(const Duration(seconds: 5));
      final response = await _get('$callback?code=the-code&state=the-state');
      expect(response.statusCode, HttpStatus.ok);
      expect(response.body, contains('Login complete'));

      final redirect = await wait;
      expect(redirect.code, 'the-code');
      expect(redirect.state, 'the-state');
    });

    test('an absent state is captured as empty', () async {
      final wait = server.waitForRedirect(const Duration(seconds: 5));
      await _get('$callback?code=only-code');
      final redirect = await wait;
      expect(redirect.code, 'only-code');
      expect(redirect.state, '');
    });

    test(
      'a redirect without a code fails with 400 and is not captured',
      () async {
        final wait = server.waitForRedirect(const Duration(seconds: 1));
        final response = await _get('$callback');
        expect(response.statusCode, HttpStatus.badRequest);
        expect(response.body, contains('did not complete'));

        await expectLater(wait, throwsA(isA<TimeoutException>()));
      },
    );

    test(
      'the first redirect wins; a late one is answered but ignored',
      () async {
        final wait = server.waitForRedirect(const Duration(seconds: 5));
        await _get('$callback?code=first&state=s1');
        await _get('$callback?code=second&state=s2');

        final redirect = await wait;
        expect(redirect.code, 'first');
      },
    );

    test('a redirect that arrives before the wait is still captured', () async {
      final response = await _get('$callback?code=early&state=s0');
      expect(response.statusCode, HttpStatus.ok);

      final redirect = await server.waitForRedirect(const Duration(seconds: 5));
      expect(redirect.code, 'early');
      expect(redirect.state, 's0');
    });

    test('a late redirect cannot complete a timed-out wait', () async {
      final wait = server.waitForRedirect(const Duration(milliseconds: 50));
      await expectLater(() => wait, throwsA(isA<TimeoutException>()));
      // The redirect still arrives at the server: it is answered, but the
      // timed-out wait is not resurrected.
      final response = await _get('$callback?code=late&state=s');
      expect(response.statusCode, HttpStatus.ok);
    });
  });
}

Future<_Response> _get(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    final body = await response.transform(const Utf8Decoder()).join();
    return _Response(response.statusCode, body);
  } finally {
    client.close(force: true);
  }
}

class _Response {
  const _Response(this.statusCode, this.body);

  final int statusCode;
  final String body;
}
