import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../sessions/paths.dart';
import '../../sse/sse.dart';
import 'opencode_event_service.dart';

/// The real [OpencodeEventService]: a single upstream `GET /api/event`
/// subscription over the shared opencode service (Basic auth), parsed with the
/// shared SSE seam. The bridge holds exactly this one subscription and reads
/// every event through it.
///
/// The subscription is self-healing: the connection loop re-opens
/// `GET /api/event` whenever the stream ends or errors — including after an
/// opencode service restart — until [close], so the bridge survives a service
/// restart and re-subscribes on its own.
class OpencodeHttpEventService implements OpencodeEventService {
  OpencodeHttpEventService({
    required Uri baseUrl,
    required String password,
    this.reconnectDelay = const Duration(milliseconds: 500),
  }) : _base = baseUrl,
       _auth = 'Basic ${base64Encode(utf8.encode("$_user:$password"))}' {
    if (!baseUrl.isScheme('http')) {
      throw ArgumentError('baseUrl must be http, got $baseUrl');
    }
    _controller = StreamController<OpencodeEvent>.broadcast(
      onListen: () => _onFirstListen(),
    );
  }

  /// The Basic-auth username the shared service expects (the password comes
  /// from the service descriptor).
  static const String _user = 'opencode';

  final Uri _base;
  final String _auth;

  /// How long to wait before re-opening the subscription after it drops
  /// (service restart / network blip).
  final Duration reconnectDelay;

  late final StreamController<OpencodeEvent> _controller;
  bool _started = false;
  bool _closed = false;
  HttpClient? _client;

  /// Builds the service client from the shared-service descriptor the opencode
  /// service publishes at `~/.local/state/opencode/service.json` (`url` +
  /// `password`), so a co-resident tool can reach it without config of its own.
  static Future<OpencodeHttpEventService> fromHost({String? statePath}) async {
    final file = File(statePath ?? defaultStatePath());
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    return OpencodeHttpEventService(
      baseUrl: Uri.parse(raw['url'] as String),
      password: raw['password'] as String,
    );
  }

  /// Where the shared opencode service publishes its `url` + `password`.
  static String defaultStatePath() =>
      '${homeDirectory()}/.local/state/opencode/service.json';

  Uri get _eventUri => _base.replace(path: '/api/event');

  @override
  Stream<OpencodeEvent> get events => _controller.stream;

  void _onFirstListen() {
    if (_started) return;
    _started = true;
    unawaited(_loop());
  }

  Future<void> _loop() async {
    while (!_closed) {
      try {
        await _connectOnce();
      } catch (_) {
        // A failed/aborted connection: fall through and (re)try below.
      }
      if (_closed) break;
      await Future<void>.delayed(reconnectDelay);
    }
    if (!_controller.isClosed) await _controller.close();
  }

  Future<void> _connectOnce() async {
    final client = HttpClient();
    _client = client;
    try {
      final request = await client.getUrl(_eventUri);
      request.headers.set(HttpHeaders.authorizationHeader, _auth);
      request.headers.set('accept', 'text/event-stream');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw OpencodeEventServiceError(
          response.statusCode,
          'event stream was not ok',
        );
      }
      final payloads = sseDataLines(response.transform(const Utf8Decoder()));
      await for (final payload in payloads) {
        if (_closed) return;
        _emit(payload);
      }
    } on OpencodeEventServiceError {
      rethrow;
    } catch (error) {
      throw OpencodeEventServiceError(0, '$error');
    } finally {
      _client = null;
      client.close(force: true);
    }
  }

  void _emit(String payload) {
    if (_closed) return;
    final event = _parse(payload);
    if (event != null && !_controller.isClosed) _controller.add(event);
  }

  OpencodeEvent? _parse(String payload) {
    Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      return null; // A malformed frame must not kill the subscription.
    }
    if (decoded is! Map<String, Object?>) return null;
    final type = decoded['type'] is String ? decoded['type'] as String : '';
    String? aggregateID;
    int? seq;
    final durable = decoded['durable'];
    if (durable is Map<String, Object?>) {
      aggregateID = durable['aggregateID'] as String?;
      final s = durable['seq'];
      seq = s is int ? s : (s is num ? s.toInt() : null);
    }
    return OpencodeEvent(
      raw: payload,
      type: type,
      aggregateID: aggregateID,
      seq: seq,
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final client = _client;
    _client = null;
    if (client != null) client.close(force: true);
    if (!_controller.isClosed) await _controller.close();
  }
}
