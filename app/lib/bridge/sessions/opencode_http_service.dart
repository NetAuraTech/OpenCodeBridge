import 'dart:convert';
import 'dart:io';

import 'opencode_service.dart';
import 'paths.dart';

/// The real [OpencodeService]: HTTP over the shared opencode service, using
/// the service's Basic auth. The bridge holds these credentials and never
/// exposes them (ADR-0001).
///
/// Maps the service's endpoints to the four operations the sessions slice
/// needs (spec §5, §6, §7):
/// - `GET /api/session` (cursor-paginated) -> the session list;
/// - `GET /api/project` -> project display names;
/// - `GET /api/session/active` -> the TUI-attached / agent-working set;
/// - `DELETE /api/session/{id}` -> deletion.
class OpencodeHttpService implements OpencodeService {
  OpencodeHttpService({required Uri baseUrl, required String password})
    : _base = baseUrl,
      _auth = 'Basic ${base64Encode(utf8.encode("$_user:$password"))}' {
    if (!_base.isScheme('http')) {
      throw ArgumentError('baseUrl must be http, got $_base');
    }
  }

  /// The Basic-auth username the shared service expects (the password comes
  /// from the service descriptor).
  static const String _user = 'opencode';

  final Uri _base;
  final String _auth;

  /// Builds the service client from the shared-service descriptor the opencode
  /// service publishes at `~/.local/state/opencode/service.json` (`url` +
  /// `password`), so a co-resident tool can reach it without config of its own.
  static Future<OpencodeHttpService> fromHost({String? statePath}) async {
    final file = File(statePath ?? defaultStatePath());
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    return OpencodeHttpService(
      baseUrl: Uri.parse(raw['url'] as String),
      password: raw['password'] as String,
    );
  }

  /// Where the shared opencode service publishes its `url` + `password`.
  static String defaultStatePath() =>
      '${homeDirectory()}/.local/state/opencode/service.json';

  /// A hard cap so a misbehaving cursor can never loop forever.
  static const int _maxPages = 1000;

  @override
  Future<List<OpencodeSession>> listSessions() async {
    final sessions = <OpencodeSession>[];
    String? cursor;
    for (var page = 0; page < _maxPages; page++) {
      final params = <String, String>{'order': 'desc'};
      if (cursor != null) params['cursor'] = cursor;
      final body = await _get(
        _base.replace(path: '/api/session', queryParameters: params),
      );
      sessions.addAll(_sessionsFrom(jsonDecode(body)));
      final next = _nextCursor(jsonDecode(body));
      if (next == null) break;
      cursor = next;
    }
    return sessions;
  }

  @override
  Future<Map<String, String>> projectNames() async {
    final body = await _get(_base.replace(path: '/api/project'));
    final decoded = jsonDecode(body);
    final list = decoded is List ? decoded : const <Object?>[];
    final names = <String, String>{};
    for (final item in list) {
      final map = item is Map<String, Object?> ? item : const {};
      final id = map['id'] as String?;
      if (id == null || id.isEmpty) continue;
      final name = map['name'] is String && (map['name'] as String).isNotEmpty
          ? map['name'] as String
          : _basename(map['canonical'] as String? ?? id);
      names[id] = name;
    }
    return names;
  }

  @override
  Future<Set<String>> activeSessionIds() async {
    final body = await _get(_base.replace(path: '/api/session/active'));
    final decoded = jsonDecode(body);
    final map = decoded is Map<String, Object?> ? decoded : const {};
    final data = map['data'];
    return data is Map<String, Object?>
        ? Set<String>.of(data.keys)
        : <String>{};
  }

  @override
  Future<void> deleteSession(String id) async {
    final client = HttpClient();
    try {
      final request = await client.deleteUrl(
        _base.replace(path: '/api/session/${Uri.encodeComponent(id)}'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, _auth);
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode != HttpStatus.noContent &&
          response.statusCode != HttpStatus.ok) {
        throw OpencodeServiceError(
          response.statusCode,
          'delete of $id was not accepted',
        );
      }
    } on OpencodeServiceError {
      rethrow;
    } catch (error) {
      throw OpencodeServiceError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// A GET to [uri] with the service auth, returning the raw body. Non-200 ->
  /// [OpencodeServiceError] carrying the status; a transport failure -> status 0.
  Future<String> _get(Uri uri) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.authorizationHeader, _auth);
      final response = await request.close();
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != HttpStatus.ok) {
        throw OpencodeServiceError(response.statusCode, body);
      }
      return body;
    } on OpencodeServiceError {
      rethrow;
    } catch (error) {
      throw OpencodeServiceError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  static List<OpencodeSession> _sessionsFrom(Object? decoded) {
    final map = decoded is Map<String, Object?> ? decoded : const {};
    final data = map['data'];
    final list = data is List ? data : const <Object?>[];
    return [
      for (final item in list)
        if (item is Map<String, Object?>)
          OpencodeSession(
            id: item['id'] as String? ?? '',
            title: item['title'] as String? ?? '',
            projectId: item['projectID'] as String? ?? '',
            created: _nestedInt(item, 'time', 'created'),
            location: _nestedString(item, 'location', 'directory'),
          ),
    ];
  }

  static String? _nextCursor(Object? decoded) {
    final map = decoded is Map<String, Object?> ? decoded : const {};
    final cursor = map['cursor'];
    final next = cursor is Map<String, Object?> ? cursor['next'] : null;
    return next is String && next.isNotEmpty ? next : null;
  }

  static int _nestedInt(Map<String, Object?> map, String outer, String inner) {
    final o = map[outer];
    if (o is Map<String, Object?>) return (o[inner] as num?)?.toInt() ?? 0;
    return 0;
  }

  static String _nestedString(
    Map<String, Object?> map,
    String outer,
    String inner,
  ) {
    final o = map[outer];
    if (o is Map<String, Object?>) return o[inner] as String? ?? '';
    return '';
  }

  /// The last path component, for deriving a project display name from its
  /// canonical directory when the service gives no explicit `name`.
  static String _basename(String path) {
    var trimmed = path;
    while (trimmed.endsWith('/') && trimmed.length > 1) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    final i = trimmed.lastIndexOf('/');
    if (i < 0) return trimmed;
    final name = trimmed.substring(i + 1);
    return name.isEmpty ? trimmed : name;
  }
}
