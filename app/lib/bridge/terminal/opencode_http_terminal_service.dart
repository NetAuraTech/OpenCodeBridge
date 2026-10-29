import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'opencode_terminal_service.dart';
import 'terminal_frames.dart';
import 'terminal_models.dart';
import '../sessions/paths.dart';

/// The real [OpencodeTerminalService]: HTTP + WebSocket over the shared
/// opencode service's persistent-PTY family, using the service's Basic auth
/// (the bridge holds these credentials and never exposes them, ADR-0001).
///
/// Maps the service's experimental endpoints to the terminal slice (spec §7):
/// - `POST   /api/experimental/session/{id}/terminal` -> create the PTY;
/// - `GET    /api/experimental/session/{id}/terminal` -> the session's PTYs;
/// - `POST   /api/experimental/persistent-pty/{id}/connect-token` -> ticket;
/// - `GET    /api/experimental/persistent-pty/{id}/connect` (WebSocket, the
///   attach: input and resize ride on it as protocol-1 frames);
/// - `PUT    /api/experimental/persistent-pty/{id}` -> resize (no attach);
/// - `DELETE /api/experimental/persistent-pty/{id}` -> delete.
class OpencodeHttpTerminalService implements OpencodeTerminalService {
  OpencodeHttpTerminalService({required Uri baseUrl, required String password})
    : _base = baseUrl,
      _auth = 'Basic ${base64Encode(utf8.encode("$_user:$password"))}' {
    if (!_base.isScheme('http')) {
      throw ArgumentError('baseUrl must be http, got $_base');
    }
  }

  /// The Basic-auth username the shared service expects (the password comes
  /// from the service descriptor).
  static const String _user = 'opencode';

  /// The native same-host marker: on the host the service issues a real
  /// connect ticket instead of a pairing token (which is Forbidden here).
  static const String _ticketHeader = 'x-opencode-ticket';

  final Uri _base;
  final String _auth;

  Uri get _wsBase =>
      _base.replace(scheme: _base.scheme == 'https' ? 'wss' : 'ws');

  /// Builds the service client from the shared-service descriptor the opencode
  /// service publishes at `~/.local/state/opencode/service.json` (`url` +
  /// `password`), so a co-resident tool can reach it without config of its own.
  static Future<OpencodeHttpTerminalService> fromHost({
    String? statePath,
  }) async {
    final file = File(statePath ?? defaultStatePath());
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    return OpencodeHttpTerminalService(
      baseUrl: Uri.parse(raw['url'] as String),
      password: raw['password'] as String,
    );
  }

  /// Where the shared opencode service publishes its `url` + `password`.
  static String defaultStatePath() =>
      '${homeDirectory()}/.local/state/opencode/service.json';

  @override
  Future<TerminalInfo> createTerminal(
    String sessionId, {
    required String cwd,
    TerminalSize? size,
    String? title,
  }) async {
    final body = <String, Object?>{
      'command': 'opencode',
      'args': ['--session', sessionId],
      'title': title ?? 'OpenCode',
      // The service marks `env` optional in the schema but requires it at
      // runtime (probe quirk); an empty env is correct for the TUI.
      'env': <String, String>{},
      'cwd': cwd,
      'size': (size ?? TerminalSize.defaultSize).toJson(),
    };
    final data = await _request(
      'POST',
      _base.replace(
        path:
            '/api/experimental/session/${Uri.encodeComponent(sessionId)}/terminal',
      ),
      body: body,
    );
    final map = data is Map<String, Object?> ? data : const {};
    return TerminalInfo.fromJson(map['data']);
  }

  @override
  Future<List<TerminalInfo>> listTerminals(String sessionId) async {
    final data = await _request(
      'GET',
      _base.replace(
        path:
            '/api/experimental/session/${Uri.encodeComponent(sessionId)}/terminal',
      ),
    );
    final map = data is Map<String, Object?> ? data : const {};
    final list = map['data'] is List ? (map['data'] as List) : const <Object>[];
    return [
      for (final item in list)
        if (item is Map<String, Object?>) TerminalInfo.fromJson(item),
    ];
  }

  @override
  Future<TerminalInfo> runningTerminal(String sessionId) async {
    final terminals = await listTerminals(sessionId);
    for (final terminal in terminals) {
      if (terminal.status == TerminalStatus.running) return terminal;
    }
    throw OpencodeTerminalServiceError(
      HttpStatus.notFound,
      'no running terminal for session $sessionId',
    );
  }

  @override
  Future<TerminalTicket> connectToken(String ptyId) async {
    final data = await _request(
      'POST',
      _base.replace(
        path:
            '/api/experimental/persistent-pty/${Uri.encodeComponent(ptyId)}/connect-token',
      ),
      extraHeaders: {_ticketHeader: '1'},
    );
    final map = data is Map<String, Object?> ? data : const {};
    return TerminalTicket.fromJson(map['data']);
  }

