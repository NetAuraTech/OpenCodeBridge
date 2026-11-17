import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../access/access_session.dart';
import '../client/authenticated_http.dart';
import '../client/events_client.dart';
import '../client/fs_client.dart';
import '../client/orbs_client.dart';
import '../client/sessions_client.dart';
import '../model/orb.dart';
import '../model/session.dart';
import '../settings/app_settings.dart';
import 'deep_link_target.dart';
import 'home_list_state.dart';
import 'new_project_dialog.dart';
import 'structured_view.dart';

/// The responsive breakpoint (issue #133): at or above this many logical
/// pixels the sessions sidebar is a persistent, collapsible column (issues
/// #131/#132); below it the sidebar stops occupying layout space — the detail
/// pane fills the width and the sidebar opens as an overlay drawer from the
/// top bar (with a scrim behind it). Driven by the layout width, not device
/// metrics, so it behaves like a responsive website and is testable at any
/// surface size. 600 covers phone-sized screens (Android first, e.g. ~360
/// logical wide in portrait) while still fitting the two panes side by side
/// on a phone held in landscape (~600+).
const double kSessionsSidebarBreakpoint = 600;

/// The width the overlay drawer occupies on narrow screens (issue #133): the
/// same 320 the persistent sidebar column takes on wide screens.
const double kSessionsDrawerWidth = 320;

/// The narrow drawer's slide time (issue #133): the drawer's list is always
/// in the tree (parked off-screen when closed), so the open is a pure
/// position animation — this duration is the whole perceived cost of the
/// open. 200 ms, the repo's micro-motion pace (see the structured view's
/// in-flow animations).
const Duration kDrawerSlideDuration = Duration(milliseconds: 200);

