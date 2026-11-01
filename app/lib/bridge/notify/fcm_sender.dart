import 'package:firebase_admin_sdk/firebase_admin_sdk.dart';
import 'package:firebase_admin_sdk/messaging.dart';

import '../../notify/deep_link.dart';
import 'firebase_service_account.dart';

/// Sends one push (issue #24). The [FcmSender.send.link] is the tap target
/// the app opens (a [DeepLink] URI); it rides in the message's `data`
/// payload.
abstract class FcmSender {
  /// Sends one push to [token], titled [title] with body [body].
  /// Implementations throw on a delivery failure.
  Future<void> send({
    required String token,
    required String title,
    required String body,
    required String link,
  });

  /// Releases the sender's resources (the bridge's `close`); a no-op by
  /// default, overridden by the senders that own a client.
  Future<void> close() async {}
}

/// The default sender: the Firebase Admin SDK for Dart (issue #24). The
/// SDK owns the OAuth2 (one-hour access tokens, auto-refresh); the bridge
/// just builds one `TokenMessage` per registered device.
class FirebaseAdminFcmSender extends FcmSender {
  FirebaseAdminFcmSender._(this._app);

  /// Initializes the SDK on [account]'s service account. The app is named
  /// (not the default one) so it never collides with another Firebase app
  /// in the process, and initializes once per bridge (the registry returns
  /// the existing app on a repeated call with matching options).
  static FirebaseAdminFcmSender forServiceAccount(
    FirebaseServiceAccount account,
  ) {
    final app = FirebaseApp.initializeApp(
      options: AppOptions(
        credential: Credential.fromServiceAccountParams(
          privateKey: account.privateKey,
          email: account.email,
          projectId: account.projectId,
        ),
        projectId: account.projectId,
      ),
      name: 'opencodebridge-bridge',
    );
    return FirebaseAdminFcmSender._(app);
  }

  final FirebaseApp _app;

  @override
  Future<void> send({
    required String token,
    required String title,
    required String body,
    required String link,
  }) async {
    final messaging = _app.messaging();
    await messaging.send(
      TokenMessage(
        token: token,
        notification: Notification(title: title, body: body),
        // The tap target: the app opens this deep link on notification tap.
        data: {'link': link},
      ),
    );
  }
}
