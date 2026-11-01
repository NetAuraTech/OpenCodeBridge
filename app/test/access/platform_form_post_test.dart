import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/access/platform_form_post.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('opencodebridge/form_post');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final url = Uri.parse('https://idp.example/cdn-cgi/access/oauth/token');

  void mockHandler(Future<Object?>? Function(MethodCall)? handler) {
    messenger.setMockMethodCallHandler(channel, handler);
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('posts the urlencoded form and returns the answer', () async {
    MethodCall? call;
    mockHandler((captured) async {
      call = captured;
      return {'status': 200, 'body': '{"access_token":"oauth:opaque-1"}'};
    });
    final (status, body) = await PlatformFormPost.post(
      url,
      Uri(queryParameters: {'grant_type': 'refresh_token', 'b': '2'}).query,
    );
    expect(status, 200);
    expect(body, '{"access_token":"oauth:opaque-1"}');
    expect(call?.method, 'postForm');
    expect(call?.arguments, {
      'url': url.toString(),
      'form': 'grant_type=refresh_token&b=2',
    });
  });

  test(
    'an error answer comes back as status plus raw body, not a throw',
    () async {
      mockHandler(
        (call) async => {'status': 500, 'body': '<html>error</html>'},
      );
      final (status, body) = await PlatformFormPost.post(url, 'a=1');
      expect(status, 500);
      expect(body, '<html>error</html>');
    },
  );

  test('a platform network failure is a PlatformException', () async {
    mockHandler(
      (call) async => throw PlatformException(code: 'network', message: 'boom'),
    );
    await expectLater(
      () => PlatformFormPost.post(url, 'a=1'),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'network',
        ),
      ),
    );
  });

  test('without a platform handler the Dart fallback is triggered', () async {
    mockHandler(null);
    await expectLater(
      () => PlatformFormPost.post(url, 'a=1'),
      throwsA(isA<MissingPluginException>()),
    );
  });
}
