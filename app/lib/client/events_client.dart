import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:opencodebridge/sse/sse.dart';

/// The durable position of an opencode event within its session aggregate.
/// [aggregateID] is the session id; [seq] increases by one per event for that
/// session, so a jump in [seq] means events were missed (a gap).
class Durable {
  const Durable({required this.aggregateID, required this.seq});

  /// The session aggregate the event belongs to (`durable.aggregateID`).
  final String aggregateID;

  /// The per-session sequence number (`durable.seq`).
  final int seq;
}

/// One event off the bridge's unified `GET /api/events` stream, decoded.
///
/// Both opencode events and bridge-native events ([`session.closed`],
/// [`terminal.closed`], `docker.*`) arrive on the same stream in the same
/// `data: {id, created, type, data[, durable]}` envelope. Bridge-native events
/// (and opencode's own non-durable ones, e.g. `server.connected`) carry no
/// [durable], so they never participate in per-session seq gap detection.
class BridgeEvent {
  const BridgeEvent({
    required this.id,
    required this.created,
    required this.type,
    required this.data,
    this.durable,
  });

  final String id;
  final int created;
  final String type;

  /// The event's payload (`data`), e.g. the session/step details.
  final Map<String, Object?> data;

  /// The durable position, or `null` when the event carries no seq.
  final Durable? durable;
}

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
  });

  /// The bridge's base URI, e.g. `http://127.0.0.1:48201/`.
  final Uri _base;

  /// How long to wait before reconnecting after the stream drops.
  final Duration reconnectDelay;

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
      final request = await client.getUrl(_base.replace(path: 'api/events'));
      final response = await request.close();
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
BridgeEvent? parseBridgeEvent(String payload) {
  Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } catch (_) {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  final id = decoded['id'] is String ? decoded['id'] as String : '';
  final created = (decoded['created'] as num?)?.toInt() ?? 0;
  final type = decoded['type'] is String ? decoded['type'] as String : '';
  final data = decoded['data'] is Map<String, Object?>
      ? decoded['data'] as Map<String, Object?>
      : const <String, Object?>{};
  Durable? durable;
  final d = decoded['durable'];
  if (d is Map<String, Object?>) {
    final aggregateID = d['aggregateID'] is String
        ? d['aggregateID'] as String
        : null;
    final seq = (d['seq'] as num?)?.toInt();
    if (aggregateID != null && seq != null) {
      durable = Durable(aggregateID: aggregateID, seq: seq);
    }
  }
  return BridgeEvent(
    id: id,
    created: created,
    type: type,
    data: data,
    durable: durable,
  );
}