/// The Sessions tab: the home list (spec section 5 endpoint 1, section 6,
/// orbs section 9.2).
///
/// Shows every session of the shared opencode service, grouped by project
/// (collapsible), newest first, with the active indicator and a per-session
/// archive (non-destructive, issue #235) and delete action. Archived rows
/// are hidden from the default **Active** surface and collected under the
/// **Archived** surface (a render filter over the same rows, no bridge
/// change). Tapping any row — archived or not — opens the structured view
/// (spec §6). The global New project button (issue #54) opens a filesystem
/// browser that
/// creates a session at the directory you pick; each project group carries a
/// New session button of its own that creates in that project directly. Both
/// create the session on the shared service and open its structured view.
///
/// The rows stay flat: orb sessions are plain rows wearing a **tappable orb
/// chip** (state dot + orb name) — tapping the chip reports the orb id
/// through [onOrbChipTapped] so the Orbs tab can highlight the card (the
/// session → orb navigation, spec §9.2). Host sessions (no orb) wear a muted
/// "host" label. No per-orb subgroups, no filter banner.
class SessionsTab extends StatefulWidget {
  const SessionsTab({
    super.key,
    required this.apiBase,
    this.client,
    this.fs,
    this.orbs,
    this.events,
    this.auth,
    this.access,
    this.deepLinks,
    this.onOpenSettings,
    this.settings,
    this.onThemeModeChanged,
    this.onOrbChipTapped,
    this.onEventSource,
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

  /// The client for the bridge's orb API (spec §9.2: the rows' orb chips).
  /// Defaults to a real [OrbsClient] at [apiBase]; tests inject a fake. The
  /// list is fetched without the PR enrichment (the badge is the Orbs tab's).
  final OrbsClient? orbs;

  /// The Access login's header provider (issue #23, client mode); `null` in
  /// server mode.
  final AuthHeaderProvider? auth;

  /// The source of the bridge's unified event stream (spec §8) the tab's
  /// views listen to. Defaults to a real [EventsClient] at [apiBase] (owned
  /// and disconnected by the tab); tests inject a scripted source.
  final EventSource? events;

  /// The one-shot deep-link target (issues #24, #287): the model a tapped
  /// notification's link landed on — the session to open in the structured
  /// view when the target is one; `null` when this device has no push
  /// registration (or the target is a container, the Docker tab's). The tab
  /// reads it from the model (not from a widget parameter) and clears it
  /// through [DeepLinkTarget.consume] when it opens it, so a later identical
  /// link is a new event.
  final DeepLinkTarget? deepLinks;

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

  /// The session → orb navigation (spec §9.2): called with the orb id when
  /// the user taps an orb chip on a session row, so the caller (the shell)
  /// can switch to the Orbs tab and highlight that orb's card.
  final ValueChanged<String>? onOrbChipTapped;

  /// Hands the tab's unified-event source to the caller (issue #246) so an
  /// app-level listener (the desktop session sounds) can subscribe to the
  /// *same* stream the tab uses — no second SSE connection. Called with the
  /// [EventSource] when it is set up, and with `null` when it is torn down
  /// (so a source that appears and disappears as the tunnel URL changes is
  /// tracked). `null` leaves the source to the tab alone.
  final void Function(EventSource? source)? onEventSource;

  @override
  State<SessionsTab> createState() => SessionsTabState();
}

class SessionsTabState extends State<SessionsTab> with WidgetsBindingObserver {
  SessionsClient? _client;

  /// The bridge's filesystem API (issue #54's "New project" picker), `null`
  /// when there is no bridge to browse.
  FsClient? _fs;

  /// The bridge's orb API (spec §9.2: the rows' orb chips), `null` when
  /// there is no bridge to look up orb names against.
  OrbsClient? _orbs;

  /// The orb list (without PR enrichment) the chip names and state dots come
  /// from; `null` until it has loaded. A row whose orb is absent (deleted in
  /// the meantime) falls back to the raw orb id.
  List<OrbRecord>? _orbRecords;

  /// The event stream source (spec §8) the tab's views listen to, `null`
  /// when there is no bridge to listen on.
  EventSource? _events;

  /// True when [_events] is this tab's own [EventsClient] (to disconnect in
  /// [dispose]); a provided [EventSource] is owned by the caller.
  bool _ownsEvents = false;

  /// The tab's own subscription to [_events] (spec §8): the session-level
  /// events that change *which rows exist* — a spawned/created session, a
  /// title the agent assigns (`session.renamed`), a deletion — and the turn
  /// boundaries that move the active dot. The composite fan-out carries every
  /// service's events on this one stream (issue #95); the detail pane holds
  /// its own subscription for the turn's content.
  StreamSubscription<BridgeEvent>? _eventsSub;

  /// The home list's merged state (issue #266): the fetched rows, the pin
  /// positions the in-place reorder keys off, the unread marks, and the
  /// selected row — owned by the [HomeListState] module, which this widget
  /// feeds (a fresh read from [_load], a decoded event from
  /// [_onBridgeEvent]) and renders exactly as before the extraction. The
  /// load's lifecycle (in-flight, quiet, the last error) and the deep link
  /// stay here: they are the widget's client transaction and navigation
  /// intent, not row facts. The reload coalescing's *state and decision* now
  /// live in the module too (issue #268: [HomeListState.requestReload] /
  /// [HomeListState.drainReload] / [HomeListState.endReload]); only the load
  /// itself (the `list()` fetch) stays here.
  final HomeListState _list = HomeListState();

  /// The last load failure, if any.
  String? _error;

  /// True while a load is in flight.
  bool _loading = true;

  /// The id whose delete is in flight (its row shows progress).
  String? _deletingId;

  /// True while a session create (the new-session flow) is in flight.
  bool _newSessionBusy = false;

  /// The id whose host→orb move (issue #97) is in flight: its row shows
  /// progress over the whole blocking move (a target-orb boot included).
  String? _movingId;

  /// The id whose workspace export (issue #98, spec §3.4) is in flight: its
  /// row shows progress over the blocking `docker cp` export.
  String? _exportingId;

  /// The id whose row Stop (issue #165) is in flight: its Stop control shows
  /// a busy spinner and ignores further presses. Cleared when the cancel
  /// lands (success or failure) — a failure leaves the dot on, so the control
  /// is offered again to retry.
  String? _stoppingId;

  /// The id whose pin / unpin (issue #238) is in flight: its pin control shows
  /// a busy spinner and ignores further presses. Cleared when the order write
  /// lands (success or failure) — a failure leaves the row's pin state as it
  /// was, so the control is offered again to retry.
  String? _pinningId;

  /// The sidebar's collapsed choice (issue #132): restored from the settings
  /// at the launch, persisted on every toggle. Collapsed, the list pane is
  /// gone entirely and the detail takes the full width; only the toggle stays
  /// visible, at the same screen spot in both states.
  bool _sidebarCollapsed = false;

  /// The overlay drawer's open choice (issue #133): transient, on narrow
  /// screens only. It is an overlay, not a layout choice, so it is never
  /// persisted (unlike [_sidebarCollapsed], which only applies to wide
  /// screens); it resets to closed whenever the narrow layout (re)builds.
  bool _drawerOpen = false;

  /// The id whose archive/unarchive (issue #235) is in flight: its row's
  /// menu is gone for the call. The tap does not re-fetch: the
  /// `session.archived` / `session.unarchived` event the route emits flips
  /// the row's flag in place and moves it between the surfaces.
  String? _archivingId;

  @override
  void initState() {
    super.initState();
    _sidebarCollapsed = widget.settings?.sessionsSidebarCollapsed ?? false;
    WidgetsBinding.instance.addObserver(this);
    final base = widget.apiBase;
    if (base != null) {
      _client = widget.client ?? SessionsClient(base, auth: widget.auth);
      _fs = widget.fs ?? FsClient(base, auth: widget.auth);
      _orbs = widget.orbs ?? OrbsClient(base, auth: widget.auth);
      _setupEvents(base);
      widget.access?.addListener(_onAccessState);
      unawaited(_load());
      // A target already on the model (a cold-start tap, issue #24, or a
      // remounted shell re-reading its stable owner, issue #287): the
      // in-flight load opens it when it lands ([_load]'s success path);
      // when the list is already loaded (a remount) open it now, deferred
      // out of the build phase.
      _openDeepLink();
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
      _orbs = widget.orbs ?? OrbsClient(widget.apiBase!, auth: widget.auth);
      _setupEvents(widget.apiBase!);
      _load();
    }
    // The deep-link target (issue #24) is read from the model (issue
    // #287): it arrives as a model change, which lands here as a widget
    // update during the build phase — open it after the frame so the open
    // never happens mid-build (a push mid-build corrupts the navigator's
    // history, leaving the view with no route back to the list).
    final target = widget.deepLinks?.target;
    if (target != null && target.isSession) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openDeepLink();
      });
    }
  }

  /// Opens the model's deep-link target when it is a session (issue #24):
  /// the detail pane (issue #131), whose banner shows the pending
  /// permission. No-op when there is no session target or the list has not
  /// loaded yet — then the model keeps holding the target (it is a stable
  /// owner, issue #287) and the next successful load opens it ([_load]'s
  /// success path calls back here). The consume lands in
  /// [_openDeepLinkRow], the moment the row is actually opened.
  void _openDeepLink() {
    final target = widget.deepLinks?.target;
    if (target == null) return;
    final rows = _list.rows;
    if (rows == null) return; // The load is in flight: it opens it.
    _openDeepLinkRow(target.id, rows);
  }

  void _openDeepLinkRow(String id, List<Session> rows) {
    widget.deepLinks?.consume();
    final row = rows.where((session) => session.id == id).firstOrNull;
    if (row == null) return; // The session is gone (deleted in the meantime).
    _selectSession(row);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.access?.removeListener(_onAccessState);
    _teardownEvents();
    super.dispose();
  }

  /// Sets up the event source (spec §8): the provided one, or a real
  /// [EventsClient] at [base] owned (and disconnected) by the tab. The tab
  /// also listens to it itself (the list follows the sessions, not just the
  /// open view).
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
    _eventsSub = _events!.events.listen(_onBridgeEvent);
    // The same stream, shared with the app-level listeners (issue #246's
    // desktop sounds): one SSE connection serves every consumer.
    widget.onEventSource?.call(_events);
  }

  /// Stops the event source, disconnecting it only when the tab owns it.
  void _teardownEvents() {
    _eventsSub?.cancel();
    _eventsSub = null;
    final source = _events;
    if (source == null) return;
    _events = null;
    widget.onEventSource?.call(null);
    if (_ownsEvents) {
      _ownsEvents = false;
      unawaited(source.disconnect());
    }
  }

  /// The list's own reaction to the unified event stream (spec §8): the
  /// event's merged state is the module's to compute (the per-event
  /// semantics live in [HomeListState.applyEvent], which also names its
  /// verdict), so this is the verdict's dispatch: reload the list (the
  /// module reloaded nothing — a missed create, an unknown session),
  /// re-derive the waiting fact (the lookups and their failure posture stay
  /// in the widget), or simply rebuild from the merged state (the event
  /// patched a row in place — a title, an active dot, an archived fact, an
  /// order change, an unread mark). The stream carries every service's
  /// events (host and orbs alike, issue #95), and a session id is globally
  /// unique: no service needs naming.
  void _onBridgeEvent(BridgeEvent event) {
    if (!mounted) return;
    if (_list.rows == null) return; // The initial load is still in flight.
    final verdict = _list.applyEvent(event);
    if (verdict == ListStateVerdict.reload) {
      // Coalesced and quiet: the rows stay on screen while the load runs.
      unawaited(_refreshFromEvents());
    } else if (verdict == ListStateVerdict.reDeriveWaiting) {
      final id = HomeListState.sessionOf(event);
      if (id != null) unawaited(_setWaiting(id));
    } else {
      // The event was merged in place: rebuild from the module's state.
      setState(() {});
    }
  }

  /// Re-derives the row [id]'s waiting fact in place (issue #209) from the
  /// service's pending states — the same pending-permission and
  /// pending-question endpoints the structured view consumes — and hands the
  /// result to the module, which patches the row when it disagrees. The
  /// question lookup runs only when the permission lookup answered empty (a
  /// waiting session already has its answer), like the backend's own
  /// derivation (issue #208). A known row whose lookup fails keeps its dot
  /// (the last word) rather than flapping off; the row is removed on its own
  /// delete event, so a stale dot never outlives the session.
  Future<void> _setWaiting(String id) async {
    final client = _client;
    // The row must be known now (a missed create reloads instead, the caller's
    // branch): issuing the lookups for a row the list does not hold is waste.
    if (client == null || !_list.hasRow(id)) return;
    try {
      final permissions = await client.getPermissions(id);
      final waiting =
          permissions.isNotEmpty || (await client.getQuestions(id)).isNotEmpty;
      if (!mounted) return;
      // Re-read the current row: it may have changed while the lookups were in
      // flight (another event patched it, or the row was dropped). Guard
      // against the live value so a burst of events settles on the latest.
      final current = _list.rows?.where((s) => s.id == id).firstOrNull;
      if (current == null || current.waiting == waiting) return;
      _list.patchRow(id, waiting: waiting);
      setState(() {});
    } on SessionsClientError {
      // Keep the last word on screen (the structured view does too).
    }
  }

  /// Reloads the list after a session event, coalescing bursts (issue #268):
  /// the *decision* of the coalescing lives in the module — [requestReload]
  /// answers whether this caller starts the loop or is queued behind an
  /// in-flight one, [drainReload] after each landed load answers whether a
  /// queued wave should run as one more load, and [endReload] clears both when
  /// the loop ends. A burst (a spawn's create, rename and first turn arrive
  /// together) collapses to one load while one is in flight, then one extra
  /// load for the queued wave.
  Future<void> _refreshFromEvents() async {
    if (!_list.requestReload()) return; // Queued behind an in-flight reload.
    try {
      do {
        await _load(quiet: true);
      } while (mounted && _list.drainReload());
    } finally {
      _list.endReload();
    }
  }

  /// Loads the rows. [quiet]: an event-driven refresh keeps the current rows
  /// on screen (the spinner stays the first load's); a failure leaves them too.
  Future<void> _load({bool quiet = false}) async {
    final client = _client;
    if (client == null) return;
    setState(() {
      if (!quiet) _loading = true;
      _error = null;
    });
    try {
      final rows = await client.list();
      if (!mounted) return;
      // The read is authoritative and pre-sorted (pinned-first): the stale
      // in-place positions (the exact pin times we learned from echoes) are
      // no longer needed — a fresh list starts the in-place reorder fresh
      // (issue #238). The module reconciles its selection and unread marks
      // against the rows inside [HomeListState.applyRead].
      _list.applyRead(rows);
      setState(() => _loading = false);
      // A deep-link target set while the list was still loading (issue
      // #24): the model kept it; open it now, from the fresh rows.
      _openDeepLink();
      unawaited(_loadOrbs());
    } on SessionsClientError catch (e) {
      if (!mounted) return;
      if (quiet) return; // Keep the rows on screen: the next event retries.
      setState(() {
        _error = e.statusCode == 0
            ? 'Cannot reach the bridge.'
            : 'The bridge could not list sessions (status ${e.statusCode}).';
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      if (quiet) return;
      setState(() {
        _error = 'Could not load the session list.';
        _loading = false;
      });
    }
  }

  /// The orb list for the rows' chips (spec §9.2): the orb names and state
  /// dots, fetched without the PR enrichment (that is the Orbs tab's badge).
  /// Decorative — a failure leaves the chips on the raw orb id.
  Future<void> _loadOrbs() async {
    final client = _orbs;
    if (client == null) return;
    try {
      final orbs = await client.list();
      if (!mounted) return;
      setState(() => _orbRecords = orbs);
    } catch (_) {
      // The chips degrade to the raw orb id.
    }
  }

  /// The record of the orb a row belongs to, or `null` when the orb is
  /// absent from the list (deleted in the meantime).
  OrbRecord? _orbOf(String? orbId) {
    if (orbId == null) return null;
    final records = _orbRecords;
    if (records == null) return null;
    for (final record in records) {
      if (record.id == orbId) return record;
    }
    return null;
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

  /// Selects [session] in the detail pane (issue #131): swaps the pane in
  /// place, with no navigator push/pop. The list stays visible. On narrow
  /// screens a selection made from the overlay drawer also closes it, so the
  /// detail shows underneath (issue #133).
  void _selectSession(Session session) {
    if (!mounted) return;
    // The module clears the row's unread mark with the selection (issue
    // #207), from every entry point (row tap, narrow drawer, deep link).
    _list.select(session);
    setState(() => _drawerOpen = false);
  }

  void _clearSelection() {
    if (!mounted) return;
    _list.select(null);
    setState(() {});
  }

  /// Opens [session] in the detail pane (issue #131). Kept as the
  /// post-create/open entry point; callers that used to await a route pop no
  /// longer need to — the pane follows the selection.
  Future<void> _openStructured(Session session) async {
    _selectSession(session);
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

  /// The rows of the home list's current surface (issue #235): a render
  /// filter over the module's rows — the **Active** surface is `!archived`
  /// (matching the TUI's own default, the research's Q1), the **Archived**
  /// surface is `archived`. The filter is the module's ([HomeListState.
  /// surfaceRows]); the list keeps fetching every row (the seam is faithful,
  /// issue #234); no bridge behaviour change.
  List<Session> get _surfaceRows => _list.surfaceRows;

  /// The rows of the current surface, grouped by project, newest first (the
  /// rows arrive pre-sorted, so grouping preserves the order).
  List<_ProjectGroup> get _groups => _groupByProject(_surfaceRows);

  /// A project group's subtitle (issue #207): the session count, with the
  /// active count appended ("N sessions (M active)") only while at least one
  /// of the project's sessions is active; otherwise the bare count
  /// ("1 session" / "N sessions").
  String _groupSubtitle(_ProjectGroup group) {
    final count = group.sessions.length;
    final active = group.sessions.where((s) => s.active).length;
    if (active == 0) {
      return count == 1 ? '1 session' : '$count sessions';
    }
    return count == 1
        ? '1 session ($active active)'
        : '$count sessions ($active active)';
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.apiBase;
    if (base == null) {
      return const _CenteredMessage(
        text: 'No bridge configured. Set the tunnel URL in Settings.',
      );
    }
    if (_loading && _list.rows == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_list.rows == null) {
      final error = _error ?? 'Could not load the session list.';
      return _ErrorState(message: error, onRetry: _load);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // Below the breakpoint the sidebar is an overlay drawer (issue #133);
        // at and above it the persistent, collapsible two-pane layout
        // (issues #131/#132) is unchanged.
        if (constraints.maxWidth < kSessionsSidebarBreakpoint) {
          return _buildNarrow(constraints.maxWidth);
        }
        return _buildWide();
      },
    );
  }

  /// The wide (≥ [kSessionsSidebarBreakpoint]) layout: the persistent,
  /// collapsible two-pane layout of issues #131/#132, unchanged by issue
  /// #133. The toggle rail, the list column (when expanded), and the detail
  /// fill the row.
  Widget _buildWide() {
    final list = _buildListPane();
    final detail = _buildDetailPane(showClose: false);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The toggle's own thin column (issue #132): the only thing that
        // survives the collapse, always at the same left edge, so the
        // affordance never moves between the two states.
        _SidebarToggleRail(
          collapsed: _sidebarCollapsed,
          onToggle: _toggleSidebar,
        ),
        if (!_sidebarCollapsed) ...[
          SizedBox(
            key: const ValueKey('sessions-list-pane'),
            width: 320,
            child: list,
          ),
          const VerticalDivider(width: 1, thickness: 1),
        ],
        Expanded(
          child: KeyedSubtree(
            key: const ValueKey('sessions-detail-pane'),
            child: detail,
          ),
        ),
      ],
    );
  }

  /// The narrow (< [kSessionsSidebarBreakpoint]) layout (issue #133): the
  /// detail fills the whole width under a top bar, and the sidebar opens as
  /// an overlay drawer (a scrim behind it) from the top bar's toggle.
  ///
  /// The drawer's list is **always in the tree**: closed, it is parked
  /// off-screen to the left; open, it slides in. A drawer that is inserted
  /// only while open rebuilds the whole list (every group, every row) on the
  /// open frame — a perceptible lag on a real list (200+ rows). Keeping it
  /// built means the open is a position animation only, and the list's rows,
  /// group expansion, and scroll offset are simply preserved across
  /// open/close.
  Widget _buildNarrow(double width) {
    // A Stack that fills the space: the detail column underneath, the parked
    // drawer always in it, and — when open — the scrim positioned over the
    // detail (an overlay, so the drawer never takes layout space from it).
    final drawerWidth = min(kSessionsDrawerWidth, width);
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        // The detail fills the screen: the top bar (its toggle) over the
        // full-width detail pane.
        Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            _NarrowTopBar(drawerOpen: _drawerOpen, onToggle: _toggleDrawer),
            Expanded(
              child: KeyedSubtree(
                key: const ValueKey('sessions-detail-pane'),
                child: _buildDetailPane(showClose: true),
              ),
            ),
          ],
        ),
        if (_drawerOpen)
          // The scrim: a tap anywhere on it closes the drawer without
          // touching the selection (issue #133). It starts below the top bar
          // (like a Material drawer below its AppBar): the top bar stays on
          // top, so the toggle is always reachable (it closes the drawer
          // too), and the drawer never hides the control that dismisses it.
          Positioned(
            top: kToolbarHeight,
            bottom: 0,
            left: 0,
            right: 0,
            child: GestureDetector(
              key: const ValueKey('sessions-drawer-scrim'),
              behavior: HitTestBehavior.opaque,
              onTap: _closeDrawer,
              child: Container(color: Colors.black.withValues(alpha: 0.32)),
            ),
          ),
        // The drawer: the session list over the detail. Always built —
        // off-screen (left: -drawerWidth, clipped by the stack's edge) when
        // closed, slid to the left edge when open. The animation is a
        // position change only: the child subtree is untouched, so opening
        // costs one relayout of the moved node, never a rebuild of the list.
        AnimatedPositioned(
          key: const ValueKey('sessions-drawer'),
          top: kToolbarHeight,
          bottom: 0,
          left: _drawerOpen ? 0 : -drawerWidth,
          width: drawerWidth,
          duration: kDrawerSlideDuration,
          curve: Curves.easeOut,
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            child: _buildListPane(),
          ),
        ),
      ],
    );
  }

  /// Closes the overlay drawer (issue #133). The selection is untouched — a
  /// tap on the scrim (or the toggle) dismisses the overlay without changing
  /// which session the detail shows.
  void _closeDrawer() {
    if (!mounted || !_drawerOpen) return;
    setState(() => _drawerOpen = false);
  }

  /// The top bar's toggle (issue #133): opens the drawer when it is closed
  /// and closes it when it is open. Transient: never persisted, unlike the
  /// wide rail's [_toggleSidebar].
  void _toggleDrawer() {
    if (!mounted) return;
    setState(() => _drawerOpen = !_drawerOpen);
  }

  /// Flips the sidebar's collapsed state and persists the choice (issue
  /// #132), so the next launch restores it. The selection is untouched: the
  /// detail pane carries through the collapse untouched.
  void _toggleSidebar() {
    setState(() => _sidebarCollapsed = !_sidebarCollapsed);
    final settings = widget.settings;
    if (settings != null) settings.sessionsSidebarCollapsed = _sidebarCollapsed;
  }

  Widget _buildListPane() {
    final showingArchived = _list.showingArchived;
    final rows = _surfaceRows;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const ValueKey('sessions-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 8),
        children: [
          if (!showingArchived)
            _NewSessionButton(busy: _newSessionBusy, onPressed: _newProject),
          // The Active / Archived surfaces (issue #235): a render filter over
          // the same rows, so the toggle re-renders only (no fetch).
          _SurfaceFilter(
            showingArchived: showingArchived,
            onToggle: _toggleArchivedSurface,
          ),
          if (rows.isEmpty)
            _CenteredMessage(
              text: showingArchived
                  ? 'No archived sessions yet.'
                  : 'No sessions yet.',
            ),
          for (final group in _groups)
            ExpansionTile(
              key: ValueKey('project-${group.project.id}'),
              initiallyExpanded: true,
              title: Text(group.project.name),
              subtitle: Text(_groupSubtitle(group)),
              children: [
                if (!showingArchived)
                  _GroupNewSessionButton(
                    projectId: group.project.id,
                    busy: _newSessionBusy,
                    onPressed: () => _createInProject(group.project.id),
                  ),
                for (final s in group.sessions)
                  _SessionRow(
                    session: s,
                    deleting: _deletingId == s.id,
                    archiving: _archivingId == s.id,
                    moving: _movingId == s.id,
                    exporting: _exportingId == s.id,
                    dot: _list.dotFor(s),
                    onTap: _rowTap(s),
                    onDelete: _confirmDelete,
                    onArchive: _client == null
                        ? null
                        : () => _archiveSession(s, true),
                    onUnarchive: _client == null
                        ? null
                        : () => _archiveSession(s, false),
                    onMoveToOrb: _moveToOrb,
                    onExportWorkspace: _exportWorkspace,
                    orb: _orbOf(s.orb),
                    onOrbChipTapped: widget.onOrbChipTapped,
                    onStop: _client == null ? null : () => _stopTurn(s),
                    stopping: _stoppingId == s.id,
                    onPin: _client == null ? null : () => _setPin(s),
                    pinning: _pinningId == s.id,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildDetailPane({required bool showClose}) {
    final session = _list.selected;
    final client = _client;
    if (session == null || client == null) {
      return const _CenteredMessage(
        key: ValueKey('sessions-detail-empty'),
        text: 'Select a session to view its details.',
      );
    }
    return StructuredSessionPanel(
      key: const ValueKey('sessions-detail-panel'),
      sessionId: session.id,
      title: session.title.isNotEmpty ? session.title : session.location,
      client: client,
      events: _events?.events,
      gaps: _events?.gaps,
      onNewSession: _newProject,
      onOpenSettings: widget.onOpenSettings,
      onClose: _clearSelection,
      showCloseButton: showClose,
      settings: widget.settings,
      onThemeModeChanged: widget.onThemeModeChanged,
    );
  }

  /// The host → orb move (issue #97, spec §2.6): one action, entirely
  /// through the bridge — the target orb is woken (or created, the full
  /// boot) before the move, and the bridge blocks for the whole move. The
  /// session id is preserved, so a re-run over an already-moved session is
  /// the idempotent success; the row shows progress meanwhile.
  Future<void> _moveToOrb(Session session) async {
    final client = _client;
    if (client == null || _movingId != null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _MoveToOrbDialog(sessionTitle: session.title),
    );
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => _movingId = session.id);
    try {
      await client.moveToOrb(session.id, name);
      if (mounted) _snackBar('Session moved to the orb "$name".');
      unawaited(_load());
    } on SessionsClientError catch (e) {
      if (mounted) _snackBar('Could not move the session: ${e.message}');
    } catch (_) {
      if (mounted) _snackBar('Could not move the session.');
    } finally {
      if (mounted) setState(() => _movingId = null);
    }
  }

  /// The `docker cp` export (issue #98, spec §3.4): the bridge writes a
  /// lossless tar.gz of the orb's whole workspace (untracked files and
  /// `.git` included) next to the project's local clone and answers with
  /// its path — the snackbar names it. An orb session only; the row shows
  /// progress meanwhile.
  Future<void> _exportWorkspace(Session session) async {
    final orbs = _orbs;
    final orbId = session.orb;
    if (orbs == null || orbId == null || _exportingId != null) return;
    setState(() => _exportingId = session.id);
    try {
      final path = await orbs.export(orbId);
      if (mounted) _snackBar('Workspace exported to $path.');
    } on OrbCreateError catch (e) {
      if (mounted) {
        _snackBar('Could not export the workspace: ${e.details ?? e.code}');
      }
    } on OrbsClientError catch (e) {
      if (mounted) _snackBar('Could not export the workspace: ${e.message}');
    } catch (_) {
      if (mounted) _snackBar('Could not export the workspace.');
    } finally {
      if (mounted) setState(() => _exportingId = null);
    }
  }

  /// The row's Stop (issue #165): interrupts the session's running turn
  /// through the bridge's cancel, on the owning service (host or orb — the
  /// route decides). One request per turn (busy while in flight). On success
  /// the dot goes out on the bridge's `session.turn.cancelled` or the
  /// service's terminal event — neither needs the tab to act. On failure the
  /// reason is reported and the row keeps its active dot (the control is
  /// offered again to retry).
  Future<void> _stopTurn(Session session) async {
    final client = _client;
    if (client == null || _stoppingId != null) return;
    setState(() => _stoppingId = session.id);
    try {
      await client.cancel(session.id);
    } on SessionsClientError catch (e) {
      if (mounted) {
        _snackBar(
          'Could not stop the turn '
          '(status ${e.statusCode == 0 ? 'unreachable' : '${e.statusCode}'}).',
        );
      }
    } catch (_) {
      if (mounted) _snackBar('Could not stop the turn.');
    } finally {
      if (mounted) setState(() => _stoppingId = null);
    }
  }

  /// Flips the home list's surface (issue #235) between **Active** (the
  /// default) and **Archived** (the archived rows). A render filter over the
  /// same fetched rows — no bridge call, no re-fetch; the rows that the
  /// filter shows or hides are the same ones, carrying the same flag. The
  /// filter is the module's ([HomeListState.toggleSurface]).
  void _toggleArchivedSurface() {
    if (!mounted) return;
    setState(() => _list.toggleSurface());
  }

  /// The row's Archive / Unarchive (issue #235): the non-destructive exit
  /// beside Delete. Archive hides the session from the Active surface — the
  /// session itself keeps running and stays fully usable per-id (the
  /// research's Q2), and it can be unarchived from the Archived surface.
  /// No destructive confirm (at most a note in the menu); the call does not
  /// re-fetch: the `session.archived` / `session.unarchived` event the route
  /// emits flips the row's flag in place and the surface filter moves it.
  Future<void> _archiveSession(Session session, bool archived) async {
    final client = _client;
    if (client == null || _archivingId != null) return;
    setState(() => _archivingId = session.id);
    try {
      await client.archive(session.id, archived);
    } on SessionsClientError catch (e) {
      if (!mounted) return;
      _snackBar(
        'Could not ${archived ? 'archive' : 'unarchive'} the session '
        '(status ${e.statusCode == 0 ? 'unreachable' : '${e.statusCode}'}).',
      );
    } catch (_) {
      if (!mounted) return;
      _snackBar('Could not ${archived ? 'archive' : 'unarchive'} the session.');
    } finally {
      if (mounted) setState(() => _archivingId = null);
    }
  }

  /// The tap target of a row: the structured view, every row (spec §6); the
  /// session stays fully usable without a TUI. An archived row opens straight
  /// into the view, no unarchive-first dance (the per-id routes work while
  /// archived — the research's Q2).
  VoidCallback? _rowTap(Session session) {
    final client = _client;
    if (client == null) return null;
    return () => _openStructured(session);
  }

  /// The row's pin / unpin (issue #238): one action, entirely through the
  /// bridge's order route — pin writes the pin time (the current epoch
  /// millis; the pin time *is* the stored position, so the pinned block
  /// orders by pin time, newest-pinned last), unpin clears it (`null`). The
  /// row shows progress meanwhile, and on success the row moves into the
  /// pinned block (or back to its created-order place) in place — no refetch.
  /// A failed write (a `404`, a network error) is reported and leaves the
  /// list unchanged, so the control is offered again to retry.
  ///
  /// The position the row sorts by after a local pin is this device's pin
  /// time. The bridge's `session.order.changed` echo (carrying the same
  /// position) re-sorts to the identical place, so the local patch and the
  /// echo agree — no flap, no double move.
  Future<void> _setPin(Session session) async {
    final client = _client;
    if (client == null || _pinningId != null) return;
    final pinning = !session.pinned;
    final position = pinning ? DateTime.now().millisecondsSinceEpoch : null;
    setState(() => _pinningId = session.id);
    try {
      await client.setOrder(session.id, position);
      if (!mounted) return;
      // Success: patch the cached row in place and re-sort (no refetch) —
      // the module's merge point for both pin paths (this write's outcome and
      // the bridge's echo of it).
      final changed = _list.setOrder(session.id, position);
      if (changed) setState(() {});
    } on SessionsClientError catch (e) {
      if (!mounted) return;
      _snackBar(
        'Could not ${pinning ? 'pin' : 'unpin'} the session '
        '(status ${e.statusCode == 0 ? 'unreachable' : '${e.statusCode}'}).',
      );
    } catch (_) {
      if (!mounted) return;
      _snackBar('Could not ${pinning ? 'pin' : 'unpin'} the session.');
    } finally {
      if (mounted) setState(() => _pinningId = null);
    }
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

/// The sidebar's toggle button (issue #132), shared by the wide rail and the
/// narrow top bar (issue #133): the same affordance in both modes — the same
/// key, the same chevron icon, and the same tooltip — so the control reads
/// the same whether it collapses the persistent column (wide) or opens and
/// closes the overlay drawer (narrow).
class _SidebarToggle extends StatelessWidget {
  const _SidebarToggle({required this.collapsed, required this.onToggle});

  /// True when the sidebar is not shown (the icon points outward): the wide
  /// rail's collapsed state, or the narrow drawer's closed state.
  final bool collapsed;

  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('sessions-sidebar-toggle'),
    tooltip: collapsed ? 'Expand sidebar' : 'Collapse sidebar',
    icon: Icon(collapsed ? Icons.chevron_right : Icons.chevron_left),
    onPressed: onToggle,
  );
}

/// The sidebar toggle's rail (issue #132): a thin fixed-width column that is
/// present in both states, so the toggle sits at the same screen spot whether
/// the sidebar is open or closed. When the sidebar is collapsed it is the
/// only thing of the list pane that remains visible — no icons rail, no
/// status dots.
class _SidebarToggleRail extends StatelessWidget {
  const _SidebarToggleRail({required this.collapsed, required this.onToggle});

  /// The rail's width (and the toggle's): the detail pane starts right of it
  /// in both states, so collapsing never moves the toggle.
  static const double width = 48;

  /// True when the sidebar is collapsed (the icon points outward).
  final bool collapsed;

  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Align(
      alignment: Alignment.topCenter,
      child: _SidebarToggle(collapsed: collapsed, onToggle: onToggle),
    ),
  );
}

/// The narrow (phone-sized) top bar (issue #133): the drawer's toggle over
/// the full-width detail, so the session list is one tap away without taking
/// layout space. The toggle reuses the wide rail's affordance
/// ([_SidebarToggle]). When the drawer is open the bar's toggle shows the
/// "collapse" state and closes it, so it always stays reachable (the drawer
/// and its scrim sit below this bar, never over it).
class _NarrowTopBar extends StatelessWidget {
  const _NarrowTopBar({required this.drawerOpen, required this.onToggle});

  /// True while the overlay drawer is open (the toggle shows the "collapse"
  /// state and closes it).
  final bool drawerOpen;

  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    elevation: 4,
    child: SizedBox(
      height: kToolbarHeight,
      child: Row(
        children: [
          _SidebarToggle(collapsed: !drawerOpen, onToggle: onToggle),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Sessions', overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
        ],
      ),
    ),
  );
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

/// The home list's Active / Archived surfaces (issue #235): a two-option
/// toggle over the same fetched rows. **Active** (the default) shows the
/// rows that are not archived; **Archived** shows the ones that are. It is a
/// render filter, so a toggle re-renders the list — no fetch, no bridge
/// call. Transient like the drawer: the choice is not persisted.
class _SurfaceFilter extends StatelessWidget {
  const _SurfaceFilter({required this.showingArchived, required this.onToggle});

  /// True while the Archived surface is shown (the default is Active).
  final bool showingArchived;

  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey('sessions-surface-filter'),
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Row(
      children: [
        _SurfaceChip(
          key: const ValueKey('sessions-surface-active'),
          label: 'Active',
          selected: !showingArchived,
          onTap: showingArchived ? onToggle : null,
        ),
        const SizedBox(width: 8),
        _SurfaceChip(
          key: const ValueKey('sessions-surface-archived'),
          label: 'Archived',
          selected: showingArchived,
          onTap: showingArchived ? null : onToggle,
        ),
      ],
    ),
  );
}

/// One option of the home list's surface filter (issue #235).
class _SurfaceChip extends StatelessWidget {
  const _SurfaceChip({
    super.key,
    required this.label,
    required this.selected,
    this.onTap,
  });

  final String label;

  final bool selected;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? scheme.primary : scheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? scheme.primary : scheme.outline),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? scheme.onPrimary : scheme.onSurface,
          ),
        ),
      ),
    );
  }
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
  const _CenteredMessage({super.key, required this.text});

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

