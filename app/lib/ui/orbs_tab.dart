import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../access/access_session.dart';
import '../bridge/events/bridge_event.dart';
import '../client/authenticated_http.dart';
import '../client/events_client.dart';
import '../client/orbs_client.dart';
import '../client/sessions_client.dart';
import '../model/orb.dart';
import '../model/project.dart';
import '../model/session.dart';
import 'structured_view.dart';

/// The Orbs tab (spec section 9, issue #96): a grid of **workspace cards** —
/// the card is the view of the orb, there is no detail screen. Each card
/// carries the state dot + word (the current boot stage while preparing),
/// `project · branch`, the session count, the PR badge when the PR is open,
/// and the lifecycle actions on the card itself.
///
/// The actions are gated by state (spec §9.5): Stop while running (a
/// confirm, then the bridge's single unguarded death path), Wake while
/// stopped (lossless — no confirm; the button blocks for the boot), New
/// session on a running orb (issue #97), the per-orb image update on a
/// running or stopped orb (issue #98, spec §2.8 — lossless and never forced,
/// no confirm; the button blocks for the re-boot of a running orb), and the
/// force delete on a running, stopped, or broken orb (issue #98, spec §2.7 —
/// its confirm explains what force discards; the bridge's guard refusal is
/// overridden by the explicit force). On a `broken:state` card: the Fresh
/// state start (issue #102, spec §9.4 — a wake over a recreated state dir,
/// with the stated confirmation: the workspace is kept, the in-orb sessions
/// are lost).
///
/// The FAB opens the create-orb wizard as a bottom sheet (spec §9.3): the
/// project + the orb name first, then the live staged boot log in the sheet
/// — the sheet stays open while the orb boots, the card appears in the grid
/// behind it. The create's POST is tracked at the tab level, so closing the
/// sheet mid-boot lets the creation run to completion.
///
/// The list is a cold path: it is fetched on first open, on foreground
/// return, on pull-to-refresh, on boot-stage changes, and when a create
/// finishes — never on a poll (spec §2.2; the PR enrichment costs a `gh`
/// call per row, so it is the Orbs tab's own `list(includePr: true)`).
class OrbsTab extends StatefulWidget {
  const OrbsTab({
    super.key,
    required this.apiBase,
    this.client,
    this.sessions,
    this.events,
    this.auth,
    this.access,
    this.highlight,
    this.onHighlightConsumed,
  });

  /// Where the bridge's orb API lives. `null` when this client has no bridge
  /// to point at (client mode without a tunnel URL yet).
  final Uri? apiBase;

  /// The client for the bridge's orb API. Defaults to a real [OrbsClient] at
  /// [apiBase]; tests inject a fake.
  final OrbsClient? client;

  /// The client for the bridge's sessions API (the per-card session count).
  /// Defaults to a real [SessionsClient] at [apiBase]; tests inject a fake.
  final SessionsClient? sessions;

  /// The source of the bridge's unified event stream (spec §8) the tab
  /// listens to (the `orb.boot` stage lines). Defaults to a real
  /// [EventsClient] at [apiBase] (owned and disconnected by the tab); tests
  /// inject a scripted source.
  final EventSource? events;

  /// The Access login's header provider (issue #23, client mode); `null` in
  /// server mode.
  final AuthHeaderProvider? auth;

  /// The tunnel's Access login (issue #23, client mode); `null` in server
  /// mode or without a tunnel URL. The tab re-fetches when the login
  /// completes (issue #41).
  final AccessSession? access;

  /// The one-shot highlight (the session → orb navigation, spec §9.2): the
  /// orb id whose card to highlight, arriving when the user taps an orb chip
  /// in the Sessions tab. Consumed through [onHighlightConsumed] (which the
  /// caller uses to clear the target, so a later identical tap is a new
  /// event); tapping the highlighted card clears it again.
  final String? highlight;
  final VoidCallback? onHighlightConsumed;

  @override
  State<OrbsTab> createState() => OrbsTabState();
}

class OrbsTabState extends State<OrbsTab> with WidgetsBindingObserver {
  OrbsClient? _client;

  /// The sessions API (the per-card session count), `null` when there is no
  /// bridge to count against.
  SessionsClient? _sessions;

  /// The event stream source (spec §8), `null` when there is no bridge to
  /// listen on.
  EventSource? _events;

  /// True when [_events] is this tab's own [EventsClient] (to disconnect in
  /// [dispose]); a provided [EventSource] is owned by the caller.
  bool _ownsEvents = false;

  /// The fetched cards, `null` until the first successful load.
  List<OrbRecord>? _orbs;

  /// The session counts per orb id (from the shared list, cold path).
  Map<String, int> _sessionCounts = const {};

  /// The last load failure, if any.
  String? _error;

  /// True while a load is in flight.
  bool _loading = true;

  /// True while a load is actually running (a stage-change event may arrive
  /// mid-load; a second concurrent cold fetch is wasted work).
  bool _loadInFlight = false;

  /// True while the image rebuild is in flight.
  bool _rebuildBusy = false;

