import 'dart:async';

import 'package:flutter/material.dart';

import '../access/access_session.dart';
import '../client/authenticated_http.dart';
import '../client/events_client.dart';
import '../client/fs_client.dart';
import '../client/sessions_client.dart';
import '../model/session.dart';
import '../settings/app_settings.dart';
import 'new_project_dialog.dart';
import 'structured_view.dart';

/// The Sessions tab: the home list (spec section 5 endpoint 1, section 6).
///
/// Shows every session of the shared opencode service, grouped by project
/// (collapsible), newest first, with the active indicator and a per-session
/// delete action. Tapping any row opens the structured view (spec §6). The
/// global New project button (issue #54) opens a filesystem browser that
/// creates a session at the directory you pick; each project group carries a
/// New session button of its own that creates in that project directly. Both
/// create the session on the shared service and open its structured view.
class SessionsTab extends StatefulWidget {
  const SessionsTab({
    super.key,
    required this.apiBase,
    this.client,
    this.fs,
    this.events,
    this.auth,
    this.access,
    this.deepLinkSession,
    this.onDeepLinkSessionConsumed,
    this.onOpenSettings,
    this.settings,
    this.onThemeModeChanged,
  });

  /// The tunnel's Access login (issue #23, client mode); `null` in server
  /// mode. The tab re-fetches when the login completes: the browser bounce
  /// brings the app to the foreground before the token exchange finishes, so
  /// the foreground re-fetch hits a `401` and the finishing login is what
  /// carries the token (issue #41).
  final AccessSession? access;

  /// Where the bridge's sessions API lives. `null` when this client has no
  /// bridge to point at (client mode without a tunnel URL yet).
  final Uri? apiBase;

  /// The client for the bridge's sessions API. Defaults to a real
  /// [SessionsClient] at [apiBase]; tests inject a fake.
  final SessionsClient? client;

  /// The client for the bridge's filesystem API (issue #54's "New project"
  /// picker). Defaults to a real [FsClient] at [apiBase]; tests inject a fake.
  final FsClient? fs;

  /// The Access login's header provider (issue #23, client mode); `null` in
  /// server mode.
  final AuthHeaderProvider? auth;

  /// The source of the bridge's unified event stream (spec §8) the tab's
  /// views listen to. Defaults to a real [EventsClient] at [apiBase] (owned
  /// and disconnected by the tab); tests inject a scripted source.
  final EventSource? events;

  /// The one-shot deep link (issue #24): the session to open in the
  /// structured view when a tapped notification targets it; `null` when
  /// there is nothing to open. The tab consumes it through
  /// [onDeepLinkSessionConsumed] (which the caller uses to clear the
  /// target, so a later identical link is a new event).
  final String? deepLinkSession;
  final VoidCallback? onDeepLinkSessionConsumed;

  /// Opens the app's Settings tab (the structured view's `/settings`
  /// command, issue #46); the shell provides it. `null` leaves `/settings`
  /// a note that it is unavailable.
  final FutureOr<void> Function()? onOpenSettings;

  /// The app's settings (issue #49): the structured view's `/themes`
  /// command reads and persists the theme choice from here. `null` leaves
  /// `/themes` a note that it is unavailable.
  final AppSettings? settings;

  /// Re-themes the whole app live from the persisted choice (issue #49);
  /// the structured view's `/themes` command calls it after the choice is
  /// persisted.
  final VoidCallback? onThemeModeChanged;

  @override
  State<SessionsTab> createState() => SessionsTabState();
}

class SessionsTabState extends State<SessionsTab> with WidgetsBindingObserver {
  SessionsClient? _client;

  /// The bridge's filesystem API (issue #54's "New project" picker), `null`
  /// when there is no bridge to browse.
  FsClient? _fs;

  /// The event stream source (spec §8) the tab's views listen to, `null`
  /// when there is no bridge to listen on.
  EventSource? _events;

  /// True when [_events] is this tab's own [EventsClient] (to disconnect in
  /// [dispose]); a provided [EventSource] is owned by the caller.
  bool _ownsEvents = false;

  /// The fetched rows, `null` until the first successful load.
  List<Session>? _rows;

  /// The last load failure, if any.
  String? _error;

  /// True while a load is in flight.
  bool _loading = true;

  /// The id whose delete is in flight (its row shows progress).
  String? _deletingId;

  /// True while a session create (the new-session flow) is in flight.
  bool _newSessionBusy = false;

