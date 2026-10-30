import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../sessions/paths.dart';
import 'bridge_event.dart';

/// The bridge's local-llama.cpp speed feed.
///
/// The session's model runs on a local llama.cpp (GGUF) server, which
/// exposes a Server-Sent-Events `GET /stream` that reports its live
/// **prefill** throughput (`event: prefill`, `data: {speed, …}`) and its
/// **decode** throughput (`event: timing`, `data: {predicted_n,
/// predicted_ms}`). This service subscribes to that stream and re-emits the
/// throughput as `llama.speed` [BridgeEvent]s on the unified event stream, so
/// the app's header shows prefill/decode tok/s — the same data the user's
/// `llama-speed` TUI plugin surfaces.
///
/// The llama.cpp base URL is resolved from the opencode service's provider
/// catalog (`GET /api/provider` → `settings.baseURL`), so the feed needs no
/// config of its own. When no provider points at a live llama.cpp `/stream`,
/// the feed stays quiet (no events) and never blocks the bridge.
class LlamaSpeedFeed {
  LlamaSpeedFeed({
    required Uri serviceBase,
    required String password,
    required void Function(String rawPayload) emit,
    this.reconnectDelay = const Duration(seconds: 2),
  }) : _service = serviceBase,
       _auth = 'Basic ${base64Encode(utf8.encode('$_user:$password'))}' {
    if (!_service.isScheme('http')) {
      throw ArgumentError('serviceBase must be http, got $_service');
    }
    _emit = emit;
  }

  /// Builds the feed from the shared-service descriptor the opencode service
  /// publishes at `~/.local/state/opencode/service.json` (`url` +
  /// `password`), or `null` when this machine has no shared opencode service
  /// (no descriptor) — in which case the speed header simply stays empty.
  static Future<LlamaSpeedFeed?> fromHost({
    String? statePath,
    required void Function(String rawPayload) emit,
  }) async {
    Uri serviceBase;
    String password;
    try {
      final file = File(
        statePath ?? '${homeDirectory()}/.local/state/opencode/service.json',
      );
      final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      serviceBase = Uri.parse(raw['url'] as String);
      password = raw['password'] as String;
    } catch (_) {
      return null;
    }
    return LlamaSpeedFeed(
      serviceBase: serviceBase,
      password: password,
      emit: emit,
    );
  }

  /// The Basic-auth username the shared service expects (the password comes
  /// from the service descriptor).
  static const String _user = 'opencode';

  /// How often steady-state throughput is re-emitted (phase changes and
  /// resets are never throttled).
  static const Duration _minEmitGap = Duration(milliseconds: 400);

  final Uri _service;
  final String _auth;
  late final void Function(String) _emit;
  final Duration reconnectDelay;

  bool _running = false;
  bool _stopped = false;

  /// The stream's [HttpClient], so [close] can interrupt a live `/stream`.
  HttpClient? _client;

  double? _prefill;
  double? _decode;
  DateTime? _lastEmit;

  /// The active phase (`idle` / `prefill` / `decode`) of the last emit, so a
  /// phase change is never throttled.
  String? _lastPhase;

