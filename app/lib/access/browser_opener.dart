import 'dart:async';
import 'dart:io';

/// Opens a URL in the user's default browser (issue #23, step 3: the IdP
/// login is a browser flow).
typedef BrowserOpener = Future<void> Function(Uri url);

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
