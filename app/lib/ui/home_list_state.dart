import '../bridge/events/bridge_event.dart';
import '../bridge/events/opencode_event_types.dart';
import '../client/events_client.dart';
import '../model/session.dart';

/// The home list's merged state (issue #266, the S7 expand): one module owns
/// everything the Sessions tab's list is about to show — the fetched rows,
/// the pin positions the in-place reorder keys off, the violet unread marks,
/// the selected row, the Active / Archived surface, and each row's status
/// dot — with a small interface: a fresh read in ([applyRead]), a decoded
/// event in ([applyEvent]), the state out (the getters). No widget, no
/// `setState`, no [BuildContext]: the module is unit-testable flat (apply a
/// read, apply an event, assert the state), and the widget renders it
/// exactly as before this extraction — the widget's event switch just became
/// [applyEvent], and its state fields the getters below. The widget keeps no
/// list state of its own (issue #269, the S7 contract): the surface
/// ([showingArchived] / [toggleSurface] / [surfaceRows]) and the row's status
/// dot ([dotFor]) are the module's, so the widget renders the list purely
/// from this module.
///
/// What the module deliberately does **not** own: the load's lifecycle
/// (in-flight, quiet, the last error) — that is the widget's client
/// transaction, applied here only through [applyRead]; and the deep link (a
/// navigation intent, not a row fact). The *decision* of a burst of reloads
/// **does** live here (issue #268): [requestReload] / [drainReload] /
/// [endReload] are the synchronous half of the widget's reload coalescing —
/// the widget's loop asks whether to start a load, whether a queued one should
/// run after the one in flight lands, and when to clear both. The *I/O* of
/// the load (the `list()` call itself, with its `quiet` posture and its
/// failure handling) stays in the widget: the module has no `Future`, and a
/// row must never be fetched from here. The bridge-native
/// `session.order.changed` is the module's own event (the row's pin fact),
/// while the permission and question events re-derive their fact *outside*
/// the module (the [applyEvent] caller issues the service lookups and hands
/// the result back in through [patchRow], with [hasRow] to guard against a
/// row that was dropped while the lookups were in flight) — the seam keeps
/// the module synchronous and the lookup failures stay the widget's to keep
/// the last word on screen.
///
/// Before the first successful load the module holds no rows, so every
/// event is a no-op ([ListStateVerdict.none]): the widget's list refresh is
/// in flight and carries the facts when it lands.
class HomeListState {
  /// The fetched rows in their current display order (a fresh read's order,
  /// re-sorted in place as pin events land), or `null` until the first
  /// successful load.
  List<Session>? get rows => _rows;

  /// True when [rows] hold a row with [id] (the events' known-session
  /// branch); false before the first read and after a row leaves.
  bool hasRow(String id) => rows?.where((s) => s.id == id).isNotEmpty ?? false;

  /// The detail pane's row (the one the structured view shows), or `null`
  /// for the empty-state hint.
  Session? get selected => _selected;

  /// True while a turn ended on [id] while it was not shown in the detail
  /// pane (the row wears the violet unread dot).
  bool isUnread(String id) => _unread.contains(id);

  /// The row's status dot (issue #209), as the module derives it: one spot
  /// with three mutually exclusive states, in precedence order — [RowDot.waiting]
  /// (orange, the row's `waiting` fact) beats [RowDot.active] (green, the
  /// `active` fact) beats [RowDot.unread] (violet, the module's unread mark
  /// for [row.id]); [RowDot.none] when none holds. The widget renders the
  /// dot purely from this — the precedence is the module's, so the dot
  /// states are unit-testable flat (apply the facts, assert the dot), not
  /// only through scripted widget events.
  RowDot dotFor(Session row) {
    if (row.waiting) return RowDot.waiting;
    if (row.active) return RowDot.active;
    if (_unread.contains(row.id)) return RowDot.unread;
    return RowDot.none;
  }

  /// The home list's surface (issue #235): `false` shows **Active** (the
  /// default — the rows that are not archived, matching the TUI's own
  /// default, the research's Q1), `true` shows **Archived** (the rows that
  /// are). A render filter over the same fetched rows — the list keeps
  /// fetching every row (the seam is faithful, issue #234) and the two
  /// surfaces are the same rows read two ways (Q7's lower-effort shape).
  /// Transient, like the module's selection and unread marks: not persisted.
  bool get showingArchived => _showingArchived;