  /// Begin resolving providers and subscribing to llama.cpp `/stream`.
  /// Idempotent.
  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop());
  }

  /// Stop the feed and release its connection.
  Future<void> close() async {
    _stopped = true;
    _running = false;
    final client = _client;
    _client = null;
    if (client != null) client.close(force: true);
  }

  Future<void> _loop() async {
    while (!_stopped) {
      final bases = await _providerBases();
      if (bases.isEmpty) {
        await Future<void>.delayed(reconnectDelay);
        continue;
      }
      for (var i = 0; i < bases.length && !_stopped; i++) {
        try {
          // Blocks until the stream ends (clean or dropped); the next cycle
          // re-resolves the providers.
          await _streamOnce(bases[i]);
          break;
        } catch (_) {
          // This candidate's `/stream` is not ok (404 on a non-llama.cpp
          // provider, etc.): try the next candidate.
        }
      }
      if (!_stopped) await Future<void>.delayed(reconnectDelay);
    }
  }

  /// The llama.cpp candidate base URLs, local hosts first, from the opencode
  /// service's provider catalog.
  Future<List<String>> _providerBases() async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        _service.replace(path: '/api/provider'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, _auth);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return const [];
      }
      final body = await response.transform(const Utf8Decoder()).join();
      final decoded = jsonDecode(body);
      final outer = decoded is Map<String, Object?>
          ? decoded
          : const <String, Object?>{};
      final data = outer['data'];
      final list = data is List ? data : const <Object?>[];
      final bases = <String>[];
      for (final item in list) {
        if (item is! Map<String, Object?>) continue;
        final settings = item['settings'];
        if (settings is! Map<String, Object?>) continue;
        final base = _normalizeBase(settings['baseURL']);
        if (base != null && !bases.contains(base)) bases.add(base);
      }
      bases.sort(_localFirst);
      return bases;
    } catch (_) {
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _streamOnce(String base) async {
    final client = HttpClient();
    _client = client;
    try {
      final request = await client.getUrl(Uri.parse('$base/stream'));
      request.headers.set('accept', 'text/event-stream');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw StateError('llama.cpp /stream was not ok');
      }
      var buffer = '';
      await for (final chunk in response.transform(const Utf8Decoder())) {
        if (_stopped) return;
        buffer += chunk;
        final frames = buffer.split('\n\n');
        buffer = frames.removeLast();
        for (final frame in frames) {
          _handleFrame(frame);
        }
      }
    } finally {
      _client = null;
      client.close(force: true);
    }
  }

  /// Parse one `event:` + `data:` SSE frame and fold it into the speed state.
  void _handleFrame(String frame) {
    var event = 'message';
    var data = '';
    for (final rawLine in frame.split('\n')) {
      final line = rawLine.endsWith('\r')
          ? rawLine.substring(0, rawLine.length - 1)
          : rawLine;
      if (line.startsWith('event:')) {
        event = line.substring('event:'.length).trim();
      } else if (line.startsWith('data:')) {
        var value = line.substring('data:'.length);
        if (value.startsWith(' ')) value = value.substring(1);
        data = value;
      }
    }
    if (data.isEmpty || data == '{}') return;
    Object? parsed;
    try {
      parsed = jsonDecode(data);
    } catch (_) {
      return;
    }
    if (parsed is! Map<String, Object?>) return;
    switch (event) {
      case 'timing':
        final n = (parsed['predicted_n'] as num?)?.toDouble();
        final ms = (parsed['predicted_ms'] as num?)?.toDouble();
        if (n != null && ms != null && n > 1 && ms > 1) {
          _setSpeed(prefill: null, decode: (n / ms) * 1000);
        }
      case 'prefill':
        final speed = (parsed['speed'] as num?)?.toDouble();
        if (speed != null) _setSpeed(prefill: speed, decode: null);
      case 'busy':
        // Idle (or a request boundary): clear the header.
        _setSpeed(prefill: null, decode: null);
    }
  }

  void _setSpeed({double? prefill, double? decode}) {
    final changed = prefill != _prefill || decode != _decode;
    _prefill = prefill;
    _decode = decode;
    if (!changed) return;
    _emitNow();
  }

  void _emitNow() {
    final phase = _decode != null
        ? 'decode'
        : _prefill != null
        ? 'prefill'
        : 'idle';
    final phaseChanged = phase != _lastPhase;
    final now = DateTime.now();
    final last = _lastEmit;
    // A phase change (idle ↔ prefill ↔ decode) is never throttled; only the
    // steady-state throughput of the same phase is capped at ~2.5/s.
    if (!phaseChanged && last != null && now.difference(last) < _minEmitGap) {
      return;
    }
    _lastPhase = phase;
    _lastEmit = now;
    _emit(
      bridgeEvent(
        type: BridgeEventType.llamaSpeed,
        data: {'prefill': _prefill, 'decode': _decode},
      ),
    );
  }

  /// Local hosts first, so the machine's own GGUF server is tried before the
  /// catalog's remote endpoints.
  static int _localFirst(String a, String b) {
    final al = _isLocal(a);
    final bl = _isLocal(b);
    if (al == bl) return 0;
    return al ? -1 : 1;
  }

  static bool _isLocal(String base) {
    final host = Uri.tryParse(base)?.host ?? '';
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host == '[::1]';
  }

  /// `http://localhost:8081/v1` → `http://localhost:8081` (the llama.cpp
  /// server root, where `/stream` and `/metrics` live).
  static String? _normalizeBase(Object? raw) {
    if (raw is! String) return null;
    var url = raw.trim();
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) return null;
    url = url.replaceAll(RegExp(r'/+$'), '');
    url = url.replaceFirst(RegExp(r'/v1$', caseSensitive: false), '');
    return url;
  }
}
