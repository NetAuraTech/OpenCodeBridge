import 'dart:async';

import 'package:flutter/material.dart';

import '../client/docker_client.dart';
import '../client/events_client.dart';
import '../model/container.dart';

/// The Docker tab (issue #21): the host's container list, each row opening
/// the detail (state, the start/stop/restart actions, the live log stream
/// with a client-side keyword filter). The list and the detail refresh from
/// the bridge's native `docker.container.*` events (spec §8), so neither
/// polls.
class DockerTab extends StatefulWidget {
  const DockerTab({super.key, required this.apiBase, this.client, this.events});

  /// Where the bridge's docker API lives. `null` when this client has no
  /// bridge to point at (client mode without a tunnel URL yet).
  final Uri? apiBase;

  /// The client for the bridge's docker API. Defaults to a real
  /// [DockerClient] at [apiBase]; tests inject a fake.
  final DockerClient? client;

  /// The source of the bridge's unified event stream (spec §8) the tab and
  /// its detail listen to. Defaults to a real [EventsClient] at [apiBase]
  /// (owned and disconnected by the tab); tests inject a scripted source.
  final EventSource? events;

  @override
  State<DockerTab> createState() => _DockerTabState();
}

class _DockerTabState extends State<DockerTab> {
  DockerClient? _client;

  /// The event stream source (spec §8) the tab listens to, `null` when there
  /// is no bridge to listen on.
  EventSource? _events;

  /// True when [_events] is this tab's own [EventsClient] (to disconnect in
  /// [dispose]); a provided [EventSource] is owned by the caller.
  bool _ownsEvents = false;

  StreamSubscription<BridgeEvent>? _eventSub;

  /// The fetched rows, `null` until the first successful load.
  List<DockerContainer>? _rows;

  /// The last load failure, if any.
  String? _error;

  /// True while a load is in flight.
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final base = widget.apiBase;
    if (base != null) {
      _client = widget.client ?? DockerClient(base);
      _setupEvents(base);
      _load();
    } else {
      _loading = false;
    }
  }

  @override
  void didUpdateWidget(covariant DockerTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.apiBase != oldWidget.apiBase && widget.apiBase != null) {
      _client = widget.client ?? DockerClient(widget.apiBase!);
      _setupEvents(widget.apiBase!);
      _load();
    }
  }

  @override
  void dispose() {
    _teardownEvents();
    super.dispose();
  }

  /// Sets up the event source (spec §8): the provided one, or a real
  /// [EventsClient] at [base] owned (and disconnected) by the tab.
  void _setupEvents(Uri base) {
    _teardownEvents();
    final provided = widget.events;
    if (provided != null) {
      _events = provided;
    } else {
      _events = EventsClient(base);
      _ownsEvents = true;
    }
    unawaited(_events!.connect());
    _eventSub = _events!.events.listen(_onEvent);
  }

  /// Stops the event source, disconnecting it only when the tab owns it.
  void _teardownEvents() {
    final source = _events;
    _events = null;
    _eventSub?.cancel();
    _eventSub = null;
    if (source == null) return;
    if (_ownsEvents) {
      _ownsEvents = false;
      unawaited(source.disconnect());
    }
  }

  /// A docker container stopped (cleanly) or crashed (non-zero exit): the
  /// list re-fetches so the state and uptime columns are up to date.
  void _onEvent(BridgeEvent event) {
    if (event.type != 'docker.container.stopped' &&
        event.type != 'docker.container.crashed') {
      return;
    }
    _load();
  }

  Future<void> _load() async {
    final client = _client;
    if (client == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await client.list();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } on DockerClientError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.statusCode == 0
            ? 'Cannot reach the bridge.'
            : 'The bridge could not list containers (status ${e.statusCode}).';
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the container list.';
        _loading = false;
      });
    }
  }

  /// Opens the detail for [row]: state, the start/stop/restart actions, and
  /// the live log stream. When the detail closes, the list re-loads.
  Future<void> _openDetail(DockerContainer row) async {
    final client = _client;
    if (client == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => _ContainerDetailScreen(
          client: client,
          container: row,
          events: _events?.events,
        ),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.apiBase;
    if (base == null) {
      return const _CenteredMessage(
        text: 'No bridge configured. Set the tunnel URL in Settings.',
      );
    }
    if (_loading && _rows == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_rows == null) {
      final error = _error ?? 'Could not load the container list.';
      return _ErrorState(message: error, onRetry: _load);
    }
    final rows = _rows!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 8),
        children: [
          if (rows.isEmpty) const _CenteredMessage(text: 'No containers.'),
          for (final row in rows)
            _ContainerRow(container: row, onTap: () => _openDetail(row)),
        ],
      ),
    );
  }
}