/// The chip's state dot (spec §9.2): green running, amber preparing, red
/// broken, grey otherwise (stopped, orphaned, unknown).
Color _orbDotColor(String state) {
  switch (state.split(':').first) {
    case 'running':
      return Colors.green;
    case 'preparing':
      return Colors.orange;
    case 'broken':
      return Colors.red;
    default:
      return Colors.grey;
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.deleting,
    required this.archiving,
    required this.moving,
    required this.exporting,
    required this.onDelete,
    required this.orb,
    required this.dot,
    this.onTap,
    this.onArchive,
    this.onUnarchive,
    this.onMoveToOrb,
    this.onExportWorkspace,
    this.onOrbChipTapped,
    this.onStop,
    this.stopping = false,
    this.onPin,
    this.pinning = false,
  });

  final Session session;

  /// The row's status dot (issue #209), as the module derives it
  /// ([HomeListState.dotFor]): one spot with mutually exclusive states,
  /// orange (waiting) > green (active) > violet (unread); [RowDot.none]
  /// shows no dot. The precedence is the module's — the widget only maps the
  /// kind to its colour and key.
  final RowDot dot;

  /// The orb the session lives on (spec §9.2): the chip's name and state
  /// dot. `null` when the orb is absent from the list (deleted in the
  /// meantime) — the chip then falls back to the raw orb id. `session.orb`
  /// being `null` means a host session (the muted "host" label).
  final OrbRecord? orb;

  /// Opens the session's structured view; `null` when the row has nothing
  /// to open.
  final VoidCallback? onTap;

  final bool deleting;

  /// True while the row's archive/unarchive (issue #235) is in flight: the
  /// menu is gone for the call (one request at a time, like Delete's). The
  /// row's flag itself flips on the `session.archived` /
  /// `session.unarchived` event the route emits.
  final bool archiving;

  /// True while the row's host→orb move (issue #97) is in flight: the row
  /// shows progress, and the menu is gone for the whole blocking move.
  final bool moving;

  /// True while the row's workspace export (issue #98, spec §3.4) is in
  /// flight: the row shows progress, and the menu is gone for the blocking
  /// export.
  final bool exporting;

  final ValueChanged<Session> onDelete;

  /// The row's Archive (issue #235, the Active surface): the non-destructive
  /// exit — no destructive confirm. `null` when the row has no archive seam
  /// (no client).
  final VoidCallback? onArchive;

  /// The row's Unarchive (issue #235, the Archived surface): brings the
  /// session back to the Active surface. `null` when the row has no archive
  /// seam (no client).
  final VoidCallback? onUnarchive;

  /// The host → orb move (issue #97): the menu's "Move to orb…" item,
  /// offered to host sessions only (`session.orb == null`).
  final ValueChanged<Session>? onMoveToOrb;

  /// The `docker cp` export (issue #98, spec §3.4): the menu's "Export
  /// workspace…" item, offered to orb sessions only (`session.orb != null`).
  final ValueChanged<Session>? onExportWorkspace;

  /// The session → orb navigation (spec §9.2): called with the orb id when
  /// the chip is tapped.
  final ValueChanged<String>? onOrbChipTapped;

  /// The row's Stop (issue #165): stops the session's running turn through
  /// the bridge's cancel. Offered (to the right of the active dot) only while
  /// the session's Turn is Active (`session.active`), so an idle row shows no
  /// Stop. `null` when the row has no cancel seam (no client).
  final VoidCallback? onStop;

  /// True while the row's Stop is in flight: the control shows a busy
  /// spinner and ignores further presses (one request per turn).
  final bool stopping;

  /// The row's pin / unpin (issue #238): toggles the session's place in the
  /// home list's pinned block through the bridge's order route. Offered on
  /// every row (host and orb alike — the pin keys on the session id, which a
  /// host↔orb move preserves). `null` when the row has no order seam (no
  /// client).
  final VoidCallback? onPin;

  /// True while the row's pin / unpin write is in flight: the control shows a
  /// busy spinner and ignores further presses (one request per tap).
  final bool pinning;

  /// The status dot's color for its current state (issue #209): orange while
  /// waiting, green while active, violet while unread.
  Color get _dotColor => switch (dot) {
    RowDot.waiting => Colors.orange,
    RowDot.active => Colors.green,
    RowDot.unread => Colors.deepPurple,
    RowDot.none => Colors.transparent,
  };

  /// The chip (an orb session) or the muted "host" label (a host session).
  Widget _orbIdentity(BuildContext context) {
    final orbId = session.orb;
    final scheme = Theme.of(context).colorScheme;
    if (orbId == null) {
      return Text(
        'host',
        key: ValueKey('host-${session.id}'),
        style: TextStyle(fontSize: 12, color: scheme.outline),
      );
    }
    final record = orb;
    return InkWell(
      onTap: () => onOrbChipTapped?.call(orbId),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        key: ValueKey('orb-chip-$orbId'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: scheme.outlineVariant,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: _orbDotColor(record?.state ?? ''),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              record?.name ?? orbId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

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
                        // The row's status dot (before the title), one spot
                        // with three mutually exclusive states, in precedence
                        // order (issue #209): orange while the session is
                        // waiting on a permission or question (the row's
                        // `waiting` fact — it beats the green active dot, so a
                        // session still marked active during the block reads
                        // orange), green while its turn is active (the
                        // `active` fact), or violet while its turn ended
                        // unviewed (the module's unread mark, issue #207).
                        // The precedence is the module's (dotFor); an
                        // inactive, non-waiting, non-unread row shows none.
                        if (dot != RowDot.none) ...[
                          Container(
                            key: ValueKey('${dot.name}-${session.id}'),
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: _dotColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            // A just-created session has no title yet (the
                            // agent sets it on its first turn): the row
                            // reads its directory until `session.renamed`.
                            session.title.isNotEmpty
                                ? session.title
                                : session.location,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        _orbIdentity(context),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            session.location,
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
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // The row's Stop (issue #165): offered only while the Turn is
              // Active (the green dot is on) and there is a cancel seam. One
              // tap interrupts the turn on the owning service; the dot goes
              // out on the bridge's `session.turn.cancelled` (in place, no
              // refetch) or the service's terminal `session.execution.interrupted`.
              // Busy (spinner, ignores presses) while the cancel is in flight.
              if (session.active && onStop != null) ...[
                IconButton(
                  key: ValueKey('stop-${session.id}'),
                  tooltip: 'Stop the turn',
                  icon: stopping
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.stop, size: 18),
                  onPressed: stopping ? null : onStop,
                ),
                const SizedBox(width: 4),
              ],
              // The row's pin / unpin (issue #238): a filled pin while the row
              // is in the pinned block, an outlined one while it is not — the
              // state is carried by the icon (filled vs. outline), not by a
              // separate badge. Offered on every row with a client (host and
              // orb alike — the pin keys on the session id, which a host↔orb
              // move preserves); gone while the row shows a progress spinner
              // (delete, archive, move, export); busy (spinner, ignores
              // presses) while the order write is in flight.
              if (onPin != null && !deleting && !moving && !exporting) ...[
                IconButton(
                  key: ValueKey('pin-${session.id}'),
                  tooltip: session.pinned ? 'Unpin session' : 'Pin session',
                  icon: pinning
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          session.pinned
                              ? Icons.push_pin
                              : Icons.push_pin_outlined,
                          size: 18,
                        ),
                  onPressed: pinning ? null : onPin,
                ),
                const SizedBox(width: 4),
              ],
              deleting || archiving || moving || exporting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : PopupMenuButton<String>(
                      key: ValueKey('menu-${session.id}'),
                      tooltip: 'More actions',
                      onSelected: (action) {
                        switch (action) {
                          case 'delete':
                            onDelete(session);
                          case 'archive':
                            onArchive?.call();
                          case 'unarchive':
                            onUnarchive?.call();
                          case 'move-to-orb':
                            onMoveToOrb?.call(session);
                          case 'export-workspace':
                            onExportWorkspace?.call(session);
                        }
                      },
                      itemBuilder: (context) => [
                        // The archive's two faces (issue #235): **Archive**
                        // on the Active surface (the row is not archived
                        // yet), **Unarchive** on the Archived surface (it is).
                        // Non-destructive — no confirm dialog; the menu
                        // carries the note instead. The row moves between
                        // surfaces on the event the route emits.
                        if (session.archived)
                          const PopupMenuItem(
                            value: 'unarchive',
                            child: Text('Unarchive'),
                          )
                        else
                          const PopupMenuItem(
                            value: 'archive',
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Archive'),
                                Text(
                                  'Hides it from the list; you can '
                                  'unarchive it later.',
                                ),
                              ],
                            ),
                          ),
                        // Orb sessions only (issue #98, spec §3.4): the
                        // `docker cp` export of the orb's workspace.
                        if (session.orb != null)
                          const PopupMenuItem(
                            value: 'export-workspace',
                            child: Text('Export workspace…'),
                          ),
                        // Host sessions only (issue #97): an orb session
                        // already lives on its orb.
                        if (session.orb == null)
                          const PopupMenuItem(
                            value: 'move-to-orb',
                            child: Text('Move to orb…'),
                          ),
                        const PopupMenuItem(
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

/// The "Move to orb…" name prompt (issue #97): the target orb's name —
/// created with the full boot when absent, since the bridge blocks for the
/// whole move. Pops the trimmed name, or `null` when cancelled (an empty
/// name is not a confirmation).
class _MoveToOrbDialog extends StatefulWidget {
  const _MoveToOrbDialog({required this.sessionTitle});

  /// The title of the session being moved (the dialog's copy).
  final String sessionTitle;

  @override
  State<_MoveToOrbDialog> createState() => _MoveToOrbDialogState();
}

class _MoveToOrbDialogState extends State<_MoveToOrbDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Move to an orb?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '"${widget.sessionTitle}" will be moved onto the orb named '
            'below. The orb is created with a full boot when absent, and '
            'the move runs to completion before the list refreshes.',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('move-to-orb-name'),
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Orb name',
              hintText: 'e.g. dev',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('move-to-orb-confirm'),
          onPressed: () {
            final name = _controller.text.trim();
            if (name.isEmpty) return;
            Navigator.of(context).pop(name);
          },
          child: const Text('Move'),
        ),
      ],
    );
  }
}
