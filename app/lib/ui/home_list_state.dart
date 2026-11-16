import '../bridge/events/bridge_event.dart';
import '../client/events_client.dart';
import '../model/session.dart';

/// The home list's merged state (issue #266, the S7 expand): one module owns
/// everything the Sessions tab's list is about to show — the fetched rows,
/// the pin positions the in-place reorder keys off, the violet unread marks,
/// and the selected row — with a small interface: a fresh read in
/// ([applyRead]), a decoded event in ([applyEvent]), the state out (the
/// getters). No widget, no `setState`, no [BuildContext]: the module is
/// unit-testable flat (apply a read, apply an event, assert the state), and
/// the widget renders it exactly as before this extraction — the widget's
/// event switch just became [applyEvent], and its state fields the getters
/// below.
///
/// What the module deliberately does **not** own: the load's lifecycle
/// (in-flight, quiet, the last error) — that is the widget's client
/// transaction, applied here only through [applyRead]; the coalescing of a
/// burst of reloads (the widget's `while (_refreshAgain)` loop); and the
/// deep link (a navigation intent, not a row fact). The bridge-native
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
    final sessionId = sessionOf(event);
    switch (event.type) {
      case 'session.created':
      case 'session.renamed':
      case 'session.deleted':
      case BridgeEventType.sessionClosed:
        // `created` always reloads, even for a known id: the row's location,
        // project or orb attribution is not something the id alone proves.
        if (event.type == 'session.created' ||
            sessionId == null ||
            !hasRow(sessionId)) {
          return ListStateVerdict.reload;
        } else if (event.type == 'session.renamed') {
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
      case 'session.archived':
      case 'session.unarchived':
        if (sessionId == null || !hasRow(sessionId)) {
          return ListStateVerdict.reload;
        }
        patchRow(sessionId, archived: event.type == 'session.archived');
        return ListStateVerdict.none;
      case 'session.execution.started':
        if (sessionId != null) {
          _setActive(sessionId, true);
          clearUnread(sessionId);
        }
        return ListStateVerdict.none;
      case 'session.execution.succeeded':
      case 'session.execution.failed':
      case 'session.execution.interrupted':
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
      case 'permission.asked':
      case 'permission.replied':
      case 'form.created':
      case 'form.replied':
      case 'form.cancelled':
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

  /// The session an event names: the durable aggregate id (every
  /// session-scoped opencode event carries one), else `data.sessionID` (the
  /// bridge-native events), else the `form`'s nested session id, else `null`.
  /// Public because [applyEvent]'s [ListStateVerdict.reDeriveWaiting] caller
  /// needs the id for its lookups.
  static String? sessionOf(BridgeEvent event) {
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

  /// The in-place re-sort of the cached home list: the pinned rows first —
  /// known positions ascending (a tie, or a position the list has not seen,
  /// keeps the row's current place: the read already placed the pinned block
  /// position-ascending, so a cold start's `pinned` field renders in place)
  /// — then the unpinned rows newest-created. Stable: rows that compare equal
  /// keep their current order, so a re-sort never scrambles the block.
  ///
  /// [List.sort] is not stable, so the rows are ordered by a (key, index)
  /// pair: the key first, the original index as the tie-breaker. The index is
  /// the row's current position, which for a cold start is exactly the
  /// bridge's order — the app never has to re-derive it.
  ///
  /// Unlike the bridge's `SessionsBackend.homeListOrder` (which treats an
  /// unknown position as *unpinned* — correct for the store's own read), the
  /// app treats a *pinned* row with an unknown position as *keeping its
  /// place*: the cached list has no position for a cold-start row, and
  /// un-pinning-then-sorting would drag it out of the block.
  void _resort() {
    final rows = _rows;
    if (rows == null) return;
    final indexed = [
      for (var i = 0; i < rows.length; i++) (row: rows[i], index: i),
    ];
    indexed.sort((a, b) {
      final aPinned = a.row.pinned;
      final bPinned = b.row.pinned;
      // Pinned rows sort before unpinned rows.
      if (aPinned != bPinned) return aPinned ? -1 : 1;
      if (!aPinned) {
        // Both unpinned: newest-created first (the read's plain order).
        final byCreated = b.row.created.compareTo(a.row.created);
        if (byCreated != 0) return byCreated;
        return a.index.compareTo(b.index); // Tie: current order.
      }
      // Both pinned: known positions ascending (a tie breaks by created,
      // like the bridge); a position the list has not seen keeps the row's
      // current place (the index tie-breaker below).
      final posA = _positions[a.row.id];
      final posB = _positions[b.row.id];
      if (posA != null && posB != null) {
        final byPosition = posA.compareTo(posB);
        if (byPosition != 0) return byPosition;
        final byCreated = b.row.created.compareTo(a.row.created);
        if (byCreated != 0) return byCreated;
      }
      // Unknown position(s), a created tie, or a position tie: current order.
      return a.index.compareTo(b.index);
    });
    for (var i = 0; i < indexed.length; i++) {
      rows[i] = indexed[i].row;
    }
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

  /// The cached list's pin positions, keyed by session id: the row's pin
  /// position, or `null`/absent when the row is un-pinned. A cold start
  /// reads each row's `pinned` field (the read is pre-sorted) and the first
  /// `session.order.changed` for a row records its position; from then on
  /// the in-place re-sort keys off these. Cleared by [applyRead] (the read
  /// is authoritative and pre-sorted) and dropped per row when it leaves the
  /// list, like the unread marks.
  final Map<String, num> _positions = {};

  Session? _selected;

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
