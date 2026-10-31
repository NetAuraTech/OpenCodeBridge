import 'dart:io';

/// Provides the `Authorization` header value (the full
/// `Bearer <opaque token>`) for requests to one bridge, or `null` when
/// there is no active login.
///
/// When [forceRefresh] is true — a `401` was just received — the provider
/// must attempt a silent token refresh before answering. (Issue #23,
/// Cloudflare Access Managed OAuth: the token is opaque, short-lived, and
/// refreshed until the grant session ends.)
typedef AuthHeaderProvider = Future<String?> Function({bool forceRefresh});

/// Performs one HTTP request against the bridge with Access authentication
/// (issue #23): when [auth] is present, attaches its `Authorization` header
/// (a proactive refresh happens inside the provider, so the header is
/// current), and on a `401` asks for a refreshed header and retries the
/// request once. The retry's status — even another `401` — is returned to
/// the caller, which decides the error.
///
/// The caller owns [client] (and closes it after the response is consumed);
/// both attempts run on it.
Future<HttpClientResponse> bridgeRequest(
  HttpClient client,
  String method,
  Uri uri, {
  String? body,
  ContentType? contentType,
  AuthHeaderProvider? auth,
}) async {
  Future<HttpClientResponse> attempt({required bool forceRefresh}) async {
    final request = await client.openUrl(method, uri);
    if (contentType != null) request.headers.contentType = contentType;
    // The header must be set before the body is written: writing flushes it.
    final header = auth == null ? null : await auth(forceRefresh: forceRefresh);
    if (header != null) request.headers.set('Authorization', header);
    if (body != null) request.write(body);
    return request.close();
  }

  var response = await attempt(forceRefresh: false);
  if (response.statusCode == HttpStatus.unauthorized && auth != null) {
    await response.drain<void>();
    response = await attempt(forceRefresh: true);
  }
  return response;
}