/// One row of the container list: the name, the image, the state dot, and
/// the uptime (the state word when the container is not running).
class _ContainerRow extends StatelessWidget {
  const _ContainerRow({required this.container, required this.onTap});

  final DockerContainer container;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        key: ValueKey('container-${container.name}'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            _StateDot(state: container.state),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    container.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    container.image,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              container.uptime ?? container.state.wire,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The container's state as a color dot: green while running, amber paused,
/// blue while restarting, red on death, grey otherwise.
Color _stateColor(DockerState state) => switch (state) {
  DockerState.running => Colors.green,
  DockerState.paused => Colors.orange,
  DockerState.restarting => Colors.blue,
  DockerState.dead => Colors.red,
  _ => Colors.grey,
};

class _StateDot extends StatelessWidget {
  const _StateDot({required this.state});

  final DockerState state;

  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey('state-${state.wire}'),
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      color: _stateColor(state),
      shape: BoxShape.circle,
    ),
  );
}

/// The detail for one container (issue #21): the state, the
/// start/stop/restart actions, and the live log stream with the keyword
/// filter. Its state column refreshes from the bridge's native
/// `docker.container.*` events for this container (spec §8).
class _ContainerDetailScreen extends StatefulWidget {
  const _ContainerDetailScreen({
    required this.client,
    required this.container,
    this.events,
  });

  final DockerClient client;
  final DockerContainer container;

  /// The unified event stream (a broadcast stream from the tab's
  /// [EventSource]); `null` when there is no bridge to listen on.
  final Stream<BridgeEvent>? events;

  @override
  State<_ContainerDetailScreen> createState() => _ContainerDetailScreenState();
}

class _ContainerDetailScreenState extends State<_ContainerDetailScreen> {
  late DockerContainer _container = widget.container;

  /// The action in flight, if any (its button shows progress).
  DockerAction? _busy;

  StreamSubscription<BridgeEvent>? _sub;

  @override
  void initState() {
    super.initState();
    final events = widget.events;
    if (events != null) {
      _sub = events.listen((event) {
        if (event.type != 'docker.container.stopped' &&
            event.type != 'docker.container.crashed') {
          return;
        }
        if (event.data['name'] != _container.name) return;
        _refreshState();
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// Re-fetches the container list and keeps this container's row fresh.
  /// The bridge emits a `docker.container.*` event for every stop/crash,
  /// but the detail should not wait for it after its own action.
  Future<void> _refreshState() async {
    final client = widget.client;
    final name = _container.name;
    try {
      final rows = await client.list();
      for (final row in rows) {
        if (row.name == name) {
          if (mounted) setState(() => _container = row);
          return;
        }
      }
    } catch (_) {
      // The bridge went away mid-refresh; the row keeps its last state.
    }
  }

  Future<void> _act(DockerAction action) async {
    final client = widget.client;
    if (_busy != null) return;
    final name = _container.name;
    setState(() => _busy = action);
    try {
      await client.action(name, action);
      if (!mounted) return;
      await _refreshState();
    } on DockerClientError catch (e) {
      if (!mounted) return;
      _snackBar(
        'Could not ${action.wire} the container '
        '(status ${e.statusCode == 0 ? 'unreachable' : '${e.statusCode}'})',
      );
    } catch (_) {
      if (!mounted) return;
      _snackBar('Could not ${action.wire} the container.');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  bool _can(DockerAction action) => switch (action) {
    DockerAction.start => _container.state != DockerState.running,
    DockerAction.stop => _container.state == DockerState.running,
    DockerAction.restart => _container.state == DockerState.running,
  };

  void _snackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final uptime = _container.uptime;
    return Scaffold(
      appBar: AppBar(title: Text(_container.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_container.name, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            _container.image,
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _StateBadge(state: _container.state),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  uptime ?? 'Not running',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              for (final action in DockerAction.values)
                _ActionButton(
                  action: action,
                  busy: _busy == action,
                  enabled: _can(action),
                  onPressed: () => _act(action),
                ),
            ],
          ),
          const SizedBox(height: 24),
          const Text('Logs'),
          const SizedBox(height: 8),
          _LogView(client: widget.client, name: _container.name),
        ],
      ),
    );
  }
}

/// One start/stop/restart action button (issue #21). Disabled while the
/// container's state does not admit the action or while an action is in
/// flight (then the button shows progress).
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.action,
    required this.busy,
    required this.enabled,
    required this.onPressed,
  });