  /// The rows of the current surface ([showingArchived]): the module's rows
  /// filtered to the surface's `archived` flag. The widget renders these
  /// (grouped, with its layout); the filter itself is the module's, so the
  /// surface is unit-testable flat (toggle the surface, assert the rows).
  List<Session> get surfaceRows => [
    for (final session in _rows ?? const <Session>[])
      if (session.archived == _showingArchived) session,
  ];

  /// Flips the surface between **Active** and **Archived** (issue #235): a
  /// render filter over the same rows — no fetch, no bridge call.
  void toggleSurface() {
    _showingArchived = !_showingArchived;
  }

  /// A fresh read (a successful `list()` fetch): replaces the rows, clears
  /// the in-place pin positions (the read is authoritative and pre-sorted —
  /// the exact pin times learned from echoes are no longer needed), and
  /// reconciles the selection and the unread marks against the rows (the
  /// selected row refreshes to its fresh data and is cleared when it is
  /// gone; a mark whose row left the list is dropped). The row the caller
  /// holds on to (its deep-link target, say) is refreshed here: it is the
  /// row's *identity* that the widget keeps, not the list's object.
  void applyRead(List<Session> rows) {
    _rows = rows;
    _positions.clear();
    _reconcileSelection(rows);
    _reconcileUnread(rows);
  }