  @override
  Future<TerminalConnection> connect(
    String ptyId, {
    required String ticket,
    int cursor = 0,
    required TerminalSize size,
  }) async {
    final url = _wsBase.replace(
      path:
          '/api/experimental/persistent-pty/${Uri.encodeComponent(ptyId)}/connect',
      queryParameters: {
        'ticket': ticket,
        'cursor': '$cursor',
        // Protocol 1: framed input. With the attach open, the service rejects
        // an HTTP resize (503, "requires the active controller attachment") —
        // only protocol 0 cannot carry a resize at all, so input and resize
        // both ride on the socket as framed binary.
        'input_protocol': '1',
      },
    );
    final socket = await WebSocket.connect(
      url.toString(),
      headers: {HttpHeaders.authorizationHeader: _auth},
    );
    return _WebSocketTerminalConnection(socket, size.cols, size.rows);
  }

  @override
  Future<TerminalInfo> resize(String ptyId, TerminalSize size) async {
    final data = await _request(
      'PUT',
      _base.replace(
        path: '/api/experimental/persistent-pty/${Uri.encodeComponent(ptyId)}',
      ),
      body: {'size': size.toJson()},
    );
    final map = data is Map<String, Object?> ? data : const {};
    return TerminalInfo.fromJson(map['data']);
  }

  @override
  Future<void> delete(String ptyId) async {
    final client = HttpClient();
    try {
      final request = await client.deleteUrl(
        _base.replace(
          path:
              '/api/experimental/persistent-pty/${Uri.encodeComponent(ptyId)}',
        ),
      );
      request.headers.set(HttpHeaders.authorizationHeader, _auth);
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode != HttpStatus.noContent &&
          response.statusCode != HttpStatus.ok) {
        throw OpencodeTerminalServiceError(
          response.statusCode,
          'delete of $ptyId was not accepted',
        );
      }
    } on OpencodeTerminalServiceError {
      rethrow;
    } catch (error) {
      throw OpencodeTerminalServiceError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// A service request, returning the decoded JSON body. Non-200 ->
  /// [OpencodeTerminalServiceError] carrying the status; a transport failure ->
  /// status 0.
  Future<Object?> _request(
    String method,
    Uri uri, {
    Object? body,
    Map<String, String> extraHeaders = const {},
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, uri);
      request.headers.set(HttpHeaders.authorizationHeader, _auth);
      for (final entry in extraHeaders.entries) {
        request.headers.set(entry.key, entry.value);
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final responseBody = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode == HttpStatus.noContent) return null;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw OpencodeTerminalServiceError(response.statusCode, responseBody);
      }
      if (responseBody.isEmpty) return null;
      return jsonDecode(responseBody);
    } on OpencodeTerminalServiceError {
      rethrow;
    } catch (error) {
      throw OpencodeTerminalServiceError(0, '$error');
    } finally {
      client.close(force: true);
    }
  }
}

/// The [TerminalConnection] over a service attach WebSocket: it filters the
/// service's stream down to raw ANSI bytes, reports when the initial replay is
/// done, and drives the PTY with protocol-1 frames.
///
/// Protocol 1 frames every client frame as a 5-byte header
/// `[flag, colsHi, colsLo, rowsHi, rowsLo]` followed by an optional payload:
/// flag 0 is a pure resize (no payload), flag 1 is input (the payload is the
/// raw bytes). The header always carries the PTY size and the service applies
/// that size to the PTY — so this connection tracks the current size
/// ([_cols]/[_rows]) so an input frame never resizes the PTY to a stale size.
class _WebSocketTerminalConnection implements TerminalConnection {
  _WebSocketTerminalConnection(this._socket, int cols, int rows)
    : _cols = cols,
      _rows = rows {
    _socket.listen(
      (event) {
        if (event is List<int>) {
          _output.add(event);
        } else if (event is String && parseReplayComplete(event) != null) {
          _markReplayDone();
        }
      },
      onDone: () {
        _markReplayDone();
        _output.close();
      },
      onError: (Object error, [StackTrace? stack]) {
        _markReplayDone();
        _output.addError(error, stack);
        _output.close();
      },
    );
  }

  final WebSocket _socket;
  final StreamController<List<int>> _output = StreamController();
  final Completer<void> _replayDone = Completer<void>();

  /// The PTY size the connection last set; every frame it sends is headed by it.
  int _cols;
  int _rows;

  @override
  Stream<List<int>> get output => _output.stream;

  @override
  Future<void> get initialReplayDone => _replayDone.future;

  void _markReplayDone() {
    if (!_replayDone.isCompleted) _replayDone.complete();
  }

  /// Build a protocol-1 frame: `[flag, colsHi, colsLo, rowsHi, rowsLo, ...]`.
  List<int> _frame(int flag, int cols, int rows, List<int> payload) => [
    flag,
    (cols >> 8) & 0xff,
    cols & 0xff,
    (rows >> 8) & 0xff,
    rows & 0xff,
    ...payload,
  ];

  @override
  Future<void> write(List<int> input) async {
    // Flag 1: the payload is the input, headed by the current PTY size.
    _socket.add(_frame(1, _cols, _rows, input));
  }

  @override
  Future<void> resize(int cols, int rows) async {
    _cols = cols;
    _rows = rows;
    // Flag 0: a pure resize, no payload.
    _socket.add(_frame(0, _cols, _rows, const []));
  }

  @override
  Future<void> close() async {
    try {
      await _socket.close();
    } catch (_) {
      // The socket is already gone; closing is idempotent for the proxy.
    }
    if (!_output.isClosed) await _output.close();
  }
}