  final DockerAction action;
  final bool busy;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Padding(
      padding: const EdgeInsets.only(right: 8),
      child: OutlinedButton(
        key: ValueKey('docker-action-${action.wire}'),
        onPressed: busy || !enabled ? null : onPressed,
        child: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(action.wire[0].toUpperCase() + action.wire.substring(1)),
      ),
    ),
  );
}

/// The state badge of the detail: the dot plus the state word on a tinted
/// background.
class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.state});

  final DockerState state;

  @override
  Widget build(BuildContext context) {
    final color = _stateColor(state);
    return Container(
      key: ValueKey('state-${state.wire}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            state.wire,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// The live log stream of one container (issue #21): the bridge's SSE log
/// stream rendered newest-at-the-bottom (the reverse scroll keeps the view
/// pinned to the newest output), above a keyword filter that this client
/// applies to the received lines (the bridge never filters).
class _LogView extends StatefulWidget {
  const _LogView({required this.client, required this.name});

  final DockerClient client;
  final String name;

  @override
  State<_LogView> createState() => _LogViewState();
}

class _LogViewState extends State<_LogView> {
  /// The cap on retained lines (oldest drop off).
  static const int _maxLines = 3000;

  final _filter = TextEditingController();
  final List<String> _lines = [];
  String? _error;
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _filter.addListener(() {
      if (mounted) setState(() {});
    });
    _sub = widget.client
        .logs(widget.name, follow: true)
        .listen(
          (line) {
            setState(() {
              _error = null;
              _lines.add(line);
              if (_lines.length > _maxLines) {
                _lines.removeRange(0, _lines.length - _maxLines);
              }
            });
          },
          onError: (Object error) {
            setState(() {
              _error = error is DockerClientError
                  ? 'Logs unavailable '
                        '(status ${error.statusCode == 0 ? 'unreachable' : '${error.statusCode}'})'
                  : 'Logs unavailable';
            });
          },
          cancelOnError: true,
        );
  }

  @override
  void dispose() {
    _filter.dispose();
    _sub?.cancel();
    super.dispose();
  }

  /// The received lines after the keyword filter (case-insensitive; the
  /// bridge streams verbatim and never filters).
  List<String> get _visible {
    final filter = _filter.text.trim().toLowerCase();
    if (filter.isEmpty) return _lines;
    return [
      for (final line in _lines)
        if (line.toLowerCase().contains(filter)) line,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final lines = _visible;
    final error = _error;
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: TextField(
            key: const ValueKey('docker-log-filter'),
            controller: _filter,
            decoration: const InputDecoration(
              hintText: 'Filter logs…',
              prefixIcon: Icon(Icons.filter_alt_outlined),
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          key: const ValueKey('docker-logs'),
          height: 320,
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: error != null && lines.isEmpty
              ? Padding(padding: const EdgeInsets.all(12), child: Text(error))
              : lines.isEmpty
              ? const Center(child: Text('No log output.'))
              : SingleChildScrollView(
                  key: const ValueKey('docker-logs-scroll'),
                  reverse: true,
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final line in lines)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(
                            line,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('docker-retry'),
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    ),
  );
}