  /// The orb ids whose Stop is in flight (issue #97): the card's button
  /// carries its busy label ("Stopping…") over the whole export/import/stop.
  final Set<String> _stoppingIds = <String>{};

  /// The orb ids whose Wake is in flight (issue #97): the bridge blocks for
  /// the whole boot, so the button carries "Waking…" meanwhile.
  final Set<String> _wakingIds = <String>{};

  /// The orb ids whose New session create is in flight (issue #97).
  final Set<String> _creatingSessionIds = <String>{};

  /// The orb ids whose per-orb update is in flight (issue #98): the bridge
  /// blocks for the whole re-boot of a running orb.
  final Set<String> _updatingIds = <String>{};

  /// The orb ids whose force delete is in flight (issue #98).
  final Set<String> _deletingIds = <String>{};

  /// The orb ids whose fresh-state start is in flight (issue #102): the
  /// button blocks for the boot like the Wake.
  final Set<String> _freshStatingIds = <String>{};

  /// The create in flight, if any (the wizard's sheet renders it; the tab
  /// owns it, so closing the sheet mid-boot keeps the creation alive).
  _OrbCreation? _creation;

  /// The orb ids the list knew when the create POST went out: an
  /// `orb.boot` event for an id outside this set is the orb being created
  /// (its id is minted by the bridge, unknowable up front).
  Set<String> _knownAtPost = const {};

  /// The orb card to highlight (spec §9.2), adopted from [OrbsTab.highlight].
  String? _highlight;

  StreamSubscription<BridgeEvent>? _eventsSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _highlight = widget.highlight;
    final base = widget.apiBase;
    if (base != null) {
      _client = widget.client ?? OrbsClient(base, auth: widget.auth);
      _sessions = widget.sessions ?? SessionsClient(base, auth: widget.auth);
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
    // On returning to the foreground (Android suspends the app, issue #41),
    // re-fetch: a boot may have finished, a PR may have opened.
    _reloadWithToken();
  }

