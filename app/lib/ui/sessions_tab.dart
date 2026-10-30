import 'package:flutter/material.dart';

import '../bridge/terminal/terminal_backend.dart';
import '../client/events_client.dart';
import '../client/sessions_client.dart';
import '../model/project.dart';
import '../model/session.dart';
import 'structured_view.dart';
import 'terminal_view.dart';

/// The Sessions tab: the home list (spec section 5 endpoint 1, section 6).
///
/// Shows every session of the shared opencode service, grouped by project
/// (collapsible), newest first, with the active indicator and a per-session
/// delete action. App-launched sessions whose window is closed collect in
/// the Closed section at the bottom; tapping one reopens its window. Tapping
/// an *external* row opens the structured view (spec §6); tapping an
/// app-launched live row follows its terminal (server mode). The New session
/// button starts a session in a project (spec §5, fill-in †): the bridge
/// creates the session, its PTY, and its terminal window, and in server mode
/// the app follows the terminal.
class SessionsTab extends StatefulWidget {
  const SessionsTab({
    super.key,
    required this.apiBase,
    this.client,
    this.terminals,
    this.events,
  });

  /// Where the bridge's sessions API lives. `null` when this client has no
  /// bridge to point at (client mode without a tunnel URL yet).
  final Uri? apiBase;

  /// The client for the bridge's sessions API. Defaults to a real
  /// [SessionsClient] at [apiBase]; tests inject a fake.
  final SessionsClient? client;

  /// Present in server mode with a shared opencode service: the terminal
  /// backend the tab attaches to in-process (spec §12). `null` in client
  /// mode, where the app cannot follow the terminal.
  final TerminalBackend? terminals;

  /// The source of the bridge's unified event stream (spec §8) the tab's
  /// views listen to. Defaults to a real [EventsClient] at [apiBase] (owned
  /// and disconnected by the tab); tests inject a scripted source.
  final EventSource? events;

  @override
  State<SessionsTab> createState() => SessionsTabState();
}

class SessionsTabState extends State<SessionsTab> {
  SessionsClient? _client;

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

  /// The id whose window reopen is in flight (its row shows progress).
  String? _reopeningId;

  /// True while a session create (the new-session flow, after the project
  /// is picked) is in flight.
  bool _newSessionBusy = false;

  @override
  void initState() {
    super.initState();
    final base = widget.apiBase;
    if (base != null) {
      _client = widget.client ?? SessionsClient(base);
      _setupEvents(base);
      _load();
    } else {
      _loading = false;
    }
  }

