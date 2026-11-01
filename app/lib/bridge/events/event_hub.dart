import 'dart:async';
import 'dart:io';

import 'opencode_event_service.dart';

/// A downstream SSE connection the [EventHub] fans out to (one app
/// `GET /api/events` connection). The hub only ever calls [write] with a
/// verbatim `data:` payload; the connection owns the SSE framing and its
/// keep-alive.
abstract class EventConnection {
  /// Write a verbatim `data:` payload to this connection (the hub writes
  /// `data: <payload>\n\n`).
  Future<void> write(String rawPayload);

  /// Close the connection.
  Future<void> close();

  /// Completes when the connection is gone — closed by the bridge, or the
  /// client disconnected. The hub drops the connection when this completes.
  Future<void> get done;
}

/// The bridge's unified event fan-out (spec §8, endpoint 14).
///
/// The hub holds the bridge's **single** upstream [OpencodeEventService]
/// subscription and re-emits every opencode event **verbatim** to any number
/// of downstream [EventConnection]s (the app SSE connections). Bridge-native
/// events (spec §8: `session.closed`, `terminal.closed`, `docker.*`) are
/// multiplexed onto the same stream through [emit]. Every live connection
/// receives an identical frame for every event, so a raw SSE client and the
/// app always see the same stream.
class EventHub {
  EventHub({required OpencodeEventService service}) : _service = service {
    _upstream = service.events.listen(_ingest);
  }

  final OpencodeEventService _service;
  late final StreamSubscription<OpencodeEvent> _upstream;
  final Set<EventConnection> _live = {};
  bool _closed = false;

  /// The number of downstream connections currently attached (tests/observability).
  int get connections => _live.length;

  /// Attach a downstream connection to the fan-out. The connection is dropped
  /// automatically when its [EventConnection.done] completes.
  void add(EventConnection connection) {
    if (_closed) {
      unawaited(connection.close());
      return;
    }
    _live.add(connection);
    unawaited(connection.done.then((_) => _live.remove(connection)));
  }

  /// Detaches [connection] from the fan-out without closing it (the
  /// bridge's notify reload swaps the push dispatcher for a fresh one);
  /// the caller owns the connection's close.
  void remove(EventConnection connection) => _live.remove(connection);

  /// Fan out a verbatim `data:` payload to every live connection.
  void emit(String rawPayload) {
    if (_closed) return;
    for (final connection in Set.of(_live)) {
      unawaited(_safeWrite(connection, rawPayload));
    }
  }

  Future<void> _safeWrite(EventConnection connection, String payload) async {
    try {
      await connection.write(payload);
    } catch (_) {
      // The client went away; its [EventConnection.done] drops it.
    }
  }

  void _ingest(OpencodeEvent event) => emit(event.raw);

  /// Detach every connection, cancel the upstream subscription, and close the
  /// upstream service.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _upstream.cancel();
    for (final connection in Set.of(_live)) {
      try {
        await connection.close();
      } catch (_) {
        // The client is already gone; closing is best-effort.
      }
    }
    _live.clear();
    await _service.close();
  }
}

/// An [EventConnection] over one app `GET /api/events` [HttpResponse].
///
/// It writes each payload as `data: <payload>\n\n` and sends a per-client
/// keep-alive comment (`: keep-alive\n\n`) so an idle tunnel connection is not
/// reaped. The service's own `: heartbeat` lines are dropped (they never reach
/// the hub), so keep-alive is the bridge's, per client.
class HttpEventConnection implements EventConnection {
  HttpEventConnection(
    this._response, {
    Duration keepAliveInterval = const Duration(seconds: 20),
  }) {
    _response.bufferOutput = false;
    // The response encodes its `write`s with the content-type's charset
    // (the bridge sets `text/event-stream; charset=utf-8`). The old default
    // was Latin-1, whose encoder threw on any character above U+00FF — one
    // such token in a streamed delta used to abort the write and drop the
    // whole connection from the fan-out.
    // An initial comment flushes the response headers on connect (the client
    // is blocked on them) and marks the stream live.
    _response.write(': connected\n\n');
    _timer = Timer.periodic(keepAliveInterval, (_) => _keepAlive());
    unawaited(_response.done.then((_) => _markGone()));
  }

  final HttpResponse _response;
  late final Timer _timer;
  final Completer<void> _gone = Completer<void>();
  bool _done = false;

  @override
  Future<void> get done => _gone.future;

  @override
  Future<void> write(String rawPayload) async {
    if (_done) return;
    try {
      _response.write('data: $rawPayload\n\n');
    } catch (_) {
      _markGone();
    }
  }

  void _keepAlive() {
    if (_done) return;
    try {
      _response.write(': keep-alive\n\n');
    } catch (_) {
      _markGone();
    }
  }

  void _markGone() {
    if (_done) return;
    _done = true;
    _timer.cancel();
    if (!_gone.isCompleted) _gone.complete();
  }

  @override
  Future<void> close() async {
    if (_done) return;
    _done = true;
    _timer.cancel();
    try {
      await _response.close();
    } catch (_) {
      // The client is already gone; closing is idempotent.
    }
    if (!_gone.isCompleted) _gone.complete();
  }
}