  void _onAccessState(AccessLoginState state) {
    if (state != AccessLoginState.loggedIn) return;
    // The login finished (issue #41): now the token is in hand.
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
  void didUpdateWidget(covariant OrbsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.access != oldWidget.access) {
      oldWidget.access?.removeListener(_onAccessState);
      widget.access?.addListener(_onAccessState);
    }
    if (widget.apiBase != oldWidget.apiBase && widget.apiBase != null) {
      _client = widget.client ?? OrbsClient(widget.apiBase!, auth: widget.auth);
      _sessions =
          widget.sessions ?? SessionsClient(widget.apiBase!, auth: widget.auth);
      _setupEvents(widget.apiBase!);
      _load();
    }
    final highlight = widget.highlight;
    if (highlight != null && highlight != oldWidget.highlight) {
      // The target arrives as a widget update, which runs during the build
      // phase: report the consumption after the frame so the shell's
      // setState never happens mid-build.
      _highlight = highlight;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onHighlightConsumed?.call();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.access?.removeListener(_onAccessState);
    _eventsSub?.cancel();
    _teardownEvents();
    _creation?.dispose();
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
    _eventsSub = _events!.events.listen(_onBridgeEvent);
  }

  /// Stops the event source, disconnecting it only when the tab owns it.
  void _teardownEvents() {
    final source = _events;
    if (source == null) return;
    _events = null;
    _eventsSub?.cancel();
    _eventsSub = null;
    if (_ownsEvents) {
      _ownsEvents = false;
      source.disconnect();
    }
  }

  /// The cold fetch of the cards (spec §2.2): the orb list with the PR
  /// enrichment, plus the per-orb session count from the shared list. The
  /// count is decorative — a sessions failure must not blank the cards.
  Future<void> _load() async {
    final client = _client;
    if (client == null || _loadInFlight) return;
    _loadInFlight = true;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final orbs = await client.list(includePr: true);
      Map<String, int> counts = const {};
      final sessions = _sessions;
      if (sessions != null) {
        try {
          final rows = await sessions.list();
          final byOrb = <String, int>{};
          for (final row in rows) {
            final orb = row.orb;
            if (orb != null) byOrb[orb] = (byOrb[orb] ?? 0) + 1;
          }
          counts = byOrb;
        } catch (_) {
          // The count is decoration; the cards stand without it.
        }
      }
      if (!mounted) return;
      setState(() {
        _orbs = orbs;
        _sessionCounts = counts;
        _loading = false;
      });
    } on OrbsClientError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.statusCode == 0
            ? 'Cannot reach the bridge.'
            : 'The bridge could not list orbs (status ${e.statusCode}).';
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the orb list.';
        _loading = false;
      });
    } finally {
      _loadInFlight = false;
    }
  }

  /// An `orb.boot` event (data: `{id, line}`) off the stream: the staged
  /// boot log of the orb being created feeds the wizard's sheet, and a
  /// `[orb] stage: <word>` line means the card's state word changed — the
  /// cold list is re-fetched (a handful of fetches per boot, never a poll).
  void _onBridgeEvent(BridgeEvent event) {
    if (event.type != BridgeEventType.orbBoot) return;
    final id = event.data['id'];
    final line = event.data['line'];
    if (id is! String || id.isEmpty) return;
    final creating = _creation;
    if (creating != null && !_knownAtPost.contains(id)) {
      if (line is String) creating.appendLog(line);
    }
    if (line is String && line.contains(_stagePrefix)) {
      unawaited(_load());
    }
  }

  /// The FAB: open the create-orb wizard (spec §9.3) as a bottom sheet. The
  /// creation notifier is created here and owned by the tab; the sheet only
  /// renders it.
  void _openWizard() {
    final creation = _OrbCreation();
    _creation = creation;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _NewOrbSheet(
        creation: creation,
        sessions: _sessions,
        onStart: (projectId, name) => _startCreation(creation, projectId, name),
      ),
    );
  }

  /// The wizard's submit: the create POST is fired and tracked here (not in
  /// the sheet) so closing the sheet mid-boot keeps the creation alive. The
  /// bridge mints the orb id, so the set of known ids is captured now, at
  /// POST time — the first `orb.boot` event for an unknown id is the new orb.
  void _startCreation(_OrbCreation creation, String projectId, String name) {
    final client = _client;
    if (client == null) return;
    final rows = _orbs;
    _knownAtPost = rows == null
        ? const <String>{}
        : <String>{for (final row in rows) row.id};
    unawaited(_create(creation, client, projectId, name));
  }

  Future<void> _create(
    _OrbCreation creation,
    OrbsClient client,
    String projectId,
    String name,
  ) async {
    try {
      final record = await client.create(projectId, name);
      if (!mounted || _creation != creation) return;
      creation.ready(record);
      _creation = null;
      unawaited(_load());
    } on OrbCreateError catch (error) {
      if (!mounted || _creation != creation) return;
      creation.failed(createError: error);
      _creation = null;
      unawaited(_load());
    } catch (error) {
      if (!mounted || _creation != creation) return;
      creation.failed(message: '$error');
      _creation = null;
      unawaited(_load());
    }
  }

  /// The explicit orphan cleanup (spec §2.2 — never auto-deleted): confirm
  /// first, then the bridge removes the orphan's labeled volumes and state
  /// dir.
  Future<void> _confirmCleanOrphan(OrbRecord orb) async {
    final client = _client;
    if (client == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clean up the orphan?'),
        content: Text(
          'This removes the orphaned volumes and state directory of '
          '"${orb.name}". The orb has no container; this cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('orb-clean-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clean up'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await client.deleteOrphan(orb.id);
      if (mounted) _snackBar('Orphan cleaned up.');
      unawaited(_load());
    } catch (_) {
      if (mounted) _snackBar('Could not clean up the orphan.');
    }
  }

  /// Stop (issue #97, spec §2.5): the single trigger for every orb death
  /// path, unguarded and lossless — every session is exported to the host
  /// checkout (same session id) and deleted from the orb only after its
  /// import, the container stops last. The confirm asks about the action,
  /// not about a risk. The bridge blocks until the move and the stop are
  /// done; afterwards the list re-fetches (the card is stopped).
  Future<void> _confirmStop(OrbRecord orb) async {
    final client = _client;
    if (client == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop this orb?'),
        content: Text(
          '"${orb.name}" will be stopped: its sessions are moved to the '
          'host as plain sessions first, and the container is stopped last. '
          'The workspace and branch are untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('orb-stop-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Stop'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _stop(orb, client);
  }

  Future<void> _stop(OrbRecord orb, OrbsClient client) async {
    if (_stoppingIds.contains(orb.id)) return; // re-issue: safe no-op
    setState(() => _stoppingIds.add(orb.id));
    try {
      await client.stop(orb.id);
      if (mounted) _snackBar('Orb stopped.');
      unawaited(_load());
    } on OrbsClientError catch (e) {
      if (mounted) _snackBar('Could not stop the orb: ${e.message}');
    } catch (_) {
      if (mounted) _snackBar('Could not stop the orb.');
    } finally {
      if (mounted) setState(() => _stoppingIds.remove(orb.id));
    }
  }

  /// Wake (issue #97, spec §2.4): re-runs the full start path — the `.env*`
  /// re-injection, the config/auth re-copy, `docker start`, the boot wait —
  /// and removes the stop marker on success. Lossless: no confirm; the
  /// button blocks ("Waking…") for the whole boot.
  Future<void> _wake(OrbRecord orb) async {
    final client = _client;
    if (client == null || _wakingIds.contains(orb.id)) return; // no-op
    setState(() => _wakingIds.add(orb.id));
    try {
      await client.wake(orb.id);
      if (mounted) _snackBar('Orb woken.');
      unawaited(_load());
    } on OrbCreateError catch (e) {
      if (mounted) {
        _snackBar('Could not wake the orb: ${e.details ?? e.code}');
      }
    } on OrbsClientError catch (e) {
      if (mounted) _snackBar('Could not wake the orb: ${e.message}');
    } catch (_) {
      if (mounted) _snackBar('Could not wake the orb.');
    } finally {
      if (mounted) setState(() => _wakingIds.remove(orb.id));
    }
  }

  /// The broken orb's start-with-fresh-state (issue #102, spec §9.4): a
  /// normal wake over a fresh opencode state db. The confirmation states
  /// the trade: the workspace (uncommitted work included) is kept, the
  /// in-orb sessions are lost.
  Future<void> _confirmFreshState(OrbRecord orb) async {
    final client = _client;
    if (client == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start with fresh state?'),
        content: Text(
          '"${orb.name}" starts over with a fresh opencode state. Its '
          'workspace is kept — uncommitted work included — but its in-orb '
          'sessions are lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('orb-fresh-state-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Start'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _freshState(orb, client);
  }

  Future<void> _freshState(OrbRecord orb, OrbsClient client) async {
    if (_freshStatingIds.contains(orb.id)) return; // re-issue: safe no-op
    setState(() => _freshStatingIds.add(orb.id));
    try {
      await client.startWithFreshState(orb.id);
      if (mounted) _snackBar('Orb started with fresh state.');
      unawaited(_load());
    } on OrbsClientError catch (e) {
      if (mounted) {
        _snackBar('Could not start with fresh state: ${e.message}');
      }
    } catch (_) {
      if (mounted) _snackBar('Could not start with fresh state.');
    } finally {
      if (mounted) setState(() => _freshStatingIds.remove(orb.id));
    }
  }

  /// New session on the orb (issue #97, spec §9.1/§9.5): the bridge creates
  /// the session in the orb's workspace (`/workspace`) on the running
  /// service; the new session's structured view opens directly.
  Future<void> _newSession(OrbRecord orb) async {
    final client = _client;
    if (client == null || _creatingSessionIds.contains(orb.id)) return;
    setState(() => _creatingSessionIds.add(orb.id));
    try {
      final session = await client.createSessionOnOrb(orb.id);
      unawaited(_load());
      if (!mounted) return;
      await _openSession(session);
    } on OrbCreateError catch (e) {
      if (mounted) {
        _snackBar('Could not create the session: ${e.details ?? e.code}');
      }
    } on OrbsClientError catch (e) {
      if (mounted) _snackBar('Could not create the session: ${e.message}');
    } catch (_) {
      if (mounted) _snackBar('Could not create the session.');
    } finally {
      if (mounted) {
        setState(() => _creatingSessionIds.remove(orb.id));
      }
    }
  }

  /// The per-orb image update (issue #98, spec §2.8): the bridge recreates
  /// the container on the current image over the same volumes — the
  /// workspace is preserved, the stop marker untouched (a stopped orb is
  /// recreated, not started), a running orb comes back running. Lossless
  /// and never forced: no confirm; the button blocks ("Updating…") for the
  /// whole re-boot of a running orb.
  Future<void> _update(OrbRecord orb) async {
    final client = _client;
    if (client == null || _updatingIds.contains(orb.id)) return; // no-op
    setState(() => _updatingIds.add(orb.id));
    try {
      await client.update(orb.id);
      if (mounted) _snackBar('Orb updated.');
      unawaited(_load());
    } on OrbCreateError catch (e) {
      if (mounted) {
        _snackBar('Could not update the orb: ${e.details ?? e.code}');
      }
    } on OrbsClientError catch (e) {
      if (mounted) _snackBar('Could not update the orb: ${e.message}');
    } catch (_) {
      if (mounted) _snackBar('Could not update the orb.');
    } finally {
      if (mounted) setState(() => _updatingIds.remove(orb.id));
    }
  }

  /// The force delete (issue #98, spec §2.7): the confirm asks about the
  /// discard (the guard's reasons are the bridge's — the dialog names what
  /// force removes), then the bridge's protected deletion with `force: true`
  /// removes the container, the workspace and data volumes, and the state
  /// dir. A refusal anyway (or a wire failure) is a snackbar with its
  /// detail.
  Future<void> _confirmForceDelete(OrbRecord orb) async {
    final client = _client;
    if (client == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Force delete this orb?'),
        content: Text(
          '"${orb.name}" carries work that the guard will not delete on its '
          'own — uncommitted changes, unpushed commits, or a workspace that '
          'cannot be verified. Force delete removes the container, the '
          'workspace and data volumes, and the state directory: everything '
          'in the orb is discarded. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('orb-force-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Force delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _forceDelete(orb, client);
  }

  Future<void> _forceDelete(OrbRecord orb, OrbsClient client) async {
    if (_deletingIds.contains(orb.id)) return;
    setState(() => _deletingIds.add(orb.id));
    try {
      await client.delete(orb.id, force: true);
      if (mounted) _snackBar('Orb deleted.');
      unawaited(_load());
    } on OrbsClientError catch (e) {
      if (mounted) _snackBar('Could not delete the orb: ${e.message}');
    } catch (_) {
      if (mounted) _snackBar('Could not delete the orb.');
    } finally {
      if (mounted) setState(() => _deletingIds.remove(orb.id));
    }
  }

  /// Opens [session] in the structured view (the same view the Sessions tab
  /// opens); when the view closes, the list re-loads.
  Future<void> _openSession(Session session) async {
    final client = _sessions;
    if (client == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => StructuredSessionScreen(
          sessionId: session.id,
          title: session.title.isNotEmpty ? session.title : session.location,
          client: client,
          events: _events?.events,
          gaps: _events?.gaps,
        ),
      ),
    );
    if (mounted) unawaited(_load());
  }

  /// The tap on a card (spec §9.1: the card is the view — no detail screen):
  /// the only effect is clearing the highlight when the card carries it.
  void _cardTap(OrbRecord orb) {
    if (_highlight != orb.id) return;
    setState(() => _highlight = null);
  }

  /// The PR badge: open the PR in an external browser (the app cannot
  /// render GitHub).
  Future<void> _openPr(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) _snackBar('Could not open the pull request.');
    }
  }

  /// The global image rebuild (spec §5.3): the tag lands in a snackbar.
  Future<void> _rebuildImage() async {
    final client = _client;
    if (client == null || _rebuildBusy) return;
    setState(() => _rebuildBusy = true);
    try {
      final tag = await client.rebuildImage();
      if (mounted) {
        _snackBar(
          tag.isEmpty ? 'Image rebuild finished.' : 'Image rebuilt: $tag',
        );
      }
    } catch (_) {
      if (mounted) _snackBar('Could not rebuild the image.');
    } finally {
      if (mounted) setState(() => _rebuildBusy = false);
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
    if (_loading && _orbs == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_orbs == null) {
      final error = _error ?? 'Could not load the orb list.';
      return _ErrorState(message: error, onRetry: _load);
    }
    final orbs = _orbs!;
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        key: const ValueKey('orbs-fab'),
        onPressed: _openWizard,
        tooltip: 'New orb',
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final crossAxisCount =
                (constraints.maxWidth - _gridPadding * 3) ~/ _cardWidth;
            return CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        TextButton.icon(
                          key: const ValueKey('orbs-rebuild'),
                          onPressed: _rebuildBusy ? null : _rebuildImage,
                          icon: _rebuildBusy
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.system_update_alt, size: 18),
                          label: _rebuildBusy
                              ? const Text('Rebuilding…')
                              : const Text('Rebuild image'),
                        ),
                        const Spacer(),
                        Text(
                          'Shared base image',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (orbs.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: _CenteredMessage(text: 'No orbs yet.'),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: _gridPadding,
                    ),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount < 1 ? 1 : crossAxisCount,
                        crossAxisSpacing: _gridPadding,
                        mainAxisSpacing: _gridPadding,
                        mainAxisExtent: _cardHeight,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) => _OrbCard(
                          orb: orbs[index],
                          sessionCount: _sessionCounts[orbs[index].id] ?? 0,
                          highlighted: _highlight == orbs[index].id,
                          stopping: _stoppingIds.contains(orbs[index].id),
                          waking: _wakingIds.contains(orbs[index].id),
                          creatingSession: _creatingSessionIds.contains(
                            orbs[index].id,
                          ),
                          updating: _updatingIds.contains(orbs[index].id),
                          deleting: _deletingIds.contains(orbs[index].id),
                          onTap: () => _cardTap(orbs[index]),
                          onOpenPr: _openPr,
                          onStop: _confirmStop,
                          onWake: _wake,
                          onNewSession: _newSession,
                          onUpdate: _update,
                          onForceDelete: _confirmForceDelete,
                          onCleanOrphan: _confirmCleanOrphan,
                          onFreshState: _confirmFreshState,
                          freshStating: _freshStatingIds.contains(
                            orbs[index].id,
                          ),
                        ),
                        childCount: orbs.length,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The stage prefix of the entrypoint's log lines (spec §9.3): a line
/// carrying it changed the card's state word.
const String _stagePrefix = '[orb] stage: ';

const double _gridPadding = 12;
const double _cardWidth = 280;
const double _cardHeight = 204;

/// The orb's state word on the card (spec §9.4).
String _stateWord(String state) {
  switch (state.split(':').first) {
    case 'running':
      return 'running';
    case 'stopped':
      return 'stopped';
    case 'preparing':
      return 'preparing';
    case 'cleanup_pending':
      return 'cleanup pending';
    case 'broken':
      return 'broken';
    case 'orphan':
      return 'orphaned';
    default:
      return state;
  }
}

/// The state's detail line: the current boot stage while preparing, the
/// missing part when broken, the reason when cleanup is pending.
String? _stateDetail(String state) {
  if (state.startsWith('preparing:')) {
    return 'stage: ${state.substring(state.indexOf(':') + 1)}';
  }
  switch (state) {
    case 'broken:workspace':
      return 'workspace volume missing';
    case 'broken:state':
      return 'state directory missing';
    case 'orphan':
      return 'volumes without a container';
  }
  if (state.startsWith('cleanup_pending:')) {
    return state.substring('cleanup_pending:'.length);
  }
  return null;
}

/// The card's state dot (spec §9.4): amber preparing / cleanup pending,
/// green running, red broken, grey stopped / orphan.
Color _stateColor(String state) {
  switch (state.split(':').first) {
    case 'running':
      return Colors.green;
    case 'preparing':
    case 'cleanup_pending':
      return Colors.orange;
    case 'broken':
      return Colors.red;
    default:
      return Colors.grey;
  }
}

/// One workspace card (spec §9.1): the state dot + word, `project · branch`,
/// the session count, the PR badge when the PR is open, and the lifecycle
/// actions on the card itself. The card is the view of the orb — there is no
/// detail screen.
class _OrbCard extends StatelessWidget {
  const _OrbCard({
    required this.orb,
    required this.sessionCount,
    required this.highlighted,
    required this.onTap,
    required this.onOpenPr,
    required this.onStop,
    required this.onWake,
    required this.onNewSession,
    required this.onUpdate,
    required this.onForceDelete,
    required this.onCleanOrphan,
    required this.onFreshState,
    this.stopping = false,
    this.waking = false,
    this.creatingSession = false,
    this.updating = false,
    this.deleting = false,
    this.freshStating = false,
  });

  final OrbRecord orb;
  final int sessionCount;
  final bool highlighted;

  /// The card's lifecycle action is in flight (issue #97, #98, #102): its
  /// button carries its busy label ("Stopping…", "Waking…", "Creating…",
  /// "Updating…", "Deleting…", "Starting…").
  final bool stopping;
  final bool waking;
  final bool creatingSession;
  final bool updating;
  final bool deleting;
  final bool freshStating;

  final VoidCallback onTap;
  final ValueChanged<String> onOpenPr;
  final ValueChanged<OrbRecord> onStop;
  final ValueChanged<OrbRecord> onWake;
  final ValueChanged<OrbRecord> onNewSession;
  final ValueChanged<OrbRecord> onUpdate;
  final ValueChanged<OrbRecord> onForceDelete;
  final ValueChanged<OrbRecord> onCleanOrphan;
  final ValueChanged<OrbRecord> onFreshState;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final detail = _stateDetail(orb.state);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          key: ValueKey('orb-${orb.id}'),
          margin: const EdgeInsets.all(_gridPadding / 2),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: highlighted
                ? Border.all(color: Colors.amber, width: 2)
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    key: ValueKey('orb-state-${orb.id}'),
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _stateColor(orb.state),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      orb.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (orb.pr?.isOpen == true && orb.pr!.url.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    _PrBadge(orb: orb, onTap: () => onOpenPr(orb.pr!.url)),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${orb.project} · ${orb.branch}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    _stateWord(orb.state),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: _stateColor(orb.state),
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: scheme.outline),
                      ),
                    ),
                  ],
                  const Spacer(),
                  Text(
                    sessionCount == 1 ? '1 session' : '$sessionCount sessions',
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                ],
              ),
              const Spacer(),
              // The actions wrap: on a narrow card (one column) the buttons
              // flow to a second line instead of overflowing.
              Wrap(
                spacing: 4,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: _actions(orb, scheme)
                    .map((action) => _ActionButton(action: action, orb: orb))
                    .toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The card's lifecycle actions (spec §9.5), gated by state: Stop and New
  /// session while running, Wake while stopped (issue #97); the per-orb
  /// Update on a running or stopped orb (issue #98, spec §2.8) and the Force
  /// delete on a running, stopped, or broken orb (issue #98, spec §2.7); the
  /// Fresh state on a `broken:state` orb (issue #102, spec §9.4 — with the
  /// stated confirmation). A cleanup-pending orb (issue #101, spec §2.10.2)
  /// is a stopped orb under the badge: it carries the stopped card's
  /// actions — the human's force-delete is the documented exit for a leaked
  /// variant (§2.10.4). A re-issued action in the same state is a safe no-op
  /// (the handler guards on the busy flag).
  List<_CardAction> _actions(OrbRecord orb, ColorScheme scheme) {
    final update = _CardAction(
      label: updating ? 'Updating…' : 'Update',
      enabled: true,
      onPressed: () => onUpdate(orb),
    );
    final forceDelete = _CardAction(
      label: deleting ? 'Deleting…' : 'Force delete',
      enabled: true,
      onPressed: () => onForceDelete(orb),
    );
    final freshState = _CardAction(
      label: freshStating ? 'Starting…' : 'Fresh state',
      enabled: !freshStating,
      onPressed: () => onFreshState(orb),
    );
    // A cleanup-pending orb (`cleanup_pending:<reason>`) is a stopped orb
    // under the badge (issue #101): the same actions, including the human's
    // force-delete — the documented exit for a leaked variant (§2.10.4).
    if (orb.isStoppedLike) {
      return [
        _CardAction(
          label: waking ? 'Waking…' : 'Wake',
          enabled: true,
          onPressed: () => onWake(orb),
        ),
        update,
        forceDelete,
      ];
    }
    switch (orb.state) {
      case 'running':
        return [
          _CardAction(
            label: stopping ? 'Stopping…' : 'Stop',
            enabled: true,
            onPressed: () => onStop(orb),
          ),
          _CardAction(
            label: creatingSession ? 'Creating…' : 'New session',
            enabled: true,
            onPressed: () => onNewSession(orb),
          ),
          update,
          forceDelete,
        ];
      case 'broken:workspace':
        return [forceDelete];
      case 'broken:state':
        return [forceDelete, freshState];
      case 'orphan':
        return [
          _CardAction(
            label: 'Clean up',
            enabled: true,
            onPressed: () => onCleanOrphan(orb),
          ),
        ];
      default:
        return const []; // preparing
    }
  }
}

/// One card action: the label, whether it is wired, and its handler.
class _CardAction {
  const _CardAction({
    required this.label,
    this.enabled = false,
    this.onPressed,
  });

  final String label;

  final bool enabled;
  final VoidCallback? onPressed;
}

/// The card's action button: a small text button.
class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.action, required this.orb});

  final _CardAction action;
  final OrbRecord orb;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      key: ValueKey('orb-action-${orb.id}-${action.label}'),
      style: TextButton.styleFrom(
        textStyle: const TextStyle(fontSize: 12),
        minimumSize: const Size(0, 28),
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      onPressed: action.enabled ? action.onPressed : null,
      child: Text(action.label),
    );
  }
}