  /// The home list's reaction to one decoded event from the bridge's
  /// unified stream (spec §8): the exact merge the Sessions tab's event
  /// switch applied before the extraction, moved here.
  ///
  /// - `session.created` — always reloads, even for a known id: the row's
  ///   location, project or orb attribution is not something the id alone
  ///   proves.
  /// - `session.renamed` — the row's title is patched in place. A rename for
  ///   a session the list does not know reloads instead (its create was
  ///   missed).
  /// - `session.archived` / `session.unarchived` — the row's `archived` fact
  ///   is patched in place, no refetch, so the surface filter (Active /
  ///   Archived) moves it. An archive for a session the list does not know
  ///   reloads instead (its create was missed), like any other unknown id.
  /// - `session.deleted` / the bridge-native `session.closed` — the row is
  ///   dropped, with its pin position and unread mark, and the detail pane
  ///   cleared when it shows it.
  /// - The turn boundaries (`session.execution.*`) move the row's active dot
  ///   in place, no refetch. A turn ending on a session that is not shown in
  ///   the detail pane lights its violet unread dot; a new turn starting
  ///   clears it (the "finished" fact is stale once the turn is live again).
  /// - The bridge-native `session.turn.cancelled` — a cancelled turn: the
  ///   row's active dot goes out in place, no refetch, and it lights the
  ///   unread dot when the session is not shown, like any other terminal.
  /// - The bridge-native `session.order.changed` — a known row's pin fact is
  ///   patched in place and the list re-sorts (no refetch), the same merge
  ///   posture as the title and the archived fact; a row the list does not
  ///   know (a missed create) reloads, like any other unknown-session event.
  /// - The pending permission and question events (`permission.asked` /
  ///   `permission.replied`, `form.created` / `form.replied` /
  ///   `form.cancelled`) — the waiting fact is re-derived *outside* the
  ///   module (the service's pending states are the source), so this only
  ///   decides: a known row says [ListStateVerdict.reDeriveWaiting] (the
  ///   caller does the lookups and hands the result in through
  ///   [patchRow]); an unknown one reloads.
  /// - Any other event naming a session the list does not know (a streamed
  ///   delta, the first turn of a just-spawned orb session whose create
  ///   preceded its upstream's attach) reloads too: the list must never stay
  ///   short of rows until the next manual refresh or app foreground.
  ///
  /// The result tells the caller (the widget) whether to reload the list
  /// ([ListStateVerdict.reload], coalesced by the caller) or to re-derive the
  /// waiting fact ([ListStateVerdict.reDeriveWaiting], with the lookups and
  /// their failure posture in the widget). Before the first successful load
  /// (the module holds no rows yet) it is always [ListStateVerdict.none].
  ListStateVerdict applyEvent(BridgeEvent event) {
    if (_rows == null) return ListStateVerdict.none;
    final sessionId = event.sessionId;
    switch (event.type) {
      case OpencodeEventType.sessionCreated:
      case OpencodeEventType.sessionRenamed:
      case OpencodeEventType.sessionDeleted:
      case BridgeEventType.sessionClosed:
        // `created` always reloads, even for a known id: the row's location,
        // project or orb attribution is not something the id alone proves.
        if (event.type == OpencodeEventType.sessionCreated ||
            sessionId == null ||
            !hasRow(sessionId)) {
          return ListStateVerdict.reload;
        } else if (event.type == OpencodeEventType.sessionRenamed) {
          patchRow(sessionId, title: _titleOf(event));
        } else {
          patchRow(sessionId, drop: true);
        }
        return ListStateVerdict.none;
      // The archive's two faces: the row's `archived` fact is flipped in
      // place — no refetch — and the surface filter (Active / Archived)
      // moves it accordingly. A known row's flip is the whole action (the
      // tap that caused it re-fetches nothing); an unknown id (a create was
      // missed) reloads, like any other unknown session.
      case OpencodeEventType.sessionArchived:
      case OpencodeEventType.sessionUnarchived:
        if (sessionId == null || !hasRow(sessionId)) {
          return ListStateVerdict.reload;
        }
        patchRow(
          sessionId,
          archived: event.type == OpencodeEventType.sessionArchived,
        );
        return ListStateVerdict.none;
      case OpencodeEventType.sessionExecutionStarted:
        if (sessionId != null) {
          _setActive(sessionId, true);
          clearUnread(sessionId);
        }
        return ListStateVerdict.none;
      case OpencodeEventType.sessionExecutionSucceeded:
      case OpencodeEventType.sessionExecutionFailed:
      case OpencodeEventType.sessionExecutionInterrupted:
        if (sessionId != null) {
          _setActive(sessionId, false);
          endUnread(sessionId);
        }
        return ListStateVerdict.none;
      // The bridge-native cancel: the session's turn was stopped (from a
      // panel), so its active dot goes out in place — no refetch. The
      // service's own terminal for the cancelled turn (`interrupted`) would
      // settle it too, but this clears it the instant the cancel lands. As
      // any other terminal, it lights the unread dot when the session is
      // not shown.
      case BridgeEventType.turnCancelled:
        if (sessionId != null) {
          _setActive(sessionId, false);
          endUnread(sessionId);
        }
        return ListStateVerdict.none;
      // The bridge-native order change: a session's position in the home
      // list's pinned block changed — a pin from another device / agent, or
      // this device's own echo. A known row's pin fact is patched in place
      // and the list re-sorts (no refetch), the same merge posture as the
      // title and the archived fact; a row the list does not know (a missed
      // create) reloads, like any other unknown-session event.
      case BridgeEventType.sessionOrderChanged:
        if (sessionId == null) return ListStateVerdict.none;
        if (hasRow(sessionId)) {
          setOrder(sessionId, _positionOf(event));
        } else {
          return ListStateVerdict.reload;
        }
        return ListStateVerdict.none;
      // The pending permission and question facts: the same events the
      // structured view consumes (`permission.asked` / `permission.replied`,
      // `form.created` / `form.replied` / `form.cancelled`). The fact itself
      // is re-derived from the service's pending states, outside the module
      // (the dot flips orange, or off, the instant the permission or
      // question appears or resolves).
      case OpencodeEventType.permissionAsked:
      case OpencodeEventType.permissionReplied:
      case OpencodeEventType.formCreated:
      case OpencodeEventType.formReplied:
      case OpencodeEventType.formCancelled:
        if (sessionId == null) return ListStateVerdict.none;
        if (hasRow(sessionId)) return ListStateVerdict.reDeriveWaiting;
        // The row is not known: a create was missed (a spawned orb session),
        // so the list reloads, like any other event naming an unknown
        // session — the waiting fact arrives with the fresh row.
        return ListStateVerdict.reload;
      default:
        if (sessionId != null && !hasRow(sessionId)) {
          return ListStateVerdict.reload;
        }
        return ListStateVerdict.none;
    }
  }

