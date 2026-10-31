import 'dart:convert';
import 'dart:io';

/// `curl` ran but could not complete the HTTP exchange (DNS, connection
/// refused, timeout).
class CurlPostFailure implements Exception {
  const CurlPostFailure(this.message);

  /// `curl`'s own stderr: the network-level reason.
  final String message;

  @override
  String toString() => 'CurlPostFailure($message)';
}

/// One `application/x-www-form-urlencoded` POST executed with the system
/// `curl` (issue #23).
///
/// Cloudflare's beta Managed OAuth 500s the token endpoint for the Dart
/// SDK's TLS fingerprint: the byte-identical form that `curl` gets a 200
/// for answers 500 from `HttpClient` (field test, Ray
/// a534fa469e03f52a). The token grants therefore ride `curl` while
/// discovery and registration keep the Dart client.
class CurlFormPost {
  const CurlFormPost._();

  /// What `-w` appends to stdout; the last occurrence on its own line is
  /// ours, whatever the body contained.
  static const String _statusMarker = 'CURL_STATUS=';

  /// POST [form] (already urlencoded) to [url]; returns the status and the
  /// raw body, whatever the status is.
  ///
  /// Throws a [ProcessException] when `curl` is not on the PATH (the caller
  /// then falls back to the Dart client).
  static Future<(int, String)> post(Uri url, String form) async {
    final process = await Process.start('curl', [
      '-sS', // no progress meter; failures land on stderr
      '--max-time',
      '30',
      '-X',
      'POST',
      url.toString(),
      '-H',
      'content-type: application/x-www-form-urlencoded',
      '--data',
      '@-', // the form arrives on stdin, never in argv
      '-w',
      '\n$_statusMarker%{http_code}',
    ]);
    process.stdin.write(form);
    await process.stdin.close();
    final stdout = await process.stdout.transform(const Utf8Decoder()).join();
    final stderr = await process.stderr.transform(const Utf8Decoder()).join();
    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      throw CurlPostFailure(stderr.trim().replaceAll('\n', ' '));
    }
    final marker = stdout.lastIndexOf('\n$_statusMarker');
    if (marker < 0) {
      throw const CurlPostFailure('curl did not report its status');
    }
    final statusText = stdout
        .substring(marker + 1 + _statusMarker.length)
        .split('\n')
        .first
        .trim();
    final status = int.tryParse(statusText);
    if (status == null) {
      throw const CurlPostFailure('curl did not report a numeric status');
    }
    return (status, stdout.substring(0, marker));
  }
}
