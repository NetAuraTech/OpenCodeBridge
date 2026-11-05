import 'dart:convert';
import 'dart:io';

import 'package:opencodebridge/client/authenticated_http.dart';
import 'package:opencodebridge/model/orb.dart';

/// The app-side client of the bridge's orb endpoints (issue #93, #96):
/// the orb list (with the optional PR state), the creation (which blocks
/// for the whole boot), the shared-base-image rebuild, and the explicit
/// orphan cleanup. The app talks only to the bridge (ADR-0001): in server
/// mode that is loopback, in client mode the same API behind the tunnel
/// (issue #23: every request carries `Authorization: Bearer` from [auth],
/// refreshed on `401` — see [bridgeRequest]).
class OrbsClient {
  OrbsClient(this._base, {this._auth});

  /// The bridge's base URI, e.g. `http://127.0.0.1:48201/`.
  final Uri _base;

  /// The Access login's header provider (issue #23); `null` in server mode.
  final AuthHeaderProvider? _auth;

  /// Every orb (spec §2.2): the labeled containers — running with their
  /// ephemeral URL, stopped/broken, or `preparing` while their boot is in
  /// flight — plus the labeled volumes without a container (orphans,
  /// surfaced for explicit cleanup). [includePr] (the Orbs tab's badge)
  /// additionally asks for the PR of each branch; the cost is a `gh` call
  /// per row, so the Orbs tab is the only caller that sets it (and it
  /// refreshes on foreground-return, not on a poll).
  Future<List<OrbRecord>> list({bool includePr = false}) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: 'api/orbs', query: includePr ? 'pr=1' : null),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw OrbsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final list = decoded is List ? decoded : const <Object?>[];
      return [for (final item in list) OrbRecord.fromJson(item)];
    } on OrbsClientError {
      rethrow;
    } catch (error) {
      throw OrbsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Create the orb [name] in [project] (spec §2.3). The bridge blocks for
  /// the whole boot (up to its 10-minute wait) before answering 201 — the
  /// create wizard keeps its sheet open over that wait and streams the
  /// staged boot log from the events stream, so the POST is fire-and-track,
  /// not a spinner. Failures surface as [OrbCreateError] (the up-front
  /// refusals, the taken name, the failed boot with its log tail).
  Future<OrbRecord> create(String projectId, String name) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/orbs'),
        body: jsonEncode({'project': projectId, 'name': name}),
        contentType: ContentType.json,
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode == HttpStatus.created) {
        return OrbRecord.fromJson(jsonDecode(body));
      }
      throw _createError(response.statusCode, body);
    } on OrbCreateError {
      rethrow;
    } on OrbsClientError {
      rethrow;
    } catch (error) {
      throw OrbsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The explicit shared-base-image rebuild (spec §5.3, #92): the tag of
  /// the freshly built image; the build logs stream as events. A 503
  /// `docker_unavailable` or a 502 failure is an [OrbsClientError].
  Future<String> rebuildImage() async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/orb/image/rebuild'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw OrbsClientError(response.statusCode, body);
      }
      final decoded = jsonDecode(body);
      final tag = decoded is Map<String, Object?> ? decoded['tag'] : null;
      return tag is String ? tag : '';
    } on OrbsClientError {
      rethrow;
    } catch (error) {
      throw OrbsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The explicit orphan cleanup (spec §2.2 — never auto-deleted): removes
  /// the orphan's labeled volumes and its state dir. A 404 (no such orphan)
  /// or a 409 `orb_exists` (a container still exists) is an
  /// [OrbsClientError] carrying the wire code.
  Future<void> deleteOrphan(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'DELETE',
        _base.replace(path: 'api/orbs/$id'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.noContent) {
        throw OrbsClientError(response.statusCode, body);
      }
    } on OrbsClientError {
      rethrow;
    } catch (error) {
      throw OrbsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The wire error of a failed create, decoded to [OrbCreateError]:
  /// `name_taken` (409), the up-front refusals (400, code + details), and
  /// the failed boot (502 `orb_boot_failed`, with its log tail).
  OrbCreateError _createError(int statusCode, String body) {
    final decoded = const JsonDecoder().convert(body);
    final map = decoded is Map<String, Object?> ? decoded : const {};
    final code = map['error'] is String ? map['error'] as String : '';
    final details = map['details'] is String ? map['details'] as String : null;
    final logTail = map['logTail'] is List
        ? [
            for (final line in (map['logTail'] as List))
              if (line is String) line,
          ]
        : const <String>[];
    return OrbCreateError(
      statusCode: statusCode,
      code: code,
      details: details,
      logTail: logTail,
    );
  }
}

/// A refusal or failure of the orb creation (spec §2.3), carrying the wire
/// `error` code, the clear [details], and the boot [logTail] when the boot
/// failed (the 502 `orb_boot_failed` path).
class OrbCreateError implements Exception {
  const OrbCreateError({
    required this.statusCode,
    required this.code,
    this.details,
    this.logTail = const [],
  });

  /// The `name_taken` conflict.
  static const String nameTaken = 'name_taken';

  /// The failed boot (the `orb_boot_failed` 502).
  static const String bootFailed = 'orb_boot_failed';

  /// The HTTP status (409 `name_taken`, 400 refusal, 502 boot failure).
  final int statusCode;

  /// The wire `error` code (`name_taken`, a refusal code such as
  /// `no_remote`, `orb_boot_failed`).
  final String code;

  /// The clear message for the user (the refusal's detail, the boot
  /// failure's reason).
  final String? details;

  /// The last container-log lines when the boot failed (most recent last).
  final List<String> logTail;

  @override
  String toString() => 'OrbCreateError($statusCode: $code)';
}

/// A failure of a bridge orb endpoint other than a named create refusal
/// (the bridge's status, 0 when the bridge could not be reached at all —
/// e.g. the 503 `docker_unavailable` of a host without docker, or the
/// 404/409 of the orphan cleanup).
class OrbsClientError implements Exception {
  const OrbsClientError(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'OrbsClientError($statusCode: $message)';
}
