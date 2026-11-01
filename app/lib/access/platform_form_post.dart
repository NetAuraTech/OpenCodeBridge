import 'package:flutter/services.dart';

/// One `application/x-www-form-urlencoded` POST executed by the Android
/// platform (issue #41).
///
/// Cloudflare's beta Managed OAuth 500s the token endpoint for the Dart
/// SDK's TLS fingerprint (the byte-identical form that `curl` gets a 200
/// for answers 500 from `HttpClient` — issue #23 field test, Ray
/// a534fa469e03f52a), and Android has no `curl` on the PATH. The token
/// grant therefore rides the platform's own HTTP stack, whose TLS
/// fingerprint is the stock Android one — the one Cloudflare does not
/// 500.
///
/// Throws a [MissingPluginException] when the platform handler is absent
/// (not Android) — the caller then falls back to the Dart client.
///
/// Throws a [PlatformException] (code `network`) when the exchange could
/// not complete: the network-level reason in its message.
class PlatformFormPost {
  const PlatformFormPost._();

  /// Must match the channel the Android handler is registered on
  /// (MainActivity.kt).
  static const MethodChannel _channel = MethodChannel(
    'opencodebridge/form_post',
  );

  /// POST [form] (already urlencoded) to [url]; returns the status and the
  /// raw body, whatever the status is.
  static Future<(int, String)> post(Uri url, String form) async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>('postForm', {
      'url': url.toString(),
      'form': form,
    });
    final status = raw?['status'];
    if (status is! int) {
      throw PlatformException(
        code: 'network',
        message: 'the platform did not report a status',
      );
    }
    return (status, raw?['body'] as String? ?? '');
  }
}
