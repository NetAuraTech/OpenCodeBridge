import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:opencodebridge/bridge/events/event_frame.dart'
    show BridgeEvent, Durable, parseEventFrame;
import 'package:opencodebridge/client/authenticated_http.dart';
import 'package:opencodebridge/sse/sse.dart';

// The event envelope ([BridgeEvent], [Durable], and the one session-identity
// rule in [BridgeEvent.sessionId]) lives in the bridge layer, because the
// bridge's own event connections consume it directly and the bridge must not
// depend on the client (ADR-0001). This file re-exports it so the app-side
// public surface is unchanged (issue #256, S2c).
export 'package:opencodebridge/bridge/events/event_frame.dart'
    show BridgeEvent, Durable;

/// A detected gap in one session's durable seq: events were missed between
/// [lastSeen] and [received] (typically across a reconnect). The app uses it
/// to catch up (re-fetch that session's state).
class SessionGap {
  const SessionGap({
    required this.aggregateID,
    required this.lastSeen,
    required this.received,
  });

  final String aggregateID;
  final int lastSeen;
  final int received;
}

/// A failure of the bridge events endpoint, carrying the bridge's status
/// (0 when the bridge could not be reached at all).
class EventsClientError implements Exception {
  const EventsClientError(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'EventsClientError($statusCode: $message)';
}

/// A live source of the bridge's unified event stream (spec §8,
/// endpoint 14). The owner drives [connect] and [disconnect]; the UI listens
/// to [events]. [EventsClient] is the production implementation; tests
/// implement it with a scripted stream.
abstract class EventSource {
  /// Every event off the stream, decoded, in order.
  Stream<BridgeEvent> get events;

  /// Gaps detected in a session's durable seq (events missed, typically
  /// across a reconnect), so a listener can catch up on its session.
  Stream<SessionGap> get gaps;

  /// Open the stream and start receiving events. Idempotent.
  Future<void> connect();

  /// Stop receiving and release the connection.
  Future<void> disconnect();

  /// Force a fresh connection (issue #41, app lifecycle): on returning to
  /// the foreground, the stream reconnects (with the current Access token)
  /// instead of waiting for the dropped connection to time out.
  Future<void> reconnect();
}

/// The app-side client of the bridge's unified event stream (spec §8,
/// endpoint 14). The app talks only to the bridge (ADR-0001): in server mode
/// that is loopback, in client mode the same API behind the tunnel.
///
/// The client opens `GET /api/events`, decodes every `data:` frame into a
/// [BridgeEvent], and tracks the per-session durable [Durable.seq]. When a
/// session's seq jumps (an event was missed — e.g. the connection dropped),
/// it emits a [SessionGap] so the app can catch up. It auto-reconnects on
/// disconnect, preserving the seq map across reconnects so a gap spanning the
/// drop is still detected.
class EventsClient implements EventSource {
  EventsClient(
    this._base, {
    this.reconnectDelay = const Duration(milliseconds: 500),
    this._auth,
  });

  /// The bridge's base URI, e.g. `http://127.0.0.1:48201/`.
  final Uri _base;

  /// How long to wait before reconnecting after the stream drops.
  final Duration reconnectDelay;

  /// The Access login's header provider (issue #23); `null` in server mode.
  /// Re-read on every (re)connect, so a dropped stream comes back with a
  /// refreshed token.
  final AuthHeaderProvider? _auth;

  final StreamController<BridgeEvent> _events =
      StreamController<BridgeEvent>.broadcast();
  final StreamController<SessionGap> _gaps =
      StreamController<SessionGap>.broadcast();

  /// The per-session durable seq last seen, keyed by session id. Preserved
  /// across reconnects so a gap spanning a disconnect is detected.
  final Map<String, int> _lastSeq = {};

  bool _running = false;
  bool _stopped = false;
  int _generation = 0;
  HttpClient? _client;

  /// Every event off the stream, decoded, in order. Listen before (or right
  /// after) [connect] to avoid missing the early frames.
  @override
  Stream<BridgeEvent> get events => _events.stream;

  /// Gaps detected in a session's durable seq.
  @override
  Stream<SessionGap> get gaps => _gaps.stream;

  /// Open the SSE stream and start receiving events. Idempotent.
  @override
  Future<void> connect() {
    if (_running) return Future<void>.value();
    _running = true;
    _stopped = false;
    final generation = ++_generation;
    unawaited(_loop(generation));
    return Future<void>.value();
  }

  /// Stop receiving and release the connection.
  @override
  Future<void> disconnect() async {
    _stopped = true;
    _running = false;
    _generation++; // Invalidate any in-flight loop.
    final client = _client;
    _client = null;
    if (client != null) client.close(force: true);
  }

  /// Force a fresh connection (issue #41, app lifecycle): drop the current
  /// stream (if any) and reconnect. The per-session seq map survives, so a
  /// gap spanning the drop is still detected.
  @override
  Future<void> reconnect() async {
    await disconnect();
    await connect();
  }

  Future<void> _loop(int generation) async {
    while (!_stopped && _generation == generation) {
      try {
        await _connectOnce();
      } catch (_) {
        // A failed/aborted connection: fall through and (re)try below.
      }
      if (_stopped || _generation != generation) break;
      await Future<void>.delayed(reconnectDelay);
    }
  }

  Future<void> _connectOnce() async {
    final client = HttpClient();
    _client = client;
    try {
      final response = await bridgeRequest(
        client,
        'GET',
        _base.replace(path: 'api/events'),
        auth: _auth,
      );
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw EventsClientError(
          response.statusCode,
          'events stream was not ok',
        );
      }
      final payloads = sseDataLines(response.transform(const Utf8Decoder()));
      await for (final payload in payloads) {
        if (_stopped) return;
        _handle(payload);
      }
    } on EventsClientError {
      rethrow;
    } catch (error) {
      throw EventsClientError(0, '$error');
    } finally {
      _client = null;
      client.close(force: true);
    }
  }

  void _handle(String payload) {
    final event = parseBridgeEvent(payload);
    if (event == null) return;
    _trackGap(event);
    if (!_events.isClosed) _events.add(event);
  }

  void _trackGap(BridgeEvent event) {
    final durable = event.durable;
    if (durable == null) {
      return; // No seq (bridge-native, etc.): side-effect only.
    }
    final last = _lastSeq[durable.aggregateID];
    if (last == null) {
      _lastSeq[durable.aggregateID] = durable.seq;
      return; // First sight of this aggregate: establish the baseline.
    }
    if (durable.seq > last + 1) {
      if (!_gaps.isClosed) {
        _gaps.add(
          SessionGap(
            aggregateID: durable.aggregateID,
            lastSeen: last,
            received: durable.seq,
          ),
        );
      }
    }
    if (durable.seq > last) _lastSeq[durable.aggregateID] = durable.seq;
  }
}

/// Decode one `data:` payload into a [BridgeEvent], or `null` when it is not
/// a well-formed event object.
///
/// Delegates to the one shared decode in the bridge layer (issue #256, S2c),
/// so the client and the bridge-side event connections read the stream the
/// same way.
BridgeEvent? parseBridgeEvent(String payload) => parseEventFrame(payload);
