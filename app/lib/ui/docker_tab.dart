import 'dart:async';

import 'package:flutter/material.dart';

import '../access/access_session.dart';
import '../client/authenticated_http.dart';
import '../client/docker_client.dart';
import '../client/events_client.dart';
import '../model/compose_project.dart';
import '../model/container.dart';

/// The Docker tab (issue #21): the host's container list, each row opening
/// the detail (state, the start/stop/restart actions, the live log stream
/// with a client-side keyword filter). The list and the detail refresh from
/// the bridge's native `docker.container.*` events (spec §8), so neither
/// polls.
class DockerTab extends StatefulWidget {
  const DockerTab({
    super.key,
    required this.apiBase,
    this.client,
    this.events,
    this.auth,
    this.access,
    this.deepLinkContainer,
    this.onDeepLinkContainerConsumed,
  });

  /// Where the bridge's docker API lives. `null` when this client has no
  /// bridge to point at (client mode without a tunnel URL yet).
  final Uri? apiBase;

  /// The client for the bridge's docker API. Defaults to a real
  /// [DockerClient] at [apiBase]; tests inject a fake.
  final DockerClient? client;

  /// The Access login's header provider (issue #23, client mode); `null` in
  /// server mode.
  final AuthHeaderProvider? auth;

  /// The tunnel's Access login (issue #23, client mode); `null` in server
  /// mode. The tab re-fetches when the login completes: the browser bounce
  /// brings the app to the foreground before the token exchange finishes, so
  /// the foreground re-fetch hits a `401` and the finishing login is what
  /// carries the token (issue #41).
  final AccessSession? access;

  /// The source of the bridge's unified event stream (spec §8) the tab and
  /// its detail listen to. Defaults to a real [EventsClient] at [apiBase]
  /// (owned and disconnected by the tab); tests inject a scripted source.
  final EventSource? events;

  /// The one-shot deep link (issue #24): the container to open in its detail
  /// when a tapped notification targets it; `null` when there is nothing to
  /// open. The tab consumes it through [onDeepLinkContainerConsumed] (which
  /// the caller uses to clear the target, so a later identical link is a new
  /// event).
  final String? deepLinkContainer;
  final VoidCallback? onDeepLinkContainerConsumed;

  @override
  State<DockerTab> createState() => DockerTabState();
}

class DockerTabState extends State<DockerTab> with WidgetsBindingObserver {
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

  /// The fetched compose projects (issue #21 follow-on), `null` until the
  /// first successful compose load.
  List<ComposeProject>? _composeProjects;

  /// The last compose load failure, if any.
  String? _composeError;

  /// True while a compose load is in flight.
  bool _composeLoading = true;

