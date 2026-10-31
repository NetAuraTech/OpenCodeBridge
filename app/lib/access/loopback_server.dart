import 'dart:async';
import 'dart:io';

/// The code and state the IdP's redirect carried back to the app
/// (issue #23, step 3: the browser opens the IdP login, then is
/// redirected to this loopback address with the authorization code).
class RedirectCallback {
  const RedirectCallback({required this.code, required this.state});

  final String code;
  final String state;
}

/// The app's own OAuth redirect URI receiver (issue #23): a one-shot
/// [HttpServer] on `127.0.0.1` at an ephemeral port, registered as the
/// dynamic-client loopback redirect URI. The IdP's browser lands here with
/// `?code=…&state=…`; the user sees a completion page and closes it.
///
/// Only the first request is captured; later ones get the same completion
/// page (the app-side state check rejects a replayed or stale redirect).
class OAuthLoopbackServer {
  OAuthLoopbackServer._(this._server);

  final HttpServer _server;
  Completer<RedirectCallback>? _pending;
  RedirectCallback? _captured;

  /// The redirect URI to register as the client's loopback redirect:
  /// `http://127.0.0.1:<port>/callback`.
  Uri get redirectUri => Uri.parse('http://127.0.0.1:${_server.port}/callback');

  static Future<OAuthLoopbackServer> start() async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final loopback = OAuthLoopbackServer._(server);
    server.listen(loopback._handleRequest);
    return loopback;
  }

  /// Waits for the IdP's redirect, up to [timeout]. The first redirect
  /// wins; a late one is answered but ignored.
  Future<RedirectCallback> waitForRedirect(Duration timeout) {
    final captured = _captured;
    if (captured != null) return Future.value(captured);
    Completer<RedirectCallback>? pending = _pending;
    if (pending == null) {
      pending = Completer<RedirectCallback>();
      _pending = pending;
    }
    return pending.future.timeout(
      timeout,
      onTimeout: () {
        if (identical(_pending, pending)) _pending = null;
        throw TimeoutException('the IdP redirect never arrived', timeout);
      },
    );
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handleRequest(HttpRequest request) async {
    final code = request.uri.queryParameters['code'];
    final state = request.uri.queryParameters['state'];
    final response = request.response;
    if (code != null) {
      _complete(RedirectCallback(code: code, state: state ?? ''));
      response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.parse('text/html; charset=utf-8');
      response.write(_completionPage);
    } else {
      // A redirect without a code: the IdP errored in the browser.
      response
        ..statusCode = HttpStatus.badRequest
        ..headers.contentType = ContentType.parse('text/html; charset=utf-8');
      response.write(_failurePage);
    }
    await response.close();
  }

  void _complete(RedirectCallback callback) {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.complete(callback);
      return;
    }
    // No waiter yet (the redirect beat waitForRedirect): keep the first one
    // so a later wait still wins; a second late one is dropped.
    _captured ??= callback;
  }
}

/// Shown in the browser once the code has been delivered to the app.
const String _completionPage = '''
<!DOCTYPE html>
<html>
  <body style="font-family: sans-serif; padding: 2rem">
    <h2>OpenCodeBridge</h2>
    <p>Login complete. You can close this window and return to the app.</p>
  </body>
</html>
''';

/// Shown in the browser when the redirect carried no code.
const String _failurePage = '''
<!DOCTYPE html>
<html>
  <body style="font-family: sans-serif; padding: 2rem">
    <h2>OpenCodeBridge</h2>
    <p>Login did not complete. Return to the app and try again.</p>
  </body>
</html>
''';