/// The PR badge (spec §9.1): rendered when the PR is open; tapping it opens
/// the PR in an external browser.
class _PrBadge extends StatelessWidget {
  const _PrBadge({required this.orb, required this.onTap});

  final OrbRecord orb;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    key: ValueKey('pr-${orb.id}'),
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.link, size: 12),
          SizedBox(width: 3),
          Text(
            'PR',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    ),
  );
}

/// The phase of the create-orb wizard (spec §9.3): the form, the live boot,
/// the ready card behind the sheet, the failed boot.
enum _CreationPhase { form, boot, ready, failed }

/// The create-orb wizard's state, owned by the tab (not the sheet): the
/// bottom sheet renders it, and the create's POST future is tracked against
/// it, so closing the sheet mid-boot keeps the creation alive.
class _OrbCreation extends ChangeNotifier {
  _CreationPhase phase = _CreationPhase.form;

  /// The picked project (id + display label), `null` before the pick.
  String? projectId;
  String? projectLabel;

  /// The orb name being created.
  String name = '';

  /// The staged boot log (the `orb.boot` lines of the new orb), most recent
  /// last, capped.
  List<String> logLines = const [];

  /// The created record, on the ready phase.
  OrbRecord? record;

  /// The create's failure, on the failed phase.
  OrbCreateError? error;

