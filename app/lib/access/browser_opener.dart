import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a URL in the user's default browser (issue #23, step 3: the IdP
/// login is a browser flow).
typedef BrowserOpener = Future<void> Function(Uri url);

/// The [BrowserOpener] for the platform this app runs on (issue #41): the
/// device's browser on Android, the desktop's default opener elsewhere.
BrowserOpener defaultBrowserOpener() {
  return defaultTargetPlatform == TargetPlatform.android
      ? openInDeviceBrowser
      : openInBrowser;
}

/// Opens [url] in the user's default browser on the device (issue #41):
/// Android has no `xdg-open`, so the Access login — the IdP login is a
/// browser flow — opens in the device's browser through the platform
/// channel. The browser runs on the same device, so the loopback redirect
/// (the OAuth redirect server binds `127.0.0.1`) still comes back to the
/// app.
Future<void> openInDeviceBrowser(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

/// Opens [url] in the user's default browser (issue #23, step 3: the IdP
/// login — email one-time passcode or Google — is a browser flow, not
/// something the app embeds).
///
/// Desktop Linux: hands the URL to the desktop's default opener. The
/// process exits right after handing off; its streams are drained so a
/// full pipe cannot hold it up.
Future<void> openInBrowser(Uri url) async {
  final process = await Process.start('xdg-open', [url.toString()]);
  unawaited(process.stdout.drain<void>());
  unawaited(process.stderr.drain<void>());
  await process.exitCode;
}
