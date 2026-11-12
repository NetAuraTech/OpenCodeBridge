import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../access/access_session.dart';
import '../bridge/events/bridge_event.dart';
import '../client/authenticated_http.dart';
import '../client/events_client.dart';
import '../client/fs_client.dart';
import '../client/orbs_client.dart';
import '../client/sessions_client.dart';
import '../model/orb.dart';
import '../model/session.dart';
import '../settings/app_settings.dart';
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

/// The Sessions tab: the home list (spec section 5 endpoint 1, section 6,
/// orbs section 9.2).
///
/// Shows every session of the shared opencode service, grouped by project
/// (collapsible), newest first, with the active indicator and a per-session
/// delete action. Tapping any row opens the structured view (spec §6). The
/// global New project button (issue #54) opens a filesystem browser that
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
    this.deepLinkSession,
    this.onDeepLinkSessionConsumed,
    this.onOpenSettings,
    this.settings,
    this.onThemeModeChanged,
    this.onOrbChipTapped,
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

  /// The session → orb navigation (spec §9.2): called with the orb id when
  /// the user taps an orb chip on a session row, so the caller (the shell)
  /// can switch to the Orbs tab and highlight that orb's card.
  final ValueChanged<String>? onOrbChipTapped;

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

  /// True while a [_refreshFromEvents]-triggered list load is in flight, so a
  /// burst (a spawn's create, rename and first turn) collapses into one load.
  bool _refreshInFlight = false;

  /// True when a session event arrived while [_refreshInFlight] was true:
  /// the list reloads once more when the in-flight one lands, so the last
  /// word is never dropped.
  bool _refreshAgain = false;

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

  /// The deep-link session awaiting a loaded list (issue #24): set when the
  /// target arrives before the rows; a failed load leaves it for the next
  /// successful one.
  String? _deepLinkPending;

  /// The session shown in the detail pane (issue #131): `null` shows the
  /// empty-state hint. Selecting a row (or a deep link, or a newly created
  /// session) swaps the pane in place; the list stays visible.
  Session? _selectedSession;

  /// The ids whose turn ended while they were not shown in the detail pane
  /// (issue #207): their row wears the violet unread dot. In memory only, per
  /// running app instance — it is not persisted and is not part of the
  /// sessions API contract. Driven by the unified event stream's turn
  /// boundaries (no list refetch for the dot itself) and pruned from the rows
  /// on every reload, so a session that leaves the list (deleted) drops its
  /// mark. Opening the session (row tap, narrow drawer, or a deep link) clears
  /// it, and a new turn starting on it clears it too (the "finished" fact is
  /// stale once the turn is live again).
  final Set<String> _unread = <String>{};

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
  /// detail pane (issue #131), whose banner shows the pending permission.
  /// Consumed immediately (the caller clears the target); when the list has
  /// not loaded yet, the target waits for it in [_deepLinkPending].
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
  }

  /// Stops the event source, disconnecting it only when the tab owns it.
  void _teardownEvents() {
    _eventsSub?.cancel();
    _eventsSub = null;
    final source = _events;
    if (source == null) return;
    _events = null;
    if (_ownsEvents) {
      _ownsEvents = false;
      unawaited(source.disconnect());
    }
  }

  /// The list's own reaction to the unified event stream (spec §8). The
  /// stream carries every service's events (host and orbs alike, issue
  /// #95), and a session id is globally unique: no service needs naming.
  ///
  /// - `session.created` — a session appeared, typically one the agent
  ///   spawned on an orb. The rows were fetched before it existed, so the
  ///   list reloads (coalesced, and quiet so the rows stay on screen).
  ///   This is what makes a spawned session show up without switching tabs.
  /// - `session.renamed` — the agent named the session on its first turn:
  ///   the row's title is patched in place. A rename for a session the list
  ///   does not know reloads instead (its create was missed).
  /// - `session.deleted` / the bridge-native `session.closed` — drop the row.
  /// - The turn boundaries (`session.execution.*`) move the row's active dot
  ///   in place, no refetch. A turn ending on a session that is not shown in
  ///   the detail pane also lights its violet unread dot (issue #207); a new
  ///   turn starting clears it (the "finished" fact is stale once the turn is
  ///   live again).
  /// - The bridge-native `session.turn.cancelled` (issue #164) — a cancelled
  ///   turn: the row's active dot goes out in place, no refetch, so a session
  ///   stopped from a panel no longer reads as busy (and lights the unread dot
  ///   when not shown, like any other terminal).
  ///
  /// Any other event naming an unknown session (a streamed delta, the first
  /// turn of a just-spawned orb session whose create preceded its upstream's
  /// attach) reloads too, coalesced: the list must never stay short of rows
  /// until the next manual refresh or app foreground.
  void _onBridgeEvent(BridgeEvent event) {
    if (!mounted) return;
    final rows = _rows;
    if (rows == null) return; // The initial load is still in flight.
    final sessionId = _sessionOf(event);
    switch (event.type) {
      case 'session.created':
      case 'session.renamed':
      case 'session.deleted':
      case BridgeEventType.sessionClosed:
        // `created` always reloads, even for a known id: the row's location,
        // project or orb attribution is not something the id alone proves.
        if (event.type == 'session.created' ||
            sessionId == null ||
            !_hasRow(rows, sessionId)) {
          unawaited(_refreshFromEvents());
        } else if (event.type == 'session.renamed') {
          _patchRow(sessionId, title: _titleOf(event));
        } else if (event.type == 'session.deleted' ||
            event.type == BridgeEventType.sessionClosed) {
          _patchRow(sessionId, drop: true);
        }
        return;
      case 'session.execution.started':
        if (sessionId != null) {
          _setActive(sessionId, true, rows);
          _clearUnread(sessionId);
        }
        return;
      case 'session.execution.succeeded':
      case 'session.execution.failed':
      case 'session.execution.interrupted':
        if (sessionId != null) {
          _setActive(sessionId, false, rows);
          _endUnread(sessionId);
        }
        return;
      // The bridge-native cancel (issue #164): the session's turn was stopped
      // (from a panel), so its active dot goes out in place — no refetch. The
      // service's own terminal for the cancelled turn (`interrupted`) would
      // settle it too, but this clears it the instant the cancel lands. As
      // any other terminal, it lights the unread dot when the session is not
      // shown (issue #207).
      case BridgeEventType.turnCancelled:
        if (sessionId != null) {
          _setActive(sessionId, false, rows);
          _endUnread(sessionId);
        }
        return;
      default:
        if (sessionId != null && !_hasRow(rows, sessionId)) {
          unawaited(_refreshFromEvents());
        }
    }
  }

  /// The session an event names: the durable aggregate id (every
  /// session-scoped opencode event carries one), else `data.sessionID` (the
  /// bridge-native events), else the `form`'s nested session id, else `null`.
  String? _sessionOf(BridgeEvent event) {
    final durable = event.durable;
    if (durable != null) return durable.aggregateID;
    final data = event.data;
    final id = data['sessionID'];
    if (id is String && id.isNotEmpty) return id;
    final form = data['form'];
    if (form is Map<String, Object?>) {
      final nested = form['sessionID'];
      if (nested is String && nested.isNotEmpty) return nested;
    }
    return null;
  }

  bool _hasRow(List<Session> rows, String id) =>
      rows.where((session) => session.id == id).isNotEmpty;

  /// The title a `session.renamed` payload carries (its `data.title`).
  String? _titleOf(BridgeEvent event) {
    final title = event.data['title'];
    return title is String && title.isNotEmpty ? title : null;
  }

  /// Replaces the row [id] in place: a new [title], an [active] dot, or
  /// ([drop]) nothing — the row is gone. A drop also clears the detail pane
  /// when it shows that row and drops its unread mark (issue #207); a patch
  /// otherwise carries the pane's row along.
  void _patchRow(String id, {String? title, bool? active, bool drop = false}) {
    final rows = _rows;
    if (rows == null) return;
    if (drop) {
      setState(() {
        _rows = [
          for (final session in rows)
            if (session.id != id) session,
        ];
        if (_selectedSession?.id == id) _selectedSession = null;
        _unread.remove(id);
      });
      return;
    }
    setState(() {
      _rows = [
        for (final session in rows)
          if (session.id == id)
            session.copyWith(title: title, active: active)
          else
            session,
      ];
      final selected = _selectedSession;
      if (selected != null && selected.id == id) {
        _selectedSession = selected.copyWith(title: title, active: active);
      }
    });
  }

  /// Moves the row [id]'s active dot, only when it actually disagrees (the
  /// turn boundaries arrive in pairs — the start right after the spawn).
  void _setActive(String id, bool active, List<Session> rows) {
    final row = rows.where((session) => session.id == id).firstOrNull;
    if (row == null || row.active == active) return;
    _patchRow(id, active: active);
  }

  /// A turn ended on [id] (any terminal, issue #207): light the violet unread
  /// dot in place when that session is not the one shown in the detail pane
  /// (it was watched live, so no dot then). Only sets the mark when it is not
  /// already set, so a burst of terminals does not churn the build.
  void _endUnread(String id) {
    if (_selectedSession?.id == id) return;
    if (_unread.contains(id)) return;
    setState(() => _unread.add(id));
  }

  /// A new turn started on [id] (issue #207): the "finished" fact is stale
  /// once the turn is live again, so the unread dot goes out (the green active
  /// dot is on instead). Only clears when it is set, so an already-read
  /// session is a no-op. (Opening [id] in the detail pane clears it too —
  /// that removal happens inside [_selectSession]'s `setState`, so the
  /// selection and the mark update atomically.)
  void _clearUnread(String id) {
    if (!_unread.contains(id)) return;
    setState(() => _unread.remove(id));
  }

  /// Drops the marks for rows that are no longer in the list (a deleted
  /// session, issue #207); the surviving marks stay. Called from [_load]
  /// (inside its `setState`, like [_reconcileSelection]) after the rows are in
  /// place, so event-driven and foreground re-fetches prune deleted sessions
  /// but never drop a still-valid mark.
  void _reconcileUnread(List<Session> rows) {
    final present = rows.map((session) => session.id).toSet();
    for (final id in _unread.toList()) {
      if (!present.contains(id)) _unread.remove(id);
    }
  }

  /// Reloads the list after a session event, coalescing bursts: while a load
  /// is in flight the request is remembered and one more load runs when it
  /// lands (a spawn's create, rename and first turn arrive together).
  Future<void> _refreshFromEvents() async {
    if (_refreshInFlight) {
      _refreshAgain = true;
      return;
    }
    _refreshInFlight = true;
    try {
      _refreshAgain = true;
      while (_refreshAgain && mounted) {
        _refreshAgain = false;
        await _load(quiet: true);
      }
    } finally {
      _refreshInFlight = false;
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
      final pending = _deepLinkPending;
      setState(() {
        _rows = rows;
        _loading = false;
        _reconcileSelection(rows);
        _reconcileUnread(rows);
      });
      if (pending != null) _openDeepLinkRow(pending, rows);
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

  /// Keeps the detail pane's selection in sync with the freshly loaded rows
  /// (issue #131): refreshes the selected row's data when it still exists,
  /// clears the selection when it is gone (e.g. deleted).
  void _reconcileSelection(List<Session> rows) {
    final selected = _selectedSession;
    if (selected == null) return;
    final fresh = rows.where((s) => s.id == selected.id).firstOrNull;
    _selectedSession = fresh;
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
    setState(() {
      _selectedSession = session;
      _drawerOpen = false;
      // Opening the session in the detail pane clears its unread dot (issue
      // #207), from every entry point (row tap, narrow drawer, deep link).
      _unread.remove(session.id);
    });
  }

  void _clearSelection() {
    if (!mounted) return;
    setState(() => _selectedSession = null);
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

  /// The rows grouped by project, newest first (the rows arrive pre-sorted,
  /// so grouping preserves the order).
  List<_ProjectGroup> get _groups => _groupByProject(_rows ?? const []);

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
    if (_loading && _rows == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_rows == null) {
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
  Widget _buildNarrow(double width) {
    // A Stack that fills the space: the detail column underneath, and — when
    // open — the scrim and the drawer positioned over it (an overlay, so the
    // drawer never takes layout space from the detail).
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
        if (_drawerOpen) ...[
          // The scrim and the drawer start below the top bar (like a Material
          // drawer below its AppBar): the top bar stays on top, so the toggle
          // is always reachable (it closes the drawer too), and the drawer
          // never hides the control that dismisses it.
          // The scrim: a tap anywhere on it closes the drawer without
          // touching the selection (issue #133).
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
          // The drawer: the session list from the left edge over the detail.
          Positioned(
            top: kToolbarHeight,
            bottom: 0,
            left: 0,
            child: SizedBox(
              key: const ValueKey('sessions-drawer'),
              width: min(kSessionsDrawerWidth, width),
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                child: _buildListPane(),
              ),
            ),
          ),
        ],
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
    final rows = _rows ?? const <Session>[];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const ValueKey('sessions-list'),
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
              subtitle: Text(_groupSubtitle(group)),
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
                    moving: _movingId == s.id,
                    exporting: _exportingId == s.id,
                    unread: _unread.contains(s.id),
                    onTap: _rowTap(s),
                    onDelete: _confirmDelete,
                    onMoveToOrb: _moveToOrb,
                    onExportWorkspace: _exportWorkspace,
                    orb: _orbOf(s.orb),
                    onOrbChipTapped: widget.onOrbChipTapped,
                    onStop: _client == null ? null : () => _stopTurn(s),
                    stopping: _stoppingId == s.id,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildDetailPane({required bool showClose}) {
    final session = _selectedSession;
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
    required this.moving,
    required this.exporting,
    required this.onDelete,
    required this.orb,
    this.unread = false,
    this.onTap,
    this.onMoveToOrb,
    this.onExportWorkspace,
    this.onOrbChipTapped,
    this.onStop,
    this.stopping = false,
  });

  final Session session;

  /// The row's unread mark (issue #207): true when the session's turn ended
  /// while it was not shown in the detail pane. The status dot (before the
  /// title) wears it as a violet dot, mutually exclusive with the green
  /// active dot — the two are states of the same spot.
  final bool unread;

  /// The orb the session lives on (spec §9.2): the chip's name and state
  /// dot. `null` when the orb is absent from the list (deleted in the
  /// meantime) — the chip then falls back to the raw orb id. `session.orb`
  /// being `null` means a host session (the muted "host" label).
  final OrbRecord? orb;

  /// Opens the session's structured view; `null` when the row has nothing
  /// to open.
  final VoidCallback? onTap;

  final bool deleting;

  /// True while the row's host→orb move (issue #97) is in flight: the row
  /// shows progress, and the menu is gone for the whole blocking move.
  final bool moving;

  /// True while the row's workspace export (issue #98, spec §3.4) is in
  /// flight: the row shows progress, and the menu is gone for the blocking
  /// export.
  final bool exporting;

  final ValueChanged<Session> onDelete;

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
                        // with two mutually exclusive states (issue #207):
                        // green while the session's turn is active (the
                        // existing `active` fact), or violet while its turn
                        // ended unviewed (the tab-local unread mark).
                        if (session.active || unread) ...[
                          Container(
                            key: ValueKey(
                              '${session.active ? 'active' : 'unread'}-${session.id}',
                            ),
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: session.active
                                  ? Colors.green
                                  : Colors.deepPurple,
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
              deleting || moving || exporting
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
                          case 'move-to-orb':
                            onMoveToOrb?.call(session);
                          case 'export-workspace':
                            onExportWorkspace?.call(session);
                        }
                      },
                      itemBuilder: (context) => [
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