  /// The deep-link container awaiting a loaded list (issue #24): set when
  /// the target arrives before the rows; a failed load leaves it for the
  /// next successful one.
  String? _deepLinkPending;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final base = widget.apiBase;
    if (base != null) {
      _client = widget.client ?? DockerClient(base, auth: widget.auth);
      _setupEvents(base);
      widget.access?.addListener(_onAccessState);
      _load();
      _loadCompose();
    } else {
      _loading = false;
      _composeLoading = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed || _client == null) return;
    // Android suspends the app (issue #41): on returning to the foreground,
    // go out again, so container state that changed while backgrounded
    // shows up on return.
    _reloadWithToken();
  }

  void _onAccessState(AccessLoginState state) {
    if (state != AccessLoginState.loggedIn) return;
    // The login finished (issue #41): the browser bounce brought the app to
    // the foreground before the token exchange finished, so the foreground
    // re-fetch saw a `401`; now the token is in hand.
    _reloadWithToken();
  }

  /// Re-connects the event stream with the current Access token and
  /// re-fetches both views.
  void _reloadWithToken() {
    final events = _events;
    if (events != null) unawaited(events.reconnect());
    unawaited(_refreshAll());
  }

  @override
  void didUpdateWidget(covariant DockerTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.access != oldWidget.access) {
      oldWidget.access?.removeListener(_onAccessState);
      widget.access?.addListener(_onAccessState);
    }
    if (widget.apiBase != oldWidget.apiBase && widget.apiBase != null) {
      _client =
          widget.client ?? DockerClient(widget.apiBase!, auth: widget.auth);
      _setupEvents(widget.apiBase!);
      _load();
      _loadCompose();
    }
    final target = widget.deepLinkContainer;
    if (target != null && target != oldWidget.deepLinkContainer) {
      // The target arrives as a widget update, which runs during the build
      // phase: open it after the frame so the [Navigator.push] below never
      // happens mid-build (a push mid-build corrupts the navigator's
      // history, leaving the view with no route back to the list).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openDeepLink(target);
      });
    }
  }

  /// A tapped notification targeted a container (issue #24): open its
  /// detail. Consumed immediately (the caller clears the target); when the
  /// list has not loaded yet, the target waits for it in [_deepLinkPending].
  void _openDeepLink(String name) {
    widget.onDeepLinkContainerConsumed?.call();
    final rows = _rows;
    if (rows == null) {
      _deepLinkPending = name;
      return;
    }
    _openDeepLinkRow(name, rows);
  }

  void _openDeepLinkRow(String name, List<DockerContainer> rows) {
    _deepLinkPending = null;
    final row = rows.where((container) => container.name == name).firstOrNull;
    if (row == null) return; // The container is gone (removed in the meantime).
    unawaited(_openDetail(row));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.access?.removeListener(_onAccessState);
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
      _events = EventsClient(base, auth: widget.auth);
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

  /// A docker container stopped (cleanly) or crashed (non-zero exit): both
  /// views re-fetch so the state and uptime columns stay up to date in the
  /// container list and in the compose section.
  void _onEvent(BridgeEvent event) {
    if (event.type != 'docker.container.stopped' &&
        event.type != 'docker.container.crashed') {
      return;
    }
    _refreshAll();
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
      final pending = _deepLinkPending;
      setState(() {
        _rows = rows;
        _loading = false;
      });
      if (pending != null) _openDeepLinkRow(pending, rows);
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

  /// Loads the compose projects (issue #21 follow-on) among the repos
  /// opencode lists. Independent of the container load: a compose failure
  /// degrades only the compose section, never the container list.
  Future<void> _loadCompose() async {
    final client = _client;
    if (client == null) return;
    setState(() {
      _composeError = null;
      _composeLoading = true;
    });
    try {
      final projects = await client.compose();
      if (!mounted) return;
      setState(() {
        _composeProjects = projects;
        _composeLoading = false;
      });
    } on DockerClientError catch (e) {
      if (!mounted) return;
      setState(() {
        _composeError = e.statusCode == 0
            ? 'Cannot reach the bridge.'
            : 'The bridge could not list compose projects '
                  '(status ${e.statusCode}).';
        _composeLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _composeError = 'Could not load the compose projects.';
        _composeLoading = false;
      });
    }
  }

  /// Re-fetches both views of the containers — the list and the compose
  /// projects — so they can never disagree. Used by pull-to-refresh and
  /// after every operation that can change a container's state.
  Future<void> _refreshAll() async {
    await _load();
    await _loadCompose();
  }

  /// Opens the detail for [row]: state, the start/stop/restart actions, and
  /// the live log stream. When the detail closes, both views re-load — the
  /// actions could have changed a container the compose section also shows.
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
    if (mounted) await _refreshAll();
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
      onRefresh: _refreshAll,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 8),
        children: [
          if (rows.isEmpty) const _CenteredMessage(text: 'No containers.'),
          for (final row in rows)
            _ContainerRow(container: row, onTap: () => _openDetail(row)),
          const SizedBox(height: 12),
          _ComposeSection(
            client: _client!,
            projects: _composeProjects,
            loading: _composeLoading,
            error: _composeError,
            reload: _refreshAll,
          ),
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

/// One compose up/stop decision (the project's, or one service's).
typedef _ComposeOnAction = void Function(
  ComposeAction action, {
  String? service,
});

/// The compose section of the Docker tab (issue #21 follow-on): the
/// docker-compose projects detected in the repos opencode lists, each a group
/// of its creatable services. The state of each service and project, and the
/// up/stop actions, are the bridge's `docker compose` endpoints. Refreshes via
/// [reload] after its own actions and on pull; [reload] also re-fetches the
/// container list, since the section and the list show the same containers.
class _ComposeSection extends StatefulWidget {
  const _ComposeSection({
    required this.client,
    required this.projects,
    required this.loading,
    required this.error,
    required this.reload,
  });

  final DockerClient client;

  /// The loaded projects; `null` until the first successful load.
  final List<ComposeProject>? projects;

  /// True while a compose load is in flight.
  final bool loading;

  /// The last compose load failure, if any.
  final String? error;

  /// Re-fetches the container list and the compose projects (the parent's
  /// loader), keeping the two views of the same containers in sync.
  final Future<void> Function() reload;

  @override
  State<_ComposeSection> createState() => _ComposeSectionState();
}

class _ComposeSectionState extends State<_ComposeSection> {
  /// The key of the in-flight action (so its button shows progress); `null`
  /// when no action is in flight. While set, all compose buttons are disabled
  /// (one compose action at a time, so they cannot race on a project).
  String? _busy;

  Future<void> _act(
    ComposeProject project,
    ComposeAction action, {
    String? service,
  }) async {
    if (_busy != null) return;
    final key = _actionKey(project.id, action, service);
    setState(() => _busy = key);
    try {
      await widget.client.composeAction(project.id, action, service: service);
      if (!mounted) return;
      await widget.reload();
    } on DockerClientError catch (e) {
      if (!mounted) return;
      _snackBar(
        'Could not ${action.wire}${service == null ? '' : ' $service'} '
        '(status ${e.statusCode == 0 ? 'unreachable' : '${e.statusCode}'})',
      );
    } catch (_) {
      if (!mounted) return;
      _snackBar(
        'Could not ${action.wire}${service == null ? '' : ' $service'}.',
      );
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  void _snackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final projects = widget.projects;
    if (widget.loading && projects == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: Text('Loading compose projects…')),
      );
    }
    if (projects == null) {
      final error = widget.error;
      return error == null
          ? const SizedBox.shrink()
          : Padding(padding: const EdgeInsets.all(16), child: Text(error));
    }
    if (projects.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: Text('No compose projects detected.')),
      );
    }
    return Column(
      children: [
        for (final project in projects)
          _ComposeProjectCard(
            project: project,
            busy: _busy,
            onAction: (action, {service}) =>
                _act(project, action, service: service),
          ),
      ],
    );
  }
}

