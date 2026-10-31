import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/access/curl_form_post.dart';

void main() {
  var curlOnPath = false;
  late HttpServer server;
  late Uri url;
  late Map<String, String?> lastForm;
  late int tokenStatus;
  late String tokenBody;

  setUpAll(() async {
    try {
      await Process.run('curl', ['--version']);
      curlOnPath = true;
    } on ProcessException {
      curlOnPath = false;
    }
  });

  setUp(() async {
    lastForm = {};
    tokenStatus = HttpStatus.ok;
    tokenBody = '{"access_token":"oauth:opaque-1"}';
    server = await HttpServer.bind('127.0.0.1', 0);
    url = Uri.parse('http://127.0.0.1:${server.port}/token');
    server.listen((req) async {
      final raw = await _read(req);
      if (req.uri.path == '/token') {
        lastForm = Uri.splitQueryString(raw);
      }
      req.response
        ..statusCode = tokenStatus
        ..write(tokenBody);
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  void curlTest(String description, Future<void> Function() body) {
    test(description, () async {
      // No curl on this machine: the Dart-client fallback, which the
      // transport-agnostic client tests cover.
      if (!curlOnPath) return;
      await body();
    });
  }

  curlTest(
    'posts the urlencoded form on stdin and returns the answer',
    () async {
      final (status, body) = await CurlFormPost.post(
        url,
        Uri(queryParameters: {'a': 'x y', 'b': '2'}).query,
      );
      expect(status, HttpStatus.ok);
      expect(jsonDecode(body)['access_token'], 'oauth:opaque-1');
      expect(lastForm['a'], 'x y');
      expect(lastForm['b'], '2');
    },
  );

  curlTest(
    'an error answer comes back as status plus raw body, not a throw',
    () async {
      tokenStatus = HttpStatus.internalServerError;
      tokenBody = '<html>Internal Server Error</html>';
      final (status, body) = await CurlFormPost.post(url, 'a=1');
      expect(status, HttpStatus.internalServerError);
      expect(body, '<html>Internal Server Error</html>');
    },
  );

  curlTest('an unreachable endpoint is a CurlPostFailure', () async {
    final closed = await HttpServer.bind('127.0.0.1', 0);
    final dead = Uri.parse('http://127.0.0.1:${closed.port}/token');
    await closed.close(force: true);
    await expectLater(
      () => CurlFormPost.post(dead, 'a=1'),
      throwsA(isA<CurlPostFailure>()),
    );
  });
}

Future<String> _read(HttpRequest request) async {
  final bytes = <int>[];
  await for (final chunk in request) {
    bytes.addAll(chunk);
  }
  return const Utf8Decoder().convert(bytes);
}