  /// Replaces the row [id] in place: a new [title], an [active] dot, a
  /// re-derived [waiting] fact, an [archived] fact (from the
  /// `session.archived` / `session.unarchived` events), or ([drop]) nothing
  /// — the row is gone. A drop also clears the detail pane when it shows
  /// that row and drops its unread mark; a patch otherwise carries the pane's
  /// row along.
  void patchRow(
    String id, {
    String? title,
    bool? active,
    bool? waiting,
    bool? archived,
    bool drop = false,
  }) {
    final rows = _rows;
    if (rows == null) return;
    if (drop) {
      _rows = [
        for (final session in rows)
          if (session.id != id) session,
      ];
      _positions.remove(id);
      if (_selected?.id == id) _selected = null;
      _unread.remove(id);
      return;
    }
    _rows = [
      for (final session in rows)
        if (session.id == id)
          session.copyWith(
            title: title,
            active: active,
            waiting: waiting,
            archived: archived,
          )
        else
          session,
    ];
    final selected = _selected;
    if (selected != null && selected.id == id) {
      _selected = selected.copyWith(
        title: title,
        active: active,
        waiting: waiting,
        archived: archived,
      );
    }
  }

  /// The row [id]'s pin fact, from [position] (its pin time, or `null` when
  /// the pin was cleared): the row's `pinned` flag is patched in place and
  /// the cached list re-sorts — no refetch. This is the merge point for both
  /// pin paths: the bridge-native `session.order.changed` (a pin from another
  /// device or agent, or this device's own echo) and a successful local pin
  /// write (whose outcome the widget applies here the same way).
  ///
  /// No-ops that would waste a re-sort and a build: a redundant un-pin of an
  /// already-un-pinned row, or a re-echo of a pin this list already applied
  /// (the same position, the row already pinned).
  ///
  /// The row's `pinned` fact flips to `position != null` and the list
  /// re-sorts pinned-first, then the current order (the cached list already
  /// holds the bridge's position-ascending pinned block; a position the list
  /// has not seen — a cold start's `pinned` field, or an echo for a row it
  /// has not re-ordered — keeps the row where the read placed it). A row
  /// that is not in the list (a missed create) is a no-op here — the
  /// unknown-session path of [applyEvent] reloads.
  ///
  /// Answers whether the list actually changed: a no-op (before the first
  /// read, a redundant un-pin of an already-un-pinned row, a re-echo of a pin
  /// this list already applied — the same position, the row already pinned)
  /// wastes neither a re-sort nor a build.
  bool setOrder(String id, num? position) {
    final rows = _rows;
    if (rows == null) return false;
    final row = rows.where((session) => session.id == id).firstOrNull;
    if (row == null) return false;
    final pinned = position != null;
    // No-ops that would waste a re-sort and a build: a redundant un-pin of an
    // already-un-pinned row, or a re-echo of a pin this list already applied
    // (the same position, the row already pinned).
    if (!pinned && !row.pinned) return false;
    if (pinned && row.pinned && _positions[id] == position) return false;
    if (position != null) {
      _positions[id] = position;
    } else {
      _positions.remove(id);
    }
    _rows = [
      for (final session in rows)
        if (session.id == id) session.copyWith(pinned: pinned) else session,
    ];
    _resort();
    final selected = _selected;
    if (selected != null && selected.id == id) {
      _selected = selected.copyWith(pinned: pinned);
    }
    return true;
  }

  /// A turn ended on [id] (any terminal): light the violet unread mark in
  /// place when that session is not the one shown in the detail pane (it
  /// was watched live, so no mark then). Only sets the mark when it is not
  /// already set, so a burst of terminals does not churn the build.
  void endUnread(String id) {
    if (_selected?.id == id) return;
    _unread.add(id);
  }

  /// A new turn started on [id]: the "finished" fact is stale once the turn
  /// is live again, so the unread mark goes out (the green active dot is on
  /// instead). Only clears when it is set, so an already-read session is a
  /// no-op. (Opening [id] in the detail pane clears it too — that removal
  /// happens inside [select] with the selection, so the two update
  /// atomically.)
  void clearUnread(String id) {
    _unread.remove(id);
  }