  /// A failure message when the create failed outside the wire contract.
  String? failure;

  void selectProject(String id, String label) {
    projectId = id;
    projectLabel = label;
    notifyListeners();
  }

  void setName(String value) {
    name = value;
    notifyListeners();
  }

  /// The form was submitted: the POST went out, the boot log is streaming.
  void start() {
    phase = _CreationPhase.boot;
    notifyListeners();
  }

  /// An `orb.boot` line for the orb being created (the tab filters by the
  /// known-id set at POST time); the log is capped to the newest 400 lines.
  void appendLog(String line) {
    final kept = logLines.length >= 400
        ? logLines.skip(logLines.length - 400)
        : logLines;
    logLines = [...kept, line];
    notifyListeners();
  }

  void ready(OrbRecord created) {
    record = created;
    phase = _CreationPhase.ready;
    notifyListeners();
  }

  void failed({OrbCreateError? createError, String? message}) {
    error = createError;
    failure = message;
    phase = _CreationPhase.failed;
    notifyListeners();
  }
}

/// The create-orb wizard's bottom sheet (spec §9.3): the project + the orb
/// name first, then the live staged boot log as the prep stages run — the
/// sheet stays open while the orb boots, the card appears in the grid behind
/// it. Rendering is delegated to a [ListenableBuilder] over the creation
/// notifier, owned by the tab.
class _NewOrbSheet extends StatefulWidget {
  const _NewOrbSheet({
    required this.creation,
    required this.sessions,
    required this.onStart,
  });