/// The single-segment key of one compose action, for the busy-button lookup.
String _actionKey(String projectId, ComposeAction action, String? service) =>
    service == null
    ? 'proj|$projectId|${action.wire}'
    : 'svc|$projectId|$service|${action.wire}';

/// One compose project: its directory, a per-project start-all / stop-all,
/// and one row per creatable service.
class _ComposeProjectCard extends StatelessWidget {
  const _ComposeProjectCard({
    required this.project,
    required this.busy,
    required this.onAction,
  });

  final ComposeProject project;
  final String? busy;
  final _ComposeOnAction onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = project.services.where((s) => s.isRunning).length;
    final total = project.services.length;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        project.project,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        project.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: scheme.outline),
                      ),
                    ],
                  ),
                ),
                Text(
                  '$running/$total up',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
                const SizedBox(width: 8),
                _ComposeButton(
                  actionKey: _actionKey(project.id, ComposeAction.up, null),
                  busy: busy,
                  label: 'Start all',
                  enabled: project.anyNotRunning,
                  onPressed: () => onAction(ComposeAction.up),
                ),
                _ComposeButton(
                  actionKey: _actionKey(project.id, ComposeAction.stop, null),
                  busy: busy,
                  label: 'Stop all',
                  enabled: project.anyRunning,
                  onPressed: () => onAction(ComposeAction.stop),
                ),
              ],
            ),
            const SizedBox(height: 4),
            for (final service in project.services)
              _ComposeServiceRow(
                project: project,
                service: service,
                busy: busy,
                onAction: onAction,
              ),
          ],
        ),
      ),
    );
  }
}

/// One creatable service of a compose project: the state dot, the name, the
/// image (when known), and its own start / stop.
class _ComposeServiceRow extends StatelessWidget {
  const _ComposeServiceRow({
    required this.project,
    required this.service,
    required this.busy,
    required this.onAction,
  });

  final ComposeProject project;
  final ComposeService service;
  final String? busy;
  final _ComposeOnAction onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 2, bottom: 2),
      child: Row(
        children: [
          _StateDot(state: service.state ?? DockerState.created),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  service.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (service.image != null)
                  Text(
                    service.image!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
              ],
            ),
          ),
          _ComposeButton(
            actionKey: _actionKey(project.id, ComposeAction.up, service.name),
            busy: busy,
            label: 'Start',
            enabled: !service.isRunning,
            onPressed: () => onAction(ComposeAction.up, service: service.name),
          ),
          _ComposeButton(
            actionKey: _actionKey(project.id, ComposeAction.stop, service.name),
            busy: busy,
            label: 'Stop',
            enabled: service.isRunning,
            onPressed: () =>
                onAction(ComposeAction.stop, service: service.name),
          ),
        ],
      ),
    );
  }
}

/// One compose start/stop button. Disabled while its action is inadmissible
/// or while any compose action is in flight; shows progress while it is the
/// in-flight action.
class _ComposeButton extends StatelessWidget {
  const _ComposeButton({
    required this.actionKey,
    required this.busy,
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  final String actionKey;
  final String? busy;
  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final inFlight = actionKey == busy;
    final active = enabled && busy == null;
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: OutlinedButton(
        key: ValueKey('compose-btn-$actionKey'),
        onPressed: active ? onPressed : null,
        child: inFlight
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }
}