  /// Selects [session] in the detail pane: swaps the pane's row in place and
  /// clears that row's unread mark — the two atomically, from every entry
  /// point (row tap, narrow drawer, deep link).
  void select(Session? session) {
    _selected = session;
    _unread.remove(session?.id ?? '');
  }

  // ── Reload coalescing (issue #268) ────────────────────────────────────────
  //
  // The synchronous half of the home list's reload coalescing. Before this
  // move the widget owned two bools and the `while (_refreshAgain)` loop; the
  // *decision* now lives here (the widget's `_refreshFromEvents` became a thin
  // driver) while the *I/O* — the actual `list()` fetch, its quiet posture,
  // its error handling — stays the widget's (this module is synchronous: no
  // `Future`, no `await`, and a row is never fetched from here).
  //
  // A reload's verdict (`session.created`, an unknown-session event, a missed
  // create) means "fetch the rows again". A burst of such verdicts (a spawn's
  // create, rename and first turn arrive together) must collapse into loads,
  // not one fetch per event: while a load is in flight a request is merely
  // queued, and exactly ONE extra load runs when the in-flight one lands —
  // each "wave" of queued requests costs one more load, so the last word is
  // never dropped and a burst of N events never triggers N fetches.

  /// Requests a reload of the list (issue #268): the event verdict that says
  /// "fetch the rows again" calls this instead of fetching.
  ///
  /// Answers whether **this** caller should start the load now. `true` means
  /// no reload was in flight — the caller runs its load loop (a `_load`, then
  /// [drainReload] after each one lands, then [endReload] when the loop
  /// ends). `false` means a reload was already in flight: this request was
  /// merely queued behind it, and it runs as ONE extra load when that
  /// in-flight one lands — no second loop is started, so the burst collapses
  /// instead of racing two fetches.
  ///
  /// This is the module's memory of the burst: the two bools the widget used
  /// to keep (`_refreshInFlight`, `_refreshAgain`) are now the module's own
  /// `_inFlight` and `_again` fields, and the driver's `while (_refreshAgain)`
  /// became [drainReload] with [endReload] as its exit. The driver's loop is
  /// unchanged in behaviour (a single request → one load; a burst during a
  /// load → one more load), so the move is of the state and decision, not of
  /// the behaviour.
  bool requestReload() {
    if (_inFlight) {
      _again = true;
      return false;
    }
    _inFlight = true;
    _again = false;
    return true;
  }

  /// Asks whether the reload just landed should be followed by the queued
  /// reload (issue #268). Called by the driver after each `_load` it ran.
  ///
  /// `true` means a reload was requested while that load was in flight (a
  /// "wave" of queued events): it is consumed here (so the next wave does not
  /// re-trigger it) and the driver runs exactly one more load, which will
  /// pick up the fresh state. `false` means nothing was queued: the driver's
  /// loop ends and it clears both halves through [endReload].
  ///
  /// A burst that arrives while a load is in flight is remembered as a single
  /// [again], so one burst costs exactly one extra load regardless of how many
  /// events were in it — the collapse the old loop provided.
  bool drainReload() {
    final runAgain = _again;
    _again = false;
    return runAgain;
  }

  /// Clears the coalescing state entirely (issue #268). Called by the driver
  /// when its loop ends — a clean exit **and** an aborted one (the widget
  /// unmounted mid-load, its `mounted` guard breaking the loop). The state is
  /// always reset, so a later, fresh reload starts clean rather than inheriting
  /// a stale "in flight" or "queued" flag.
  void endReload() {
    _inFlight = false;
    _again = false;
  }

  /// The title a `session.renamed` payload carries (its `data.title`).
  static String? _titleOf(BridgeEvent event) {
    final title = event.data['title'];
    return title is String && title.isNotEmpty ? title : null;
  }

  /// The position a `session.order.changed` payload carries (its
  /// `data.position`): the row's new pin position, or `null` when the pin
  /// was cleared. A non-numeric value (malformed) reads as `null`, the safe
  /// default (an unknown position un-pins rather than corrupting the order).
  static num? _positionOf(BridgeEvent event) {
    final position = event.data['position'];
    return position is num ? position : null;
  }

