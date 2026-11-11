import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/notify/deep_link.dart';
import 'package:opencodebridge/notify/notification_service.dart';
import 'package:opencodebridge/settings/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A tapped notification's data payload: the deep link under `link`.
RemoteMessage _message(String id) =>
    RemoteMessage(data: {'link': DeepLink.sessionUri(id).toString()});

void main() {
  late AppSettings settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await AppSettings.load();
  });

  NotificationService makeService() => NotificationService(
    settings: settings,
    bridgeBase: Uri.parse('http://127.0.0.1:1/'),
  );

  group('NotificationService.deepLinks', () {
    test('a tap before any listener is buffered and replayed on listen', () {
      final service = makeService();
      service.openForTest(_message('ses_early'));
      // The replay is one microtask after the listen (a broadcast
      // controller must not deliver inside onListen); `.first` delivers
      // that replayed link to the freshly attached listener.
      return expectLater(
        service.deepLinks.first,
        completion(DeepLink.session('ses_early')),
      );
    });

    test('a listener receives a tap that arrives while it listens', () {
      final service = makeService();
      final got = Completer<DeepLink>();
      final sub = service.deepLinks.listen(got.complete);
      service.openForTest(_message('ses_live'));
      return expectLater(
        got.future,
        completion(DeepLink.session('ses_live')),
      ).then((_) => sub.cancel());
    });

    test('remounts: a second listener attaches to the same stream after the '
        'first cancels, without a `Bad state`', () {
      // The remount scenario: the shell listens, the tap arrives (the shell
      // handles it), the shell is disposed, and a fresh shell instance
      // listens again on the same stream object. The stream must accept the
      // second listener (the old single-subscription stream threw
      // `Bad state: Stream has already been listened to.` here).
      final service = makeService();
      final firstGot = Completer<DeepLink>();
      final first = service.deepLinks.listen(firstGot.complete);
      service.openForTest(_message('ses_first'));

      return expectLater(
        firstGot.future,
        completion(DeepLink.session('ses_first')),
      ).then((_) async {
        await first.cancel();

        // A fresh listener on the very same stream object: no throw, and it
        // receives the links that arrive while it listens.
        final secondGot = Completer<DeepLink>();
        final second = service.deepLinks.listen(secondGot.complete);
        service.openForTest(_message('ses_second'));
        await expectLater(
          secondGot.future,
          completion(DeepLink.session('ses_second')),
        );
        await second.cancel();
      });
    });
  });
}
