import 'dart:async';

import '../../model/orb.dart';
import 'opencode_event_service.dart';
import 'opencode_http_event_service.dart';

/// The aggregate [OpencodeEventService] (issue #95, spec §7.3): one
/// self-healing upstream `GET /api/event` per live service — the host plus
/// every running orb — fanned into a single [events] stream.
///
/// The events pass through **raw** (no envelope): session ids are globally
/// unique, so the host's and the orbs' events are indistinguishable and
/// need no tagging. The EventHub, the SSE contract, and the push dispatcher
/// are unchanged: they subscribe to this one stream as before, and orb
/// events drive push notifications like host events.
///
/// The per-orb upstreams are reconciled on a periodic interval from the
/// running orb list: a started orb gets an upstream, a stopped orb's
/// upstream is closed, and a respawn (a new `(url, password)` key) replaces
/// it. Each upstream is itself self-healing (it re-subscribes across the
/// orb service's own restarts), so a transient orb-service drop does not
/// wait for the next reconcile.
class CompositeOpencodeEventService implements OpencodeEventService {
  CompositeOpencodeEventService({
    required this.host,
    required this.orbList,
    required this.orbPassword,
    this.upstreamFactory = _defaultUpstreamFactory,
    this.refreshInterval = const Duration(seconds: 15),
    this.bootRetryInterval = const Duration(seconds: 2),
  }) {
    _controller = StreamController<OpencodeEvent>.broadcast(
      onListen: () => _onFirstListen(),
    );
  }

  /// The per-orb upstream: the same self-healing HTTP event service as the
  /// host, pointed at the orb's ephemeral URL with the orb's derived
  /// password (Basic `opencode:<password>`, spec §7.1).
  static OpencodeEventService _defaultUpstreamFactory(
    Uri baseUrl,
    String password,
  ) => OpencodeHttpEventService(baseUrl: baseUrl, password: password);

  final OpencodeEventService host;

  /// The running orb list (labels; `url` only for a running orb). May throw
  /// when docker is down (the composite degrades to host-only).
  final Future<List<OrbRecord>> Function() orbList;

  /// The orb's current `server password` (the last log line wins on a
  /// respawn), or `null` when it cannot be derived.
  final Future<String?> Function(String orbId) orbPassword;

  /// Builds the per-orb upstream from its ephemeral URL + derived password
  /// (injectable for tests; the default is the same HTTP event client as the
  /// host).
  final OpencodeEventService Function(Uri baseUrl, String password)
  upstreamFactory;

  /// How often the per-orb upstream set is reconciled (a started/stopped or
  /// respawned orb is picked up on the next pass).
  final Duration refreshInterval;

  /// How soon to retry after a pass that left a running orb without an
  /// upstream (still booting: its `server password` line is not in the log
  /// yet). Without it, a session the agent spawns the instant the orb is ready
  /// would stream only once the next [refreshInterval] pass attaches the orb,
  /// and its `session.created` / first turn could be invisible to the app for
  /// that whole window.
  final Duration bootRetryInterval;

  late final StreamController<OpencodeEvent> _controller;
  final Map<String, _OrbUpstream> _upstreams = {};
  StreamSubscription<OpencodeEvent>? _hostSubscription;
  Timer? _timer;
  Timer? _bootRetry;
  bool _started = false;
  bool _closed = false;
  Future<void>? _reconciling;

  @override
  Stream<OpencodeEvent> get events => _controller.stream;

  void _onFirstListen() {
    if (_started) return;
    _started = true;
    _hostSubscription = host.events.listen(_reemit);
    unawaited(_reconcile());
    _timer = Timer.periodic(refreshInterval, (_) => unawaited(_reconcile()));
  }

  void _reemit(OpencodeEvent event) {
    if (_closed || _controller.isClosed) return;
    _controller.add(event);
  }

  /// Coalesced reconcile: re-derives every running orb's upstream from the
  /// labels + the container log, closes the ones that went away, and
  /// replaces the ones whose `(url, password)` key changed.
  Future<void> _reconcile() {
    if (_closed) return Future.value();
    final inFlight = _reconciling;
    if (inFlight != null) return inFlight;
    final future = _doReconcile();
    _reconciling = future;
    future.whenComplete(() {
      if (identical(_reconciling, future)) _reconciling = null;
    });
    return future;
  }

  Future<void> _doReconcile() async {
    final records = <OrbRecord>[];
    try {
      records.addAll(await orbList());
    } catch (_) {
      // Docker is down (or the labels unreadable): degrade to host-only.
    }
    final live = <String>{};
    var booting = false;
    for (final record in records) {
      final url = record.url;
      if (record.state != 'running' || url == null) continue;
      final password = await orbPassword(record.id);
      if (password == null) {
        // Running but still booting (no `server password` line in the log
        // yet). Its sessions start streaming the instant that line lands,
        // so retry soon instead of waiting for the next full pass.
        booting = true;
        continue;
      }
      live.add(record.id);
      final key = '$url|$password';
      final existing = _upstreams[record.id];
      if (existing != null && existing.key == key) continue;
      if (existing != null) {
        await existing.subscription.cancel();
        await existing.upstream.close();
      }
      final upstream = upstreamFactory(Uri.parse(url), password);
      _upstreams[record.id] = _OrbUpstream(
        key: key,
        upstream: upstream,
        subscription: upstream.events.listen(_reemit),
      );
    }
    for (final gone
        in _upstreams.keys.where((id) => !live.contains(id)).toList()) {
      final entry = _upstreams.remove(gone)!;
      await entry.subscription.cancel();
      await entry.upstream.close();
    }
    if (booting) _scheduleBootRetry();
  }

  /// One short-timer retry for a pass that saw a running orb still booting
  /// (no password yet in its log). A retry that finds it still booting
  /// schedules the next one, so the attach happens within [bootRetryInterval]
  /// of the log line landing — long before the next [refreshInterval] pass.
  void _scheduleBootRetry() {
    if (_closed || _bootRetry?.isActive == true) return;
    _bootRetry = Timer(bootRetryInterval, () => unawaited(_reconcile()));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final timer = _timer;
    _timer = null;
    timer?.cancel();
    final bootRetry = _bootRetry;
    _bootRetry = null;
    bootRetry?.cancel();
    await _hostSubscription?.cancel();
    for (final entry in _upstreams.values) {
      await entry.subscription.cancel();
      await entry.upstream.close();
    }
    _upstreams.clear();
    await host.close();
    if (!_controller.isClosed) await _controller.close();
  }
}

/// One live per-orb event upstream and the `(url, password)` key it was
/// derived from (a key change — a respawn's new port/password — replaces it).
class _OrbUpstream {
  const _OrbUpstream({
    required this.key,
    required this.upstream,
    required this.subscription,
  });

  final String key;
  final OpencodeEventService upstream;
  final StreamSubscription<OpencodeEvent> subscription;
}
