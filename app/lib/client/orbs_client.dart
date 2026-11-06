import 'dart:convert';
import 'dart:io';

import 'package:opencodebridge/client/authenticated_http.dart';
import 'package:opencodebridge/model/orb.dart';
import 'package:opencodebridge/model/session.dart';

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

  /// The protected deletion (issue #98, spec §2.7): `DELETE /api/orbs/<id>`
  /// — the bridge evaluates the deletion guard (dirty tree, unpushed
  /// commits) and refuses with a 409 `deletion_refused` (an
  /// [OrbsClientError] carrying the code) unless [force] overrides it (the
  /// explicit human force-delete — the card's confirm dialog). An `orphan`
  /// record goes through the orphan cleanup (its 404 surfaces here too); a
  /// 204 is the removal (container, volumes, state dir).
  Future<void> delete(String id, {bool force = false}) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'DELETE',
        _base.replace(path: 'api/orbs/$id'),
        body: force ? jsonEncode({'force': true}) : null,
        contentType: force ? ContentType.json : null,
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.noContent) {
        throw OrbsClientError(response.statusCode, _detail(body));
      }
    } on OrbsClientError {
      rethrow;
    } catch (error) {
      throw OrbsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The per-orb image update (issue #98, spec §2.8): the bridge recreates
  /// the container on the current image over the same volumes (the
  /// workspace preserved, the marker untouched — a stopped orb stays
  /// stopped, a running orb comes back running). The bridge blocks for the
  /// whole re-boot of a running orb; a failure surfaces as an
  /// [OrbCreateError] (the 400 `not_updatable` / `update_busy` refusals and
  /// the 502 `orb_boot_failed` with its log tail) or an [OrbsClientError]
  /// (the 503 when the orb password cannot be read).
  Future<OrbRecord> update(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/orbs/$id/update'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode == HttpStatus.ok) {
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

  /// The `docker cp` export (issue #98, spec §3.4): the bridge writes a
  /// lossless tar.gz of the orb's whole workspace next to the project's
  /// local clone and answers 200 with its path. A failure surfaces as an
  /// [OrbCreateError] (the 400 `missing_checkout` / `missing_workspace`
  /// refusals) or an [OrbsClientError].
  Future<String> export(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/orbs/$id/export'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode == HttpStatus.ok) {
        final decoded = jsonDecode(body);
        final path = decoded is Map<String, Object?> ? decoded['path'] : null;
        return path is String ? path : '';
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

  /// The orb stop (issue #97, spec §2.5): the single trigger for every orb
  /// death path — every session exported to the host checkout and deleted
  /// from the orb only after its import, the container stopped last, the
  /// `ocb.stopped` marker set. The bridge blocks until the move and the
  /// stop are done (the card keeps its "stopping" state open over the
  /// wait); a re-issue while stopped is a safe no-op 204. A failure
  /// surfaces as an [OrbsClientError] (the 503 `opencode_unavailable` when
  /// the host CLI or service is missing, the 502 `session_move_failed`
  /// with its detail, the 502 `docker_unreachable`, or the 404 of an
  /// unknown id).
  Future<void> stop(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/orbs/$id/stop'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.noContent) {
        throw OrbsClientError(response.statusCode, _detail(body));
      }
    } on OrbsClientError {
      rethrow;
    } catch (error) {
      throw OrbsClientError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// The orb wake (issue #97, spec §2.4): re-runs the full start path on
  /// the same container/volumes/state — the `.env*` re-injection, the
  /// config/auth re-copy, `docker start`, the boot wait — and removes the
  /// `ocb.stopped` marker only on success. The bridge blocks for the whole
  /// boot before answering 200 with the running record. A failure surfaces
  /// as an [OrbCreateError] (the 400 `not_wakeable` refusal and the 502
  /// `orb_boot_failed` with its log tail) or an [OrbsClientError].
  Future<OrbRecord> wake(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/orbs/$id/wake'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode == HttpStatus.ok) {
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

  /// Create a session on the running orb [id] (issue #97, spec §9.5): the
  /// new session's working directory is the orb's workspace
  /// (`/workspace`), and the returned row is stamped with the orb. A
  /// stopped orb refuses with the 400 `not_running` (an [OrbCreateError])
  /// — wake it first.
  Future<Session> createSessionOnOrb(String id) async {
    final client = HttpClient();
    try {
      final response = await bridgeRequest(
        client,
        'POST',
        _base.replace(path: 'api/orbs/$id/sessions'),
        auth: _auth,
      );
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode == HttpStatus.created) {
        return Session.fromJson(jsonDecode(body));
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

  /// The user-facing text of a wire error body: its `details` field, its
  /// `error` code when there are none, or the raw body.
  static String _detail(String body) {
    final decoded = const JsonDecoder().convert(body);
    final map = decoded is Map<String, Object?> ? decoded : const {};
    final details = map['details'] is String ? map['details'] as String : null;
    if (details != null) return details;
    final code = map['error'] is String ? map['error'] as String : null;
    return code ?? body;
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
