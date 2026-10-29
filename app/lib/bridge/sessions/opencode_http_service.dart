import 'dart:convert';
import 'dart:io';

import 'opencode_service.dart';
import 'paths.dart';

/// The real [OpencodeService]: HTTP over the shared opencode service, using
/// the service's Basic auth. The bridge holds these credentials and never
/// exposes them (ADR-0001).
///
/// Maps the service's endpoints to the operations the sessions slice
/// needs (spec §5, §6, §7):
/// - `GET /api/session` (cursor-paginated) -> the session list;
/// - `GET /api/project` -> the project list (names + canonical dirs);
/// - `GET /api/session/active` -> the TUI-attached / agent-working set;
/// - `POST /api/session` -> create a session in a project;
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
    final list = await projects();
    return {for (final p in list) p.id: p.name};
  }

  @override
  Future<List<OpencodeProject>> projects() async {
    final body = await _get(_base.replace(path: '/api/project'));
    final decoded = jsonDecode(body);
    final list = decoded is List ? decoded : const <Object?>[];
    return [
      for (final item in list)
        if (item is Map<String, Object?>) _projectFrom(item),
    ].where((p) => p.id.isNotEmpty).toList();
  }

  @override
  Future<OpencodeSession> createSession(String projectId) async {
    OpencodeProject? project;
    for (final p in await projects()) {
      if (p.id == projectId) {
        project = p;
        break;
      }
    }
    if (project == null) {
      throw const OpencodeServiceError(404, 'no such project');
    }
    final body = await _post(
      _base.replace(path: '/api/session'),
      jsonEncode({
        'location': {'directory': project.canonical},
      }),
    );
    final decoded = jsonDecode(body);
    final outer = decoded is Map<String, Object?>
        ? decoded
        : const <String, Object?>{};
    // The service wraps single-object responses in `{ "data": … }` (the same
    // envelope as the list endpoint); unwrap it. The top-level fallback keeps
    // a shape change from degrading to a silently-empty id.
    final data = outer['data'];
    final map = data is Map<String, Object?> ? data : outer;
    return _sessionFrom(map);
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

  /// A POST to [uri] with the service auth and a JSON [body], returning the raw
  /// response body. Non-2xx -> [OpencodeServiceError]; a transport failure ->
  /// status 0.
  Future<String> _post(Uri uri, String body) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(uri);
      request.headers.set(HttpHeaders.authorizationHeader, _auth);
      request.headers.contentType = ContentType.json;
      request.write(body);
      final response = await request.close();
      final responseBody = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw OpencodeServiceError(response.statusCode, responseBody);
      }
      return responseBody;
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
        if (item is Map<String, Object?>) _sessionFrom(item),
    ];
  }

  /// One session object (the service's `Session`), from a list item or the
  /// create response.
  static OpencodeSession _sessionFrom(Map<String, Object?> item) {
    return OpencodeSession(
      id: item['id'] as String? ?? '',
      title: item['title'] as String? ?? '',
      projectId: item['projectID'] as String? ?? '',
      created: _nestedInt(item, 'time', 'created'),
      location: _nestedString(item, 'location', 'directory'),
    );
  }

  /// One project object (`GET /api/project` item).
  static OpencodeProject _projectFrom(Map<String, Object?> item) {
    final id = item['id'] as String? ?? '';
    final canonical = item['canonical'] as String? ?? '';
    final name = item['name'] is String && (item['name'] as String).isNotEmpty
        ? item['name'] as String
        : _basename(canonical.isEmpty ? id : canonical);
    return OpencodeProject(id: id, name: name, canonical: canonical);
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