  @override
  void didUpdateWidget(covariant SessionsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.apiBase != oldWidget.apiBase && widget.apiBase != null) {
      _client = widget.client ?? SessionsClient(widget.apiBase!);
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
      setState(() {
        _rows = rows;
        _loading = false;
      });
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

  /// The new-session flow (spec §5, fill-in †): pick a project, then create
  /// the session in it. The bridge creates the session + PTY + window and
  /// returns the session; afterwards the app follows the terminal (server
  /// mode) or just reports the launch (client mode).
  Future<void> _newSession() async {
    final client = _client;
    if (client == null || _newSessionBusy) return;
    final project = await _pickProject(client);
    if (project == null) return;
    setState(() => _newSessionBusy = true);
    try {
      final session = await client.create(project.id);
      if (!mounted) return;
      await _load();
      final terminals = widget.terminals;
      if (terminals == null) {
        // Client mode: the window opened on the host machine; this client
        // cannot follow the terminal.
        _snackBar('Session created; its terminal window opened on the host.');
        return;
      }
      await _openTerminal(session, terminals);
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

  /// Shows the project picker (spec fill-in †); returns the picked project
  /// or `null` when the user dismissed it.
  Future<Project?> _pickProject(SessionsClient client) async {
    List<Project> projects;
    try {
      projects = await client.projects();
    } on SessionsClientError catch (e) {
      if (!mounted) return null;
      _snackBar(
        'Could not load the projects '
        '(status ${e.statusCode == 0 ? 'unreachable' : '${e.statusCode}'}).',
      );
      return null;
    } catch (_) {
      if (!mounted) return null;
      _snackBar('Could not load the projects.');
      return null;
    }
    if (!mounted) return null;
    return showDialog<Project>(
      context: context,
      builder: (context) => _ProjectPicker(projects: projects),
    );
  }

  /// Follows [session]'s terminal in the interactive view (spec §12). The
  /// attach is in-process: the app and the window's attach client are
  /// attached simultaneously. When the view closes, the list re-loads so
  /// the section the session belongs to is up to date.
  Future<void> _openTerminal(Session session, TerminalBackend terminals) async {
    final client = _client;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => TerminalScreen(
          title: session.title.isNotEmpty ? session.title : session.location,
          attach: () => terminals.proxyFor(session.id).attach(),
          sessionId: session.id,
          client: client,
          events: _events?.events,
        ),
      ),
    );
    if (mounted) await _load();
  }

  /// Opens [session] in the structured view (spec §6: *External* →
  /// structured view). The structured view is fully usable without a TUI:
  /// the session stays sendable after its terminal window closes. When the
  /// view closes, the list re-loads.
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
        ),
      ),
    );
    if (mounted) await _load();
  }

  /// Reopens [session]'s window (spec §5 endpoint 3) and, in server mode,
  /// follows the terminal as in the new-session flow.
  Future<void> _reopen(Session session) async {
    final client = _client;
    if (client == null || _reopeningId != null) return;
    final terminals = widget.terminals;
    setState(() => _reopeningId = session.id);
    try {
      await client.openWindow(session.id);
      if (!mounted) return;
      if (terminals == null) {
        _snackBar('Window reopened on the host.');
        await _load();
        return;
      }
      await _openTerminal(session, terminals);
    } on SessionsClientError catch (e) {
      if (!mounted) return;
      _snackBar(
        'Could not reopen the window '
        '(status ${e.statusCode == 0 ? 'unreachable' : '${e.statusCode}'}).',
      );
    } catch (_) {
      if (!mounted) return;
      _snackBar('Could not reopen the window.');
    } finally {
      if (mounted) setState(() => _reopeningId = null);
    }
  }

  Future<void> _confirmDelete(Session session) async {
    final context = this.context;
    final live =
        session.classification == SessionClassification.appLaunchedLive;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this session?'),
        content: Text(
          live
              ? '"${session.title}" is live: its terminal window will be '
                    'closed and the session deleted from the opencode service. '
                    'This cannot be undone.'
              : '"${session.title}" will be deleted from the opencode service. '
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

  /// The live / external rows grouped by project (newest first): everything
  /// that is not in the Closed section.
  List<_ProjectGroup> get _liveGroups => _groupByProject([
    if (_rows != null)
      for (final row in _rows!)
        if (row.classification != SessionClassification.appLaunchedClosed) row,
  ]);

  /// The Closed section's rows, newest first.
  List<Session> get _closedRows {
    final rows = _rows;
    if (rows == null) return const [];
    return [
      for (final row in rows)
        if (row.classification == SessionClassification.appLaunchedClosed) row,
    ];
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
      final error = _error ?? 'Could not load the session list.';
      return _ErrorState(message: error, onRetry: _load);
    }
    final rows = _rows!;
    final closed = _closedRows;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 8),
        children: [
          _NewSessionButton(busy: _newSessionBusy, onPressed: _newSession),
          if (rows.isEmpty) const _CenteredMessage(text: 'No sessions yet.'),
          for (final group in _liveGroups)
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
                for (final s in group.sessions)
                  _SessionRow(
                    session: s,
                    deleting: _deletingId == s.id,
                    onTap: _rowTap(s),
                    onDelete: _confirmDelete,
                  ),
              ],
            ),
          if (closed.isNotEmpty) ...[
            const Padding(
              key: ValueKey('closed-section'),
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Closed',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey,
                ),
              ),
            ),
            for (final s in closed)
              _SessionRow(
                session: s,
                deleting: _deletingId == s.id,
                reopening: _reopeningId == s.id,
                closed: true,
                onTap: () => _reopen(s),
                onDelete: _confirmDelete,
              ),
          ],
        ],
      ),
    );
  }

  /// The tap target of a live / external row:
  ///   * *external* → the structured view (spec §6), always (the session
  ///     stays fully usable without a TUI);
  ///   * *app-launched live* → following the terminal in server mode;
  ///   * otherwise → `null` (nothing to open from a live row).
  VoidCallback? _rowTap(Session session) {
    final client = _client;
    if (client == null) return null;
    return switch (session.classification) {
      SessionClassification.external => () => _openStructured(session),
      SessionClassification.appLaunchedLive =>
        widget.terminals == null
            ? null
            : () => _openTerminal(session, widget.terminals!),
      SessionClassification.appLaunchedClosed => null,
    };
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

/// The New session action (spec §5, fill-in †): opens the project picker.
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
      label: busy ? const Text('Creating…') : const Text('New session'),
    ),
  );
}

/// The new-session project picker (spec §5, fill-in †): the shared opencode
/// service's projects, the only parameter of a new session.
class _ProjectPicker extends StatelessWidget {
  const _ProjectPicker({required this.projects});

  final List<Project> projects;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('project-picker'),
      title: const Text('New session'),
      content: projects.isEmpty
          ? const _CenteredMessage(text: 'No projects found.')
          : SizedBox(
              width: 400,
              height: 320,
              child: ListView.builder(
                itemCount: projects.length,
                itemBuilder: (context, index) {
                  final project = projects[index];
                  return ListTile(
                    key: ValueKey('project-${project.id}'),
                    title: Text(project.name),
                    subtitle: Text(project.canonical),
                    onTap: () => Navigator.of(context).pop(project),
                  );
                },
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
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
    this.reopening = false,
    this.closed = false,
  });

  final Session session;

  /// True for rows of the Closed section (window reopen is in flight).
  final bool reopening;

  /// True for rows of the Closed section.
  final bool closed;

  /// Follow the terminal (live rows) or reopen the window (Closed rows);
  /// `null` when the row has nothing to open.
  final VoidCallback? onTap;

  final bool deleting;
  final ValueChanged<Session> onDelete;

  @override
  Widget build(BuildContext context) {
    final classificationCaption = switch (session.classification) {
      SessionClassification.appLaunchedLive => 'App-launched · window open',
      SessionClassification.appLaunchedClosed => 'App-launched · window closed',
      SessionClassification.external => null,
    };
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
                    if (classificationCaption != null)
                      Text(
                        classificationCaption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (closed && !reopening && !deleting)
                IconButton(
                  key: ValueKey('reopen-${session.id}'),
                  icon: const Icon(Icons.replay),
                  tooltip: 'Reopen window',
                  onPressed: onTap,
                ),
              deleting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : reopening
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