  /// The deep-link session awaiting a loaded list (issue #24): set when the
  /// target arrives before the rows; a failed load leaves it for the next
  /// successful one.
  String? _deepLinkPending;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final base = widget.apiBase;
    if (base != null) {
      _client = widget.client ?? SessionsClient(base, auth: widget.auth);
      _fs = widget.fs ?? FsClient(base, auth: widget.auth);
      _setupEvents(base);
      widget.access?.addListener(_onAccessState);
      _load();
    } else {
      _loading = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed || _client == null) return;
    // Android suspends the app (issue #41): on returning to the foreground,
    // go out again, so rows that changed while backgrounded (a session closed
    // on the host, a turn ended) show up on return.
    _reloadWithToken();
  }

  void _onAccessState(AccessLoginState state) {
    if (state != AccessLoginState.loggedIn) return;
    // The login finished (issue #41): the browser bounce brought the app to
    // the foreground before the token exchange finished, so the foreground
    // re-fetch saw a `401`; now the token is in hand.
    _reloadWithToken();
  }

  /// Re-connects the event stream with the current Access token and re-fetches
  /// the list.
  void _reloadWithToken() {
    final events = _events;
    if (events != null) unawaited(events.reconnect());
    _load();
  }

  @override
  void didUpdateWidget(covariant SessionsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.access != oldWidget.access) {
      oldWidget.access?.removeListener(_onAccessState);
      widget.access?.addListener(_onAccessState);
    }
    if (widget.apiBase != oldWidget.apiBase && widget.apiBase != null) {
      _client =
          widget.client ?? SessionsClient(widget.apiBase!, auth: widget.auth);
      _fs = widget.fs ?? FsClient(widget.apiBase!, auth: widget.auth);
      _setupEvents(widget.apiBase!);
      _load();
    }
    final target = widget.deepLinkSession;
    if (target != null && target != oldWidget.deepLinkSession) {
      // The target arrives as a widget update, which runs during the build
      // phase: open it after the frame so the [Navigator.push] below never
      // happens mid-build (a push mid-build corrupts the navigator's
      // history, leaving the view with no route back to the list).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openDeepLink(target);
      });
    }
  }

  /// A tapped notification targeted a session (issue #24): open it in the
  /// structured view, whose banner shows the pending permission. Consumed
  /// immediately (the caller clears the target); when the list has not
  /// loaded yet, the target waits for it in [_deepLinkPending].
  void _openDeepLink(String id) {
    widget.onDeepLinkSessionConsumed?.call();
    final rows = _rows;
    if (rows == null) {
      _deepLinkPending = id;
      return;
    }
    _openDeepLinkRow(id, rows);
  }

  void _openDeepLinkRow(String id, List<Session> rows) {
    _deepLinkPending = null;
    final row = rows.where((session) => session.id == id).firstOrNull;
    if (row == null) return; // The session is gone (deleted in the meantime).
    unawaited(_openStructured(row));
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
    _events!.connect();
  }

  /// Stops the event source, disconnecting it only when the tab owns it.
  void _teardownEvents() {
    final source = _events;
    if (source == null) return;
    _events = null;
    if (_ownsEvents) {
      _ownsEvents = false;
      source.disconnect();
    }
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
    } on SessionsClientError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.statusCode == 0
            ? 'Cannot reach the bridge.'
            : 'The bridge could not list sessions (status ${e.statusCode}).';
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the session list.';
        _loading = false;
      });
    }
  }

  /// The global new-project flow (issue #54): browse the host's filesystem
  /// one level at a time, then "Create here" — the dialog creates the session
  /// at the directory on screen (it shows the create's busy state itself),
  /// and this opens the new session's structured view.
  Future<void> _newProject() async {
    final client = _client;
    final fs = _fs;
    if (client == null || fs == null || _newSessionBusy) return;
    final session = await showDialog<Session>(
      context: context,
      builder: (context) =>
          NewProjectDialog(fs: fs, onCreate: client.createInDirectory),
    );
    if (session == null || !mounted) return; // The user cancelled.
    setState(() => _newSessionBusy = true);
    try {
      await _load();
      await _openStructured(session);
    } finally {
      if (mounted) setState(() => _newSessionBusy = false);
    }
  }

  /// Creates a session in the project [projectId] and opens its structured
  /// view (spec §5, fill-in †). The bridge creates the session on the shared
  /// service and records the launch; afterwards the app opens the session's
  /// structured view, in server and client mode alike.
  /// Each project group's New session button creates directly in that
  /// project, no browsing.
  Future<void> _createInProject(String projectId) async {
    final client = _client;
    if (client == null || _newSessionBusy) return;
    setState(() => _newSessionBusy = true);
    try {
      final session = await client.create(projectId);
      if (!mounted) return;
      await _load();
      await _openStructured(session);
    } on SessionsClientError catch (e) {
      if (!mounted) return;
      _snackBar(
        'Could not create the session '
        '(status ${e.statusCode == 0 ? 'unreachable' : '${e.statusCode}'}).',
      );
    } catch (_) {
      if (!mounted) return;
      _snackBar('Could not create the session.');
    } finally {
      if (mounted) setState(() => _newSessionBusy = false);
    }
  }

  /// Opens [session] in the structured view (spec §6: *External* →
  /// structured view). The structured view is fully usable on its own: the
  /// session stays sendable after the view closes. When the view closes, the
  /// list re-loads.
  Future<void> _openStructured(Session session) async {
    final client = _client;
    if (client == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => StructuredSessionScreen(
          sessionId: session.id,
          title: session.title.isNotEmpty ? session.title : session.location,
          client: client,
          events: _events?.events,
          gaps: _events?.gaps,
          onNewSession: _newProject,
          onOpenSettings: widget.onOpenSettings,
          settings: widget.settings,
          onThemeModeChanged: widget.onThemeModeChanged,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _confirmDelete(Session session) async {
    final context = this.context;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this session?'),
        content: Text(
          '"${session.title}" will be deleted from the opencode service. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    final client = _client;
    if (client == null) return;
    setState(() => _deletingId = session.id);
    try {
      await client.delete(session.id);
      if (!mounted) return;
      // Re-fetch so the list reflects the merged state after deletion.
      await _load();
    } on SessionsClientError catch (e) {
      if (!mounted) return;
      _snackBar(
        'Could not delete the session '
        '(status ${e.statusCode == 0 ? 'unreachable' : '${e.statusCode}'}).',
      );
    } catch (_) {
      if (!mounted) return;
      _snackBar('Could not delete the session.');
    } finally {
      if (mounted) setState(() => _deletingId = null);
    }
  }

  void _snackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// The rows grouped by project, newest first (the rows arrive pre-sorted,
  /// so grouping preserves the order).
  List<_ProjectGroup> get _groups => _groupByProject(_rows ?? const []);

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
      final error = _error ?? 'Could not load the session list.';
      return _ErrorState(message: error, onRetry: _load);
    }
    final rows = _rows!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 8),
        children: [
          _NewSessionButton(busy: _newSessionBusy, onPressed: _newProject),
          if (rows.isEmpty) const _CenteredMessage(text: 'No sessions yet.'),
          for (final group in _groups)
            ExpansionTile(
              key: ValueKey('project-${group.project.id}'),
              initiallyExpanded: true,
              title: Text(group.project.name),
              subtitle: Text(
                group.sessions.length == 1
                    ? '1 session'
                    : '${group.sessions.length} sessions',
              ),
              children: [
                _GroupNewSessionButton(
                  projectId: group.project.id,
                  busy: _newSessionBusy,
                  onPressed: () => _createInProject(group.project.id),
                ),
                for (final s in group.sessions)
                  _SessionRow(
                    session: s,
                    deleting: _deletingId == s.id,
                    onTap: _rowTap(s),
                    onDelete: _confirmDelete,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// The tap target of a row: the structured view, every row (spec §6); the
  /// session stays fully usable without a TUI.
  VoidCallback? _rowTap(Session session) {
    final client = _client;
    if (client == null) return null;
    return () => _openStructured(session);
  }
}

/// One project group: the project plus its sessions, newest first (the rows
/// arrive pre-sorted, so grouping preserves the order).
class _ProjectGroup {
  const _ProjectGroup(this.project, this.sessions);

  final SessionProject project;
  final List<Session> sessions;
}

List<_ProjectGroup> _groupByProject(List<Session> rows) {
  final byProject = <String, _ProjectGroup>{};
  for (final row in rows) {
    final group = byProject[row.project.id];
    if (group == null) {
      byProject[row.project.id] = _ProjectGroup(row.project, [row]);
    } else {
      byProject[row.project.id] = _ProjectGroup(group.project, [
        ...group.sessions,
        row,
      ]);
    }
  }
  return byProject.values.toList();
}

/// The global New project action (issue #54): opens the filesystem browser
/// and creates a session at the directory you pick.
class _NewSessionButton extends StatelessWidget {
  const _NewSessionButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey('sessions-new'),
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: FilledButton.icon(
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.add),
      label: busy ? const Text('Creating…') : const Text('New project'),
    ),
  );
}

/// A project group's New session action (spec §5, fill-in †): creates a
/// session directly in the group's project, no picker.
class _GroupNewSessionButton extends StatelessWidget {
  const _GroupNewSessionButton({
    required this.projectId,
    required this.busy,
    required this.onPressed,
  });

  final String projectId;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    key: ValueKey('session-new-$projectId'),
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
    child: TextButton.icon(
      onPressed: busy ? null : onPressed,
      icon: busy
          ? const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.add, size: 18),
      label: busy ? const Text('Creating…') : const Text('New session'),
    ),
  );
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
            key: const ValueKey('sessions-retry'),
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    ),
  );
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.deleting,
    required this.onDelete,
    this.onTap,
  });

  final Session session;

  /// Opens the session's structured view; `null` when the row has nothing
  /// to open.
  final VoidCallback? onTap;

  final bool deleting;
  final ValueChanged<Session> onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          key: ValueKey('session-${session.id}'),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (session.active) ...[
                          Container(
                            key: ValueKey('active-${session.id}'),
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Colors.green,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            session.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      session.location,
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
              deleting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : PopupMenuButton<String>(
                      key: ValueKey('menu-${session.id}'),
                      tooltip: 'More actions',
                      onSelected: (action) {
                        if (action == 'delete') onDelete(session);
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete session…'),
                        ),
                      ],
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
