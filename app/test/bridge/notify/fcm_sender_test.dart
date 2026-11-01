import 'dart:convert';

import 'package:firebase_admin_sdk/firebase_admin_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/notify/fcm_sender.dart';
import 'package:opencodebridge/bridge/notify/firebase_service_account.dart';

/// A real RSA PEM: `Credential.fromServiceAccountParams` parses it at
/// construction. No delivery happens in these tests (no `send` calls), so
/// the key never leaves the process.
const String kPrivateKey =
    "-----BEGIN PRIVATE KEY-----\n"
    "MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQC8eiyvZu7imXnx\n"
    "ydajqaGBuR5yVYDtWpqvJJHWeWREipAJXTS/00Rf9nR2/tRC0ttrb95U2q2dCPPj\n"
    "kzoyH6O7XMjEm8zjBFYrHQEcbLH53m/5+RaAa7FOXaozM5IILu157Sc6cuB3dhiH\n"
    "otlUTZpoaM76jD7nEFckw/z9B1f7qBW2KqGWYrIdF2+RyGVMEEYOkQrQrmmW5BUu\n"
    "pXfe7TzbAnmmC0l8IQ3+UUSSiLTEsu0PlOhh298577P0HezEjYddzj4gY0OgFSHQ\n"
    "hfRvkC5PXyXVBUfsdo/5D+vuSkNrjxz+iszP8NHRFTx5H7nz4baXcx5VFtfn5iFU\n"
    "qstmMBEpAgMBAAECggEAAkQOPjgUsl7xuTtJ1CsdhNGYyPtX6tKSZj1gbvWD4/KN\n"
    "/3zSPeWgbm5oMUeIPfrqtiCQydCcsnT5eKCMHC7m8SFRDRMJ7CdA0XEecqzoWVaI\n"
    "HldVIstYpPZpjcbGkEhfJL56AKEBq5H9AsFtjy7FJtDuvxKZTX4T7B5aj+CrGTyD\n"
    "aKR/I1IUmtzzX4j9WpbOBMG6OlinhxKzt4/7FDJzxx37X0KjDVvUh0issWt35HO+\n"
    "0F0ea0xltv9cAsZRBh5bheQMY3bQOcUb/zQO7bCzL4fRvkiFylQxFjt/MKgMRbjP\n"
    "apEWYRZM0d9Hfp4IgoMj8joMn1DPXL33Y8R5L+YhoQKBgQDiT+k+kOzIfYq9dsNS\n"
    "IPtIQml6WHR62P5IQvWT0hRf4O6LTWtKd6oU4HMBDnf5xwGzA8UeigU8Mj+/763n\n"
    "XPjHbOCkE1Ckz8O5iVPx2hHlhx8Ythqpj5iqkrzqEXN6WdFRAda0AIvI4LNv9Tzm\n"
    "H0femnWbCf7h0tiUuyH+w7q0yQKBgQDVM63ccKfFp/rEtkwQ/XWz5dMrjnszwUZ+\n"
    "PltS6d3yw8/xrd/IbngQ1vf7G7ZMyUDg+zjE39FvCSAXEMzaQFglW9iDQvw4Wqrr\n"
    "KWf8aS47D30B6wuTFErlI9mXhZnDatM80Qphx73FA67PBr2KqsI6pWJJ3bziSRi3\n"
    "X4oIVyKJYQKBgG1Ih2pmE2FRdlC9a95Z/N3M7CBfXIgCBvCgHPRvytTtymNMVFYW\n"
    "aPRB2mcVNIxSNBjc5jA0GAkUfsJRnBmQRLYQdn3ksdmUVoBet0Gfu2qqEDMfpMpi\n"
    "hCdCSqWBHdFkU/aZO7OaW+X508xpkSnSyyLMVaQzdHhaF6nin6zlmWA5AoGAFqYA\n"
    "yDQnfnXTy+XZusxSHqRBhJUEPYFArdSN+wbhDxMCGhhwd2hU1OUhPsm42ftfKwdF\n"
    "BpUIOJVtlUWxnVXMh1t0aq1JAeuP0J97bnL1+Ewy6WtAtYUoV6MxUElfBkVo30MN\n"
    "qUmAvVcg0NlUdVCihXxgLpyhniBJweEiVrR69MECgYA07ebbgc3GBvHCIrcBMsrO\n"
    "bdFMCyh1yOTizML7qtoQKInrj0Y0yM0TX/Q4vdZFtepy89BTCA4RfOYg5xUB65Yw\n"
    "LMso5I/CHT5MsSAAlO7GyGWCDWRnZbg9Q5AuQLDrWjy8shiRvFyTncgzYeGXExSr\n"
    "PpRSVDvtElyBUiljh0ZkkQ==\n"
    "-----END PRIVATE KEY-----";

FirebaseServiceAccount _account(String project) =>
    FirebaseServiceAccount.fromJsonString(jsonEncode({
      'type': 'service_account',
      'project_id': project,
      'private_key': kPrivateKey,
      'client_email': 'svc@$project.iam.gserviceaccount.com',
      'client_id': '1234567890',
      'token_uri': 'https://oauth2.googleapis.com/token',
    }))!;

/// The named app the bridge's sender lives under.
const String _appName = 'opencodebridge-bridge';

List<FirebaseApp> _bridgeApps() =>
    FirebaseApp.apps.where((app) => app.name == _appName).toList();

void main() {
  test('forServiceAccount initializes the named app', () async {
    await FirebaseAdminFcmSender.forServiceAccount(_account('project-a'));

    expect(_bridgeApps().length, 1);
  });

  test('a reload with a changed account replaces the app', () async {
    // A second account under the same app name: the registry refuses a
    // second app under one name, so the sender must replace the live one
    // (the bridge's reloadNotify flow, issue #24).
    await FirebaseAdminFcmSender.forServiceAccount(_account('project-a'));
    await FirebaseAdminFcmSender.forServiceAccount(_account('project-b'));

    expect(_bridgeApps().length, 1);
  });
}