  /// Moves the row [id]'s active dot, only when it actually disagrees (the
  /// turn boundaries arrive in pairs — the start right after the spawn).
  void _setActive(String id, bool active) {
    final rows = _rows;
    if (rows == null) return;
    final row = rows.where((session) => session.id == id).firstOrNull;
    if (row == null || row.active == active) return;
    patchRow(id, active: active);
  }

  /// The in-place re-sort of the cached home list (issue #268): the rows are
  /// ordered by [homeListOrder], keyed on this module's pin positions
  /// ([_positions]) and the rows' current indices, then written back. A thin
  /// driver over the pure comparator — the comparator is the testable
  /// artifact, the (row, index) pairing and the write-back are the
  /// module-internal glue that keeps it applied to *these* rows.
  ///
  /// [List.sort] is not stable, so the rows are ordered by a (row, index)
  /// pair: the comparator first, the original index as the stable
  /// tie-breaker. The index is the row's current position, which for a cold
  /// start is exactly the bridge's order — the app never has to re-derive it.
  void _resort() {
    final rows = _rows;
    if (rows == null) return;
    final indexed = [
      for (var i = 0; i < rows.length; i++) (row: rows[i], index: i),
    ];
    indexed.sort(
      (a, b) =>
          homeListOrder(a.row, a.index, b.row, b.index, (id) => _positions[id]),
    );
    for (var i = 0; i < indexed.length; i++) {
      rows[i] = indexed[i].row;
    }
  }

  /// The home list's sort comparator (issue #268): the order the Sessions
  /// tab renders its rows in, as a **pure** function — given two rows, their
  /// two current indices (the stable tie-breaker), and a [positionOf] lookup
  /// for a row's pin position, it answers which comes first. No module state,
  /// no widget: it is the app's cached-list analogue of the bridge's
  /// `SessionsBackend.homeListOrder` (pinned-first, position ascending for
  /// the pinned block, newest-created for the rest), modelled on it and
  /// deliberately **different** where the app's cache needs to stay stable
  /// across an in-place re-sort. [positionOf] is injected (the bridge injects
  /// its store's map lookup the same way) so the comparator is unit-testable
  /// on its own, keyed on any position the test holds. The indices, too, are
  /// parameters: unlike the bridge (which sorts the store's fresh read once),
  /// the app re-sorts a cache in place, so the comparator must take the
  /// rows' current order and use it as the tie-breaker to stay stable.
  ///
  /// Ordering, for two rows with their CURRENT index (the stable tie-breaker):
  ///
  /// 1. Pinned rows sort before unpinned rows.
  /// 2. Both UNPINNED: newest-created first ([b.created] vs [a.created];
  ///    [Session.created] is epoch-millis, higher = newer). On a created tie
  ///    → current order (index).
  /// 3. Both PINNED:
  ///    - If BOTH rows have a KNOWN pin position: position ascending; on a
  ///      position tie → newest-created first; on that tie → current order
  ///      (index).
  ///    - If EITHER row's position is UNKNOWN (a cold-start row the read
  ///      placed in place, so the list holds no pin position for it): the
  ///      rows keep their CURRENT relative order (index tie-breaker).
  ///
  /// That last rule is the app-specific one. Unlike the bridge's
  /// `SessionsBackend.homeListOrder` — which treats an unknown position as
  /// *unpinned* (correct for the store's own read, where a missing position
  /// *is* "not pinned") — the app treats a *pinned* row with an unknown
  /// position as *keeping its place*: the cached list has no position for a
  /// cold-start row, and un-pinning-then-sorting would drag it out of the
  /// pinned block. The index tie-breaker keeps it where the read put it.
  ///
  /// Stable: rows that compare equal return their index difference, so a
  /// re-sort never scrambles the block the read (or a prior re-sort) already
  /// arranged.
  static int homeListOrder(
    Session a,
    int indexA,
    Session b,
    int indexB,
    num? Function(String id) positionOf,
  ) {
    final aPinned = a.pinned;
    final bPinned = b.pinned;
    // Pinned rows sort before unpinned rows.
    if (aPinned != bPinned) return aPinned ? -1 : 1;
    if (!aPinned) {
      // Both unpinned: newest-created first (the read's plain order).
      final byCreated = b.created.compareTo(a.created);
      if (byCreated != 0) return byCreated;
      return indexA.compareTo(indexB); // Tie: current order.
    }
    // Both pinned: known positions ascending (a tie breaks by created, like
    // the bridge); a position the list has not seen keeps the row's current
    // place (the index tie-breaker below).
    final posA = positionOf(a.id);
    final posB = positionOf(b.id);
    if (posA != null && posB != null) {
      final byPosition = posA.compareTo(posB);
      if (byPosition != 0) return byPosition;
      final byCreated = b.created.compareTo(a.created);
      if (byCreated != 0) return byCreated;
    }
    // Unknown position(s), a created tie, or a position tie: current order.
    return indexA.compareTo(indexB);
  }

