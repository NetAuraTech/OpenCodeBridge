import 'dart:convert';
import 'dart:io';

import '../../model/message.dart';
import '../../model/permission.dart';
import '../../model/session_detail.dart';
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

  /// Endpoint 5 (spec §5): the session's detail — state plus costs and token
  /// usage. The service's `Session.Info` flattens to the bridge contract.
  @override
  Future<SessionDetail> getDetail(String id) async {
    final body = await _get(
      _base.replace(path: '/api/session/${Uri.encodeComponent(id)}'),
    );
    final outer = jsonDecode(body);
    final data = outer is Map<String, Object?> ? outer['data'] : null;
    final map = data is Map<String, Object?> ? data : const <String, Object?>{};
    final title = map['title'] is String ? map['title'] as String : null;
    final outcome = map['outcome'] is String ? map['outcome'] as String : null;
    final model = map['model'] is Map<String, Object?>
        ? map['model'] as Map<String, Object?>
        : null;
    return SessionDetail(
      id: map['id'] as String? ?? '',
      title: title ?? '',
      location: _nestedString(map, 'location', 'directory'),
      cost: (map['cost'] as num?)?.toDouble() ?? 0,
      tokens: _tokensFrom(map['tokens']),
      outcome: outcome,
      contextLimit: await _contextLimitFor(model),
    );
  }

  /// The model registry's context limits, keyed by model id (and by
  /// `providerID/modelID` when the registry carries a provider), cached for
  /// the life of this service: the registry is static for a running service,
  /// and the detail is the only consumer.
  final Map<String, int> _contextLimits = {};

  /// True once the registry fetch has run (a failed fetch leaves it false so
  /// the next detail retries; the registry is optional, never fatal).
  var _limitsLoaded = false;

  Future<void> _ensureModelLimits() async {
    if (_limitsLoaded) return;
    try {
      final body = await _get(_base.replace(path: '/api/model'));
      final decoded = jsonDecode(body);
      final data = decoded is Map<String, Object?> ? decoded['data'] : null;
      final list = data is List
          ? data
          : decoded is List
          ? decoded
          : const <Object?>[];
      for (final item in list) {
        if (item is! Map<String, Object?>) continue;
        final limit = _nestedInt(item, 'limit', 'context');
        if (limit <= 0) continue;
        final id = item['modelID'] is String
            ? item['modelID'] as String
            : item['id'] is String
            ? item['id'] as String
            : null;
        if (id == null) continue;
        _contextLimits.putIfAbsent(id, () => limit);
        final provider = item['providerID'] is String
            ? item['providerID'] as String
            : null;
        if (provider != null) {
          _contextLimits.putIfAbsent('$provider/$id', () => limit);
        }
      }
      _limitsLoaded = true;
    } catch (_) {
      // The registry is optional: the detail just carries no limit.
    }
  }

  /// The session's model's context window in tokens (the registry's
  /// `limit.context` for its `model.id`, preferring the `model.providerID`
  ///-keyed entry when the registry carries providers), or `null`.
  Future<int?> _contextLimitFor(Map<String, Object?>? model) async {
    final id = model?['id'] is String ? model!['id'] as String : null;
    final provider = model?['providerID'] is String
        ? model!['providerID'] as String
        : null;
    if (id == null) return null;
    await _ensureModelLimits();
    if (provider != null) {
      final keyed = _contextLimits['$provider/$id'];
      if (keyed != null) return keyed;
    }
    return _contextLimits[id];
  }

  /// Endpoint 6 (spec §5): the session's history as structured-view messages.
  /// Only `user` and `assistant` turns are conversational; the other
  /// message kinds (system, synthetic, shell, …) carry no display content.
  @override
  Future<List<SessionMessage>> getMessages(String id) async {
    final body = await _get(
      _base.replace(path: '/api/session/${Uri.encodeComponent(id)}/context'),
    );
    final outer = jsonDecode(body);
    final map = outer is Map<String, Object?>
        ? outer
        : const <String, Object?>{};
    final data = map['data'];
    final list = data is List ? data : const <Object?>[];
    final messages = <SessionMessage>[];
    for (final item in list) {
      if (item is Map<String, Object?>) {
        final message = _messageFrom(item);
        if (message != null) messages.add(message);
      }
    }
    return messages;
  }

  /// Endpoint 7 (spec §5): send a prompt. `delivery: steer` is the verified
  /// mid-turn delivery — the service accepts it at any time and runs turns
  /// sequentially.
  @override
  Future<void> prompt(String id, String text) async {
    await _post(
      _base.replace(path: '/api/session/${Uri.encodeComponent(id)}/prompt'),
      jsonEncode({'text': text, 'delivery': 'steer'}),
    );
  }

  /// Endpoint 8 (spec §5): the session's pending permission requests. The
  /// service's `Permission.Request` flattens to the bridge contract.
  @override
  Future<List<PermissionRequest>> pendingPermissions(String id) async {
    final body = await _get(
      _base.replace(path: '/api/session/${Uri.encodeComponent(id)}/permission'),
    );
    final outer = jsonDecode(body);
    final map = outer is Map<String, Object?>
        ? outer
        : const <String, Object?>{};
    final data = map['data'];
    final list = data is List ? data : const <Object?>[];
    return [
      for (final item in list)
        if (item is Map<String, Object?>)
          PermissionRequest(
            id: item['id'] as String? ?? '',
            action: item['action'] as String? ?? '',
            resources: _stringList(item['resources']),
          ),
    ];
  }

  /// Endpoint 9 (spec §5): reply to a pending permission request. The bridge
  /// contract's `reply` becomes the service's `decision`.
  @override
  Future<void> replyPermission(
    String id,
    String requestID,
    PermissionReply reply,
  ) async {
    await _post(
      _base.replace(
        path:
            '/api/session/${Uri.encodeComponent(id)}'
            '/permission/${Uri.encodeComponent(requestID)}/reply',
      ),
      jsonEncode({'decision': reply.wire}),
    );
  }

  /// The service's `TokenUsage.Info` flattens `cache.{read,write}` to the
  /// contract's `cacheRead`/`cacheWrite`.
  static TokenUsage _tokensFrom(Object? json) {
    final map = json is Map<String, Object?> ? json : const {};
    final cache = map['cache'] is Map<String, Object?>
        ? map['cache'] as Map<String, Object?>
        : const <String, Object?>{};
    return TokenUsage(
      input: (map['input'] as num?)?.toInt() ?? 0,
      output: (map['output'] as num?)?.toInt() ?? 0,
      reasoning: (map['reasoning'] as num?)?.toInt() ?? 0,
      cacheRead: (cache['read'] as num?)?.toInt() ?? 0,
      cacheWrite: (cache['write'] as num?)?.toInt() ?? 0,
    );
  }

  /// One context message. Returns `null` for the non-conversational kinds the
  /// structured view does not render.
  static SessionMessage? _messageFrom(Map<String, Object?> item) {
    final type = item['type'] as String?;
    final id = item['id'] is String ? item['id'] as String : null;
    if (type == 'user') {
      final text = item['text'] is String ? item['text'] as String : null;
      return SessionMessage(id: id, role: 'user', text: text);
    }
    if (type != 'assistant') return null;
    final content = item['content'];
    final texts = <String>[];
    final tools = <ToolCall>[];
    if (content is List) {
      for (final part in content) {
        if (part is! Map<String, Object?>) continue;
        final partType = part['type'] as String?;
        if (partType == 'text' || partType == 'reasoning') {
          final t = part['text'] is String ? part['text'] as String : '';
          if (t.isNotEmpty) texts.add(t);
        } else if (partType == 'tool') {
          tools.add(_toolCallFrom(part));
        }
      }
    }
    return SessionMessage(
      id: id,
      role: 'assistant',
      text: texts.isEmpty ? null : texts.join('\n'),
      tools: tools,
    );
  }

  /// One assistant tool part (the service's `Session.Message.Assistant.Tool`)
  /// flattens to a contract [ToolCall]; the error text is the structured
  /// error's `message`.
  static ToolCall _toolCallFrom(Map<String, Object?> part) {
    final state = part['state'] is Map<String, Object?>
        ? part['state'] as Map<String, Object?>
        : const <String, Object?>{};
    final status = state['status'] as String? ?? '';
    String? error;
    if (status == 'error') {
      final e = state['error'];
      if (e is Map<String, Object?> && e['message'] is String) {
        error = e['message'] as String;
      }
    }
    return ToolCall(
      id: part['id'] is String ? part['id'] as String : null,
      name: part['name'] as String? ?? '',
      status: status,
      input: state['input'],
      error: error,
    );
  }

  static List<String> _stringList(Object? json) {
    final list = json is List ? json : const <Object?>[];
    return [
      for (final item in list)
        if (item is String) item,
    ];
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
