import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/access/browser_opener.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('defaultBrowserOpener (issue #41)', () {
    test('on Android it selects the device browser, not xdg-open', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      expect(identical(defaultBrowserOpener(), openInDeviceBrowser), isTrue);
      expect(identical(defaultBrowserOpener(), openInBrowser), isFalse);
    });

    test('on desktop it selects the desktop default opener (xdg-open)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      expect(identical(defaultBrowserOpener(), openInBrowser), isTrue);
      expect(identical(defaultBrowserOpener(), openInDeviceBrowser), isFalse);
    });
  });

  group('openInDeviceBrowser (issue #41)', () {
    test(
      'hands the URL to the device browser over the platform channel',
      () async {
        final binding = TestWidgetsFlutterBinding.instance;
        const channel = MethodChannel('plugins.flutter.io/url_launcher');
        final launched = <String>[];
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          if (call.method == 'launch') {
            launched.add((call.arguments as Map)['url'] as String);
            return true;
          }
          return false;
        });

        await openInDeviceBrowser(Uri.parse('https://auth.example.com/login'));

        expect(launched, ['https://auth.example.com/login']);
      },
    );
  });
}