  final _OrbCreation creation;
  final SessionsClient? sessions;

  /// Fires the create POST at the tab (which tracks it); the sheet only
  /// renders the result.
  final void Function(String projectId, String name) onStart;

  @override
  State<_NewOrbSheet> createState() => _NewOrbSheetState();
}

class _NewOrbSheetState extends State<_NewOrbSheet> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();

  List<Project>? _projects;
  String? _projectsError;

  @override
  void initState() {
    super.initState();
    unawaited(_loadProjects());
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// The wizard's project picker (the bridge's project list, cold fetch).
  Future<void> _loadProjects() async {
    final sessions = widget.sessions;
    if (sessions == null) {
      setState(() => _projects = const []);
      return;
    }
    try {
      final projects = await sessions.projects();
      if (!mounted) return;
      setState(() => _projects = projects);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _projects = const [];
        _projectsError = 'Could not load the projects.';
      });
    }
  }

  void _submit() {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) return;
    final creation = widget.creation;
    final projectId = creation.projectId;
    final name = _nameController.text.trim();
    if (projectId == null || name.isEmpty) return;
    creation.setName(name);
    creation.start();
    widget.onStart(projectId, name);
  }

  @override
  Widget build(BuildContext context) {
    final creation = widget.creation;
    return ListenableBuilder(
      listenable: creation,
      builder: (context, _) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.7,
            ),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'New orb',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('orb-sheet-close'),
                          icon: const Icon(Icons.close),
                          tooltip: 'Close',
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    switch (creation.phase) {
                      _CreationPhase.form => _form(),
                      _CreationPhase.boot => _boot(creation),
                      _CreationPhase.ready => _ready(creation),
                      _CreationPhase.failed => _failed(creation),
                    },
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// The form phase: the project pick + the orb name, then "Create & boot".
  Widget _form() {
    return Form(
      key: _formKey,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Project',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 8),
          if (_projects == null)
            const Padding(
              padding: EdgeInsets.all(8),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (_projects!.isEmpty)
            Text(
              'No projects available on the bridge.',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.outline,
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final project in _projects!)
                  ChoiceChip(
                    key: ValueKey('orb-project-${project.id}'),
                    label: Text(project.name),
                    selected: widget.creation.projectId == project.id,
                    onSelected: (_) =>
                        widget.creation.selectProject(project.id, project.name),
                  ),
              ],
            ),
          if (_projectsError != null) ...[
            const SizedBox(height: 8),
            Text(
              _projectsError!,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 16),
          TextFormField(
            key: const ValueKey('orb-name'),
            controller: _nameController,
            textCapitalization: TextCapitalization.none,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Orb name'),
            onChanged: widget.creation.setName,
            validator: (value) {
              final name = (value ?? '').trim();
              if (name.isEmpty) return 'Give the orb a name.';
              if (name.length > 40) return 'Keep the name under 40 characters.';
              return null;
            },
          ),
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const ValueKey('create-orb'),
              onPressed: widget.creation.projectId == null || _projects == null
                  ? null
                  : _submit,
              child: const Text('Create & boot'),
            ),
          ),
        ],
      ),
    );
  }

  /// The boot phase: the live staged boot log in the sheet while the POST
  /// blocks for the whole boot — the sheet stays open, the card appears in
  /// the grid behind it.
  Widget _boot(_OrbCreation creation) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: Colors.orange,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Preparing — you can close this sheet, the boot continues.',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _LogConsole(lines: creation.logLines),
      ],
    );
  }

  /// The ready phase: the create's POST answered 201, the card is running
  /// behind the sheet.
  Widget _ready(_OrbCreation creation) {
    final record = creation.record;
    return Column(
      children: [
        const SizedBox(height: 12),
        const Icon(Icons.check_circle, size: 40, color: Colors.green),
        const SizedBox(height: 12),
        Text(
          '${record?.name ?? creation.name} is up',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        if (record != null) ...[
          const SizedBox(height: 4),
          Text(
            '${record.project} · ${record.branch}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ],
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            key: const ValueKey('orb-ready-close'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ),
      ],
    );
  }

  /// The failed phase: the wire refusal (taken name, up-front refusal) or
  /// the failed boot with its log tail.
  Widget _failed(_OrbCreation creation) {
    final error = creation.error;
    final message = error?.details ?? creation.failure;
    final lines = creation.logLines.isEmpty
        ? error?.logTail ?? const <String>[]
        : creation.logLines;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.error, color: Colors.red, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'The orb could not be created.',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        if (message != null) ...[
          const SizedBox(height: 12),
          Text(message, style: const TextStyle(fontSize: 13)),
        ],
        if (lines.isNotEmpty) ...[
          const SizedBox(height: 12),
          _LogConsole(lines: lines),
        ],
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            key: const ValueKey('orb-failed-close'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ),
      ],
    );
  }
}

/// The boot log console: a dark, monospaced, auto-scrolling box of the
/// `orb.boot` lines (most recent last).
class _LogConsole extends StatefulWidget {
  const _LogConsole({required this.lines});

  final List<String> lines;

  @override
  State<_LogConsole> createState() => _LogConsoleState();
}

class _LogConsoleState extends State<_LogConsole> {
  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant _LogConsole oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.lines.length != oldWidget.lines.length) {
      // Stay pinned to the newest line as the log grows.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.lines;
    return Container(
      key: const ValueKey('boot-log'),
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(8),
      ),
      child: lines.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Waiting for the boot to start…',
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
            )
          : ListView.builder(
              controller: _scroll,
              itemExtent: 18,
              itemCount: lines.length,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  lines[index],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    key: const ValueKey('orbs-empty'),
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
            key: const ValueKey('orbs-retry'),
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    ),
  );
}
