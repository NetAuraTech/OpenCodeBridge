import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// The Cloudflare Access application's OAuth metadata (issue #23, step 1:
/// RFC 8414/9728 discovery at `/.well-known/oauth-authorization-server`
/// on the tunnel hostname). The Access application is the authorization
/// server; the app is a plain OAuth client.
class AccessMetadata {
  const AccessMetadata({
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.registrationEndpoint,
  });

  /// Where the user's browser is sent for the IdP login.
  final Uri authorizationEndpoint;

  /// Where the code exchange and the silent token refresh are posted.
  final Uri tokenEndpoint;

  /// Dynamic client registration (RFC 8707); `null` when the Access
  /// application does not offer it (the login flow cannot proceed).
  final Uri? registrationEndpoint;
}

/// One opaque token pair issued by the Access token endpoint (issue #23,
/// step 4): the short-lived access token (sent as `Authorization: Bearer`)
/// plus the refresh token that stays valid until the grant session ends.
class AccessTokens {
  const AccessTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.acquiredAt,
  });

  /// The opaque token for `Authorization: Bearer <token>`.
  final String accessToken;

  /// The refresh token; silent refresh is impossible without it (then the
  /// login ends with the access token's expiry, not the grant session's).
  final String? refreshToken;

  /// The access token's lifetime as the token endpoint declared it.
  final Duration expiresIn;

  /// When this pair was received.
  final DateTime acquiredAt;

  /// When the access token stops being valid.
  DateTime get expiresAt => acquiredAt.add(expiresIn);

  /// Whether [now] is past the expiry, or within [skew] of it (refresh
  /// early so an in-flight expiry cannot cut a request).
  bool isExpired(DateTime now, {Duration skew = const Duration(seconds: 30)}) =>
      !now.isBefore(expiresAt.subtract(skew));
}

/// A rejection from the Access token/registration endpoints, carrying the
/// OAuth `error` code (RFC 6749 §30; `invalid_grant` covers an ended grant
/// session).
class OAuthError implements Exception {
  const OAuthError(this.code, [this.description]);

  /// The RFC 6749 `error` value, or `http_<status>` when the endpoint
  /// answered without one.
  final String code;

  /// The endpoint's `error_description`, when given.
  final String? description;

  /// The grant session ended: the refresh token is dead, re-login is the
  /// only way back.
  bool get grantEnded =>
      code == 'invalid_grant' ||
      code == 'invalid_client' ||
      code == 'unauthorized_client';

  @override
  String toString() =>
      'OAuthError($code${description == null ? '' : ': $description'})';
}

/// The app as an OAuth client of the tunnel's Cloudflare Access application
/// (issue #23): discovery, dynamic client registration (RFC 8707), the
/// authorization URL for the browser login, the code exchange, and the
/// silent refresh.
///
/// [base] is the tunnel URL the Access application fronts
/// (e.g. `https://bridge.example.com`).
class AccessOAuthClient {
  AccessOAuthClient(this._base);

  final Uri _base;

  AccessMetadata? _metadata;

  /// The in-flight PKCE code verifier (RFC 7636); a public client must
  /// present it in the code exchange to claim its challenge.
  String? _codeVerifier;

  /// Step 1: `GET /.well-known/oauth-authorization-server`.
  Future<AccessMetadata> discover() async {
    final Map<String, Object?> raw;
    try {
      raw = await _httpJson(
        'GET',
        _base.replace(path: '.well-known/oauth-authorization-server'),
      );
    } on OAuthError catch (error) {
      if (error.code != 'bad_response') rethrow;
      // A web page where JSON was expected: without Managed OAuth the
      // Access app redirects non-browser clients to its login page (and
      // HttpClient follows the redirect), so discovery answers HTML.
      throw const OAuthError(
        'discovery_failed',
        'the endpoint answered a web page, not JSON: enable Managed OAuth '
            'on the Access application (dashboard: Access controls > '
            'Applications > <app> > Edit > Advanced settings > Managed '
            'OAuth), and allow loopback clients for the browser login',
      );
    }
    final authorization = raw['authorization_endpoint'];
    final token = raw['token_endpoint'];
    final registration = raw['registration_endpoint'];
    if (authorization is! String || token is! String) {
      throw const OAuthError(
        'discovery_failed',
        'the tunnel does not look like a Cloudflare Access app '
            'with Managed OAuth enabled',
      );
    }
    return _metadata = AccessMetadata(
      authorizationEndpoint: Uri.parse(authorization),
      tokenEndpoint: Uri.parse(token),
      registrationEndpoint: registration is String
          ? Uri.parse(registration)
          : null,
    );
  }

  /// Step 2: dynamic client registration (RFC 8707) with the loopback
  /// redirect URI; returns the registered `client_id`.
  Future<String> registerClient(String redirectUri) async {
    final metadata = await discover();
    final registration = metadata.registrationEndpoint;
    if (registration == null) {
      throw const OAuthError(
        'registration_unavailable',
        'dynamic client registration is not enabled on the Access app',
      );
    }
    final raw = await _httpJson(
      'POST',
      registration,
      body: jsonEncode({
        'client_name': 'OpenCodeBridge',
        'redirect_uris': [redirectUri],
        'grant_types': ['authorization_code', 'refresh_token'],
        'response_types': ['code'],
        // A public client: no secret, the browser login plus PKCE below.
        'token_endpoint_auth_method': 'none',
        // RFC 8707: bind the registration to the resource the tokens will
        // be used against, so the token endpoint can enforce it.
        'resource': _base.toString(),
      }),
    );
    final clientId = raw['client_id'];
    if (clientId is! String || clientId.isEmpty) {
      throw const OAuthError(
        'registration_failed',
        'the Access app did not return a client id',
      );
    }
    return clientId;
  }

