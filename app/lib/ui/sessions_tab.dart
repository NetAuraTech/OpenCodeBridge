import 'package:flutter/material.dart';

import '../client/sessions_client.dart';
import '../model/session.dart';

/// The Sessions tab: the home list (spec section 5 endpoint 1, section 6).
///
/// Shows every session of the shared opencode service, grouped by project
/// (collapsible), newest first, with the active indicator and a per-session
/// delete action.
class SessionsTab extends StatefulWidget {
  const SessionsTab({super.key, required this.apiBase, this.client});

  /// Where the bridge's sessions API lives. `null` when this client has no
  /// bridge to point at (client mode without a tunnel URL yet).
  final Uri? apiBase;

  /// The client for the bridge's sessions API. Defaults to a real
  /// [SessionsClient] at [apiBase]; tests inject a fake.
  final SessionsClient? client;

  @override
  State<SessionsTab> createState() => SessionsTabState();
}

class SessionsTabState extends State<SessionsTab> {
  SessionsClient? _client;

  /// The fetched rows, `null` until the first successful load.
  List<Session>? _rows;

  /// The last load failure, if any.
  String? _error;

  /// True while a load is in flight.
  bool _loading = true;

  /// The id whose delete is in flight (its row shows progress).
  String? _deletingId;

  @override
  void initState() {
    super.initState();
    final base = widget.apiBase;
    if (base != null) {
      _client = widget.client ?? SessionsClient(base);
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
      _load();
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
    if (rows.isEmpty) {
      return const _CenteredMessage(text: 'No sessions yet.');
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 8),
        children: [
          for (final group in _groupByProject(rows))
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
                    onDelete: _confirmDelete,
                  ),
              ],
            ),
        ],
      ),
    );
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
  });

  final Session session;
  final bool deleting;
  final ValueChanged<Session> onDelete;

  @override
  Widget build(BuildContext context) {
    final classificationCaption = switch (session.classification) {
      SessionClassification.appLaunchedLive => 'App-launched · window open',
      SessionClassification.appLaunchedClosed => 'App-launched · window closed',
      SessionClassification.external => null,
    };
    return Padding(
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
          deleting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : PopupMenuButton<String>(
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
    );
  }
}