  /// Keeps the detail pane's selection in sync with the freshly loaded rows:
  /// refreshes the selected row's data when it still exists, clears the
  /// selection when it is gone (e.g. deleted).
  void _reconcileSelection(List<Session> rows) {
    final selected = _selected;
    if (selected == null) return;
    _selected = rows.where((s) => s.id == selected.id).firstOrNull;
  }

  /// Drops the unread marks for rows that are no longer in the list (a
  /// deleted session); the surviving marks stay. Called from [applyRead]
  /// after the rows are in place, so event-driven and foreground re-fetches
  /// prune deleted sessions but never drop a still-valid mark.
  void _reconcileUnread(List<Session> rows) {
    final present = rows.map((session) => session.id).toSet();
    for (final id in _unread.toList()) {
      if (!present.contains(id)) _unread.remove(id);
    }
  }

  List<Session>? _rows;

  /// True while a [_refreshFromEvents]-triggered reload is in flight (the
  /// driver's loop is running its loads), so a burst of reload-verdict events
  /// collapses into one extra load rather than one fetch per event. Set by
  /// [requestReload] when it starts the loop, cleared by [endReload]. (The
  /// widget's old `_refreshInFlight`.)
  bool _inFlight = false;

  /// True when a reload was requested while [_inFlight] was true: the queued
  /// wave runs as one extra load when the in-flight one lands (consumed by
  /// [drainReload]). (The widget's old `_refreshAgain`.)
  bool _again = false;

  /// The cached list's pin positions, keyed by session id: the row's pin
  /// position, or `null`/absent when the row is un-pinned. A cold start
  /// reads each row's `pinned` field (the read is pre-sorted) and the first
  /// `session.order.changed` for a row records its position; from then on
  /// the in-place re-sort keys off these. Cleared by [applyRead] (the read
  /// is authoritative and pre-sorted) and dropped per row when it leaves the
  /// list, like the unread marks.
  final Map<String, num> _positions = {};

  Session? _selected;

  /// The home list's surface (issue #235): `true` shows the Archived surface,
  /// `false` (the default) the Active one. A transient render filter over the
  /// rows, not persisted.
  bool _showingArchived = false;

  /// The ids whose turn ended while they were not shown in the detail pane
  /// (the violet unread dots): in memory only, per running app instance —
  /// not persisted and not part of the sessions API contract. Driven by the
  /// unified event stream's turn boundaries (no list refetch for the mark
  /// itself) and pruned from the rows by [applyRead], so a session that
  /// leaves the list (deleted) drops its mark.
  final Set<String> _unread = <String>{};
}

/// What [HomeListState.applyEvent] asks the caller (the widget) to do:
/// nothing — the event was merged in place — reload the list (coalesced by
/// the caller's in-flight tracking, as before), or re-derive the named
/// row's waiting fact from the service's pending states (the lookups and
/// their failure posture stay in the widget, which hands the result back in
/// through [HomeListState.patchRow]).
enum ListStateVerdict { none, reload, reDeriveWaiting }

/// The home list row's status dot (issue #209): one spot with three mutually
/// exclusive states, in precedence order — [waiting] (orange, the row's
/// `waiting` fact, a pending permission or question) beats [active] (green,
/// the turn is live) beats [unread] (violet, the turn ended unviewed);
/// [none] otherwise. The widget maps the kind to its colour and key; the
/// precedence itself is the module's (see [HomeListState.dotFor]).
enum RowDot { none, waiting, active, unread }