  /// Step 3: the URL to open in the user's browser for the IdP login
  /// (email one-time passcode or Google). [state] is the app's anti-CSRF
  /// value; it comes back on the loopback redirect. The PKCE challenge is
  /// minted here; its verifier is presented by [exchangeCode].
  Uri authorizationUrl(String clientId, String redirectUri, String state) {
    final metadata = _metadata;
    if (metadata == null) {
      throw StateError(
        'call discover() or registerClient() before authorizationUrl()',
      );
    }
    // RFC 7636 S256: challenge = base64url(SHA-256(verifier)). Cloudflare
    // mangles a challenge that starts with `-` or `_` (its URL parameter
    // parsing), so regenerate until it starts alphanumeric.
    var challenge = '';
    do {
      final verifier = _randomCodeVerifier();
      challenge = base64UrlEncode(sha256.convert(verifier.codeUnits).bytes)
          .replaceAll('=', '');
      _codeVerifier = verifier;
    } while (challenge.startsWith('-') || challenge.startsWith('_'));
    return metadata.authorizationEndpoint.replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'resource': _base.toString(),
      },
    );
  }

  static String _randomCodeVerifier() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  /// Step 4: exchange the authorization code for the opaque access token
  /// and the refresh token; presents the PKCE verifier minted by
  /// [authorizationUrl].
  Future<AccessTokens> exchangeCode(
    String clientId,
    String code,
    String redirectUri,
  ) async {
    final verifier = _codeVerifier;
    if (verifier == null) {
      throw StateError('call authorizationUrl() before exchangeCode()');
    }
    return _tokenRequest({
      'grant_type': 'authorization_code',
      'client_id': clientId,
      'code': code,
      'redirect_uri': redirectUri,
      'code_verifier': verifier,
    });
  }

  /// The silent refresh until the grant session ends (issue #23, step 5):
  /// a new opaque access token for the same refresh token.
  Future<AccessTokens> refresh(String clientId, String refreshToken) async {
    return _tokenRequest({
      'grant_type': 'refresh_token',
      'client_id': clientId,
      'refresh_token': refreshToken,
    });
  }

  Future<AccessTokens> _tokenRequest(Map<String, String> form) async {
    final metadata = _metadata ??= await discover();
    final raw = await _httpJson('POST', metadata.tokenEndpoint, form: form);
    final accessToken = raw['access_token'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw const OAuthError('token_failed', 'no access token in the response');
    }
    final refreshToken = raw['refresh_token'];
    final expiresIn = (raw['expires_in'] is num)
        ? Duration(milliseconds: ((raw['expires_in'] as num) * 1000).round())
        : const Duration(seconds: 900); // Access default (issue #23: 15 min)
    return AccessTokens(
      accessToken: accessToken,
      refreshToken: refreshToken is String ? refreshToken : null,
      expiresIn: expiresIn,
      acquiredAt: DateTime.now(),
    );
  }

  Future<Map<String, Object?>> _httpJson(
    String method,
    Uri uri, {
    String? body,
    Map<String, String>? form,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, uri);
      if (form != null) {
        request.headers.contentType = ContentType(
          'application/x-www-form-urlencoded',
          'utf-8',
        );
        request.write(Uri(queryParameters: form).query);
      } else if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(body);
      }
      final response = await request.close();
      final rawBody = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode == HttpStatus.ok ||
          response.statusCode == HttpStatus.created) {
        Object? decoded;
        try {
          decoded = rawBody.isEmpty ? <String, Object?>{} : jsonDecode(rawBody);
        } catch (_) {
          throw const OAuthError(
            'bad_response',
            'the endpoint did not answer JSON',
          );
        }
        if (decoded is! Map<String, Object?>) {
          throw const OAuthError(
            'bad_response',
            'the endpoint did not answer JSON',
          );
        }
        return decoded;
      }
      Object? error;
      Object? description;
      try {
        final decoded = jsonDecode(rawBody);
        if (decoded is Map<String, Object?>) {
          error = decoded['error'];
          description = decoded['error_description'];
        }
      } catch (_) {
        // Not JSON: the status code is the error.
      }
      if (description is! String || description.isEmpty) {
        // No description (an HTML error page, a bare 500): the body is the
        // only clue about what the endpoint did not like.
        final trimmed = rawBody.trim();
        description = trimmed.isEmpty
            ? null
            : trimmed.length > 200
            ? trimmed.substring(0, 200)
            : trimmed;
      }
      throw OAuthError(
        error is String ? error : 'http_${response.statusCode}',
        description is String ? description : null,
      );
    } on OAuthError {
      rethrow;
    } catch (error) {
      throw OAuthError('network', '$error');
    } finally {
      client.close(force: true);
    }
  }
}
