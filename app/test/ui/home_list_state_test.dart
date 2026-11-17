import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/events/bridge_event.dart';
import 'package:opencodebridge/client/events_client.dart';
import 'package:opencodebridge/model/session.dart';
import 'package:opencodebridge/ui/home_list_state.dart';

/// The home list's merged state (issue #266), tested flat: apply a fresh
/// read, apply an event, assert the state — no widget, no `setState`.

const _project = SessionProject(id: 'p1', name: 'app');

Session _row(
  String id, {
  int created = 100,
  String title = 'a session',
  bool active = false,
  bool pinned = false,
  bool archived = false,
  bool waiting = false,
}) => Session(
  id: id,
  title: title,
  project: _project,
  created: created,
  location: '/code/app',
  active: active,
  pinned: pinned,
  archived: archived,
  waiting: waiting,
);

/// One decoded event from the bridge's unified stream: a session-scoped
/// opencode event (a durable seq names the session) when [session] is set, a
/// bridge-native one (`data.sessionID`, no durable) when it is not.
BridgeEvent _ev(String type, {String? session, Map<String, Object?>? data}) =>
    BridgeEvent(
      id: 'evt_$type',
      created: 1,
      type: type,
      data: data ?? const <String, Object?>{},
      durable: session == null ? null : Durable(aggregateID: session, seq: 1),
    );

/// Runs the module's pure sort comparator (issue #268) over [rows] exactly
/// the way the module re-sorts: a (row, index) pair, the position looked up
/// from [positions] (a row absent from the map is *unknown* — the cold-start
/// case), and the current index as the stable tie-breaker. Returns the
/// resulting id order. [List.sort] is not stable, but the comparator returns
/// the index difference when everything else ties, so it is a total order and
/// the result is deterministic regardless of [List.sort]'s stability.
List<String> _orderOf(
  List<Session> rows, [
  Map<String, num> positions = const {},
]) {
  final indexed = [
    for (var i = 0; i < rows.length; i++) (row: rows[i], index: i),
  ];
  indexed.sort(
    (a, b) => HomeListState.homeListOrder(
      a.row,
      a.index,
      b.row,
      b.index,
      (id) => positions[id],
    ),
  );
  return [for (final entry in indexed) entry.row.id];
}

void main() {
  late HomeListState list;

  /// A cold start's read: newest-created first, the bridge's order.
  void readFresh() => list.applyRead([
    _row('ses_2', created: 300, title: 'newer'),
    _row('ses_1', created: 100),
  ]);

  setUp(() => list = HomeListState());

  group('a fresh read (applyRead)', () {
    test('owns the rows in the read\'s order, nothing selected or marked', () {
      readFresh();
      expect(list.rows?.map((s) => s.id).toList(), ['ses_2', 'ses_1']);
      expect(list.selected, isNull);
      expect(list.isUnread('ses_1'), isFalse);
    });

    test('refreshes the selected row in place and clears a mark for a row that '
        'left, keeping the surviving marks', () {
      readFresh();
      list.select(list.rows!.first); // ses_2
      list.endUnread('ses_1');
      // A re-read: ses_2 was renamed and ses_1 is gone (deleted).
      list.applyRead([
        _row('ses_2', created: 300, title: 'renamed'),
        _row('ses_3', created: 400, title: 'third'),
      ]);
      expect(list.selected?.id, 'ses_2');
      expect(list.selected?.title, 'renamed');
      expect(list.isUnread('ses_1'), isFalse); // Dropped with its row.
      list.endUnread('ses_3');
      list.applyRead([
        _row('ses_2', created: 300, title: 'renamed'),
        _row('ses_3', created: 400, title: 'third'),
      ]);
      expect(list.isUnread('ses_3'), isTrue); // Survives a re-read.
    });
  });

  group('a decoded event (applyEvent)', () {
    test('is a no-op before the first read', () {
      expect(list.rows, isNull);
      expect(
        list.applyEvent(_ev('session.renamed', session: 'ses_1')),
        ListStateVerdict.none,
      );
      expect(list.rows, isNull);
    });

    test('session.created reloads, even for a known id', () {
      readFresh();
      expect(
        list.applyEvent(_ev('session.created', session: 'ses_1')),
        ListStateVerdict.reload,
      );
      // The merge changed nothing: the fresh read carries the new row.
      expect(list.rows?.map((s) => s.id).toList(), ['ses_2', 'ses_1']);
    });

    test('session.created reloads for an unknown id, too', () {
      readFresh();
      expect(
        list.applyEvent(_ev('session.created', session: 'ses_9')),
        ListStateVerdict.reload,
      );
      // The merge changed nothing: the fresh read carries the new row.
      expect(list.rows?.map((s) => s.id).toList(), ['ses_2', 'ses_1']);
    });

    test('session.renamed patches the title in place, selection carried', () {
      readFresh();
      list.select(list.rows!.first); // ses_2
      expect(
        list.applyEvent(
          _ev('session.renamed', session: 'ses_2', data: {'title': 'new name'}),
        ),
        ListStateVerdict.none,
      );
      expect(list.rows!.where((s) => s.id == 'ses_2').first.title, 'new name');
      expect(list.selected?.title, 'new name');
    });

    test('a rename of an unknown session reloads (its create was missed)', () {
      readFresh();
      expect(
        list.applyEvent(_ev('session.renamed', session: 'ses_9')),
        ListStateVerdict.reload,
      );
    });

    test('session.deleted drops the row, its pin position and unread mark, and '
        'the selection when it shows the row', () {
      readFresh();
      list.select(list.rows!.first); // ses_2
      list.endUnread('ses_2');
      expect(
        list.applyEvent(_ev('session.deleted', session: 'ses_2')),
        ListStateVerdict.none,
      );
      expect(list.rows?.map((s) => s.id).toList(), ['ses_1']);
      expect(list.selected, isNull);
      expect(list.isUnread('ses_2'), isFalse);
    });

    test('the bridge-native session.closed drops a row the same way', () {
      readFresh();
      expect(
        list.applyEvent(
          _ev(BridgeEventType.sessionClosed, data: {'sessionID': 'ses_1'}),
        ),
        ListStateVerdict.none,
      );
      expect(list.rows?.map((s) => s.id).toList(), ['ses_2']);
    });

    test(
      'session.archived flips the archived fact in place; unarchived flips it '
      'back',
      () {
        readFresh();
        expect(
          list.applyEvent(
            _ev('session.archived', data: {'sessionID': 'ses_1'}),
          ),
          ListStateVerdict.none,
        );
        expect(list.rows!.where((s) => s.id == 'ses_1').first.archived, isTrue);
        expect(
          list.applyEvent(
            _ev('session.unarchived', data: {'sessionID': 'ses_1'}),
          ),
          ListStateVerdict.none,
        );
        expect(
          list.rows!.where((s) => s.id == 'ses_1').first.archived,
          isFalse,
        );
      },
    );

    test(
      'an archive of an unknown session reloads (its create was missed)',
      () {
        readFresh();
        expect(
          list.applyEvent(
            _ev('session.archived', data: {'sessionID': 'ses_9'}),
          ),
          ListStateVerdict.reload,
        );
      },
    );

    test('execution.started moves the active dot on in place and clears the '
        'unread mark', () {
      readFresh();
      list.endUnread('ses_1');
      expect(
        list.applyEvent(_ev('session.execution.started', session: 'ses_1')),
        ListStateVerdict.none,
      );
      expect(list.rows!.where((s) => s.id == 'ses_1').first.active, isTrue);
      expect(list.isUnread('ses_1'), isFalse);
    });

    test('a terminal moves the dot off and lights the unread mark when the row '
        'is not selected; on the selected row it does not', () {
      readFresh();
      list.select(list.rows!.first); // ses_2 is shown, ses_1 is not.
      for (final type in [
        'session.execution.succeeded',
        'session.execution.failed',
        'session.execution.interrupted',
      ]) {
        expect(
          list.applyEvent(_ev(type, session: 'ses_1')),
          ListStateVerdict.none,
        );
      }
      expect(list.rows!.where((s) => s.id == 'ses_1').first.active, isFalse);
      expect(list.isUnread('ses_1'), isTrue);
      expect(list.isUnread('ses_2'), isFalse); // Watched live: no mark.
    });

    test(
      'the bridge-native session.turn.cancelled goes the dot out in place and '
      'lights the mark like any other terminal',
      () {
        readFresh();
        expect(
          list.applyEvent(
            _ev(BridgeEventType.turnCancelled, data: {'sessionID': 'ses_1'}),
          ),
          ListStateVerdict.none,
        );
        expect(list.rows!.where((s) => s.id == 'ses_1').first.active, isFalse);
        expect(list.isUnread('ses_1'), isTrue);
      },
    );

    test('session.order.changed pins a known row in place and re-sorts '
        'pinned-first, by known position ascending', () {
      readFresh();
      // ses_1 (the older, currently-last row) is pinned first.
      expect(
        list.applyEvent(
          _ev(
            BridgeEventType.sessionOrderChanged,
            data: {'sessionID': 'ses_1', 'position': 1},
          ),
        ),
        ListStateVerdict.none,
      );
      expect(list.rows!.map((s) => s.id).toList(), ['ses_1', 'ses_2']);
      expect(list.rows!.first.pinned, isTrue);
      // ses_2 is pinned second: the position order is preserved.
      expect(
        list.applyEvent(
          _ev(
            BridgeEventType.sessionOrderChanged,
            data: {'sessionID': 'ses_2', 'position': 2},
          ),
        ),
        ListStateVerdict.none,
      );
      expect(list.rows!.map((s) => s.id).toList(), ['ses_1', 'ses_2']);
    });

    test('a re-echo of the same pin is a no-op: the order does not churn', () {
      readFresh();
      list.applyEvent(
        _ev(
          BridgeEventType.sessionOrderChanged,
          data: {'sessionID': 'ses_1', 'position': 1},
        ),
      );
      final before = list.rows!.map((s) => s.id).toList();
      expect(list.setOrder('ses_1', 1), isFalse); // Redundant echo.
      expect(list.rows!.map((s) => s.id).toList(), before);
    });

    test('an un-pin echoes the row back to its created-order place', () {
      readFresh();
      list.applyEvent(
        _ev(
          BridgeEventType.sessionOrderChanged,
          data: {'sessionID': 'ses_1', 'position': 1},
        ),
      );
      expect(list.rows!.map((s) => s.id).toList(), ['ses_1', 'ses_2']);
      expect(
        list.applyEvent(
          _ev(
            BridgeEventType.sessionOrderChanged,
            data: {'sessionID': 'ses_1', 'position': null},
          ),
        ),
        ListStateVerdict.none,
      );
      // Back to newest-created first: ses_2 (300) before ses_1 (100).
      expect(list.rows!.map((s) => s.id).toList(), ['ses_2', 'ses_1']);
      expect(list.rows!.last.pinned, isFalse);
    });

    test(
      'a malformed position reads as null (an un-pin, the safe default)',
      () {
        readFresh();
        list.applyEvent(
          _ev(
            BridgeEventType.sessionOrderChanged,
            data: {'sessionID': 'ses_1', 'position': 1},
          ),
        );
        expect(
          list.applyEvent(
            _ev(
              BridgeEventType.sessionOrderChanged,
              data: {'sessionID': 'ses_1', 'position': 'not-a-number'},
            ),
          ),
          ListStateVerdict.none,
        );
        expect(list.rows!.where((s) => s.id == 'ses_1').first.pinned, isFalse);
      },
    );

    test('an order change for an unknown session reloads (missed create)', () {
      readFresh();
      expect(
        list.applyEvent(
          _ev(
            BridgeEventType.sessionOrderChanged,
            data: {'sessionID': 'ses_9', 'position': 1},
          ),
        ),
        ListStateVerdict.reload,
      );
    });

    test('a pinned row whose position the list has not seen (a cold start\'s '
        'pinned field) keeps its place when a known position lands', () {
      // The bridge's read placed the cold-start pinned row first; the list
      // holds no position for it.
      list.applyRead([
        _row('ses_pin', created: 50, pinned: true),
        _row('ses_2', created: 300),
        _row('ses_1', created: 100),
      ]);
      expect(list.rows!.map((s) => s.id).toList(), [
        'ses_pin',
        'ses_2',
        'ses_1',
      ]);
      list.applyEvent(
        _ev(
          BridgeEventType.sessionOrderChanged,
          data: {'sessionID': 'ses_1', 'position': 1},
        ),
      );
      // ses_1 joins the pinned block; ses_pin (a position the list has not
      // seen) keeps its current place relative to it — the read's order,
      // the index tie-breaker — never dragged out of the block.
      expect(list.rows!.map((s) => s.id).toList(), [
        'ses_pin',
        'ses_1',
        'ses_2',
      ]);
    });

    test(
      'the permission and question events ask the caller to re-derive the '
      'waiting fact for a known row — including the form\'s nested session',
      () {
        readFresh();
        for (final type in [
          'permission.asked',
          'permission.replied',
          'form.created',
          'form.replied',
          'form.cancelled',
        ]) {
          expect(
            list.applyEvent(_ev(type, session: 'ses_1')),
            ListStateVerdict.reDeriveWaiting,
          );
        }
        // The form events name the session through `data.form.sessionID`.
        expect(
          list.applyEvent(
            _ev(
              'form.replied',
              data: {
                'form': {'sessionID': 'ses_1'},
              },
            ),
          ),
          ListStateVerdict.reDeriveWaiting,
        );
        // The lookup's result lands through the module's patch, with the
        // selection carried.
        list.select(list.rows!.first);
        list.patchRow('ses_1', waiting: true);
        expect(list.rows!.where((s) => s.id == 'ses_1').first.waiting, isTrue);
      },
    );

    test('a permission event for an unknown session reloads', () {
      readFresh();
      expect(
        list.applyEvent(_ev('permission.asked', data: {'sessionID': 'ses_9'})),
        ListStateVerdict.reload,
      );
    });

    test(
      'any other event: an unknown session reloads, a known one is a no-op',
      () {
        readFresh();
        expect(
          list.applyEvent(_ev('message.part.delta', session: 'ses_9')),
          ListStateVerdict.reload,
        );
        expect(
          list.applyEvent(_ev('message.part.delta', session: 'ses_1')),
          ListStateVerdict.none,
        );
      },
    );

    test(
      'sessionOf reads the durable id, then data.sessionID, then the form\'s '
      'nested session id, else null',
      () {
        expect(
          HomeListState.sessionOf(
            _ev('session.execution.started', session: 's1'),
          ),
          's1',
        );
        expect(
          HomeListState.sessionOf(
            _ev(BridgeEventType.turnCancelled, data: {'sessionID': 's2'}),
          ),
          's2',
        );
        expect(
          HomeListState.sessionOf(
            _ev(
              'form.replied',
              data: {
                'form': {'sessionID': 's3'},
              },
            ),
          ),
          's3',
        );
        expect(
          HomeListState.sessionOf(
            _ev(BridgeEventType.turnCancelled, data: const <String, Object?>{}),
          ),
          isNull,
        );
      },
    );
  });

  group('the merge the widget drives by hand', () {
    test('setOrder pins and re-sorts; answers whether the list changed '
        '(a no-op wastes neither a re-sort nor a build)', () {
      readFresh();
      expect(list.setOrder('ses_1', 1), isTrue);
      expect(list.rows!.map((s) => s.id).toList(), ['ses_1', 'ses_2']);
      expect(list.setOrder('ses_1', 1), isFalse); // The re-echo.
      expect(list.setOrder('ses_1', null), isTrue); // The un-pin.
      expect(list.rows!.map((s) => s.id).toList(), ['ses_2', 'ses_1']);
      expect(list.setOrder('ses_1', null), isFalse); // Already un-pinned.
      expect(list.setOrder('ses_9', 1), isFalse); // Not a row.
    });

    test('setOrder before the first read is a no-op; a delete drops the pin '
        'position with the row', () {
      expect(list.setOrder('ses_1', 1), isFalse);
      readFresh();
      list.setOrder('ses_1', 1);
      list.patchRow('ses_1', drop: true);
      expect(list.rows!.map((s) => s.id).toList(), ['ses_2']);
      expect(list.setOrder('ses_1', 1), isFalse); // The row is gone.
    });

    test('endUnread lights the mark only when the row is not the selected one; '
        'select clears it atomically with the selection', () {
      readFresh();
      list.select(list.rows!.first); // ses_2 is shown.
      list.endUnread('ses_2'); // Watched live: no mark.
      expect(list.isUnread('ses_2'), isFalse);
      list.endUnread('ses_1');
      expect(list.isUnread('ses_1'), isTrue);
      // Opening ses_1 in the detail pane clears its mark with the
      // selection.
      list.select(list.rows!.where((s) => s.id == 'ses_1').first);
      expect(list.isUnread('ses_1'), isFalse);
      expect(list.selected?.id, 'ses_1');
      list.select(null);
      expect(list.selected, isNull);
    });

    test(
      'patchRow carries a live patch onto the selection, drop clears it',
      () {
        readFresh();
        list.select(list.rows!.first); // ses_2
        list.patchRow('ses_2', title: 'renamed');
        expect(list.selected?.title, 'renamed');
        list.patchRow('ses_2', drop: true);
        expect(list.selected, isNull);
        expect(list.rows?.map((s) => s.id).toList(), ['ses_1']);
      },
    );
  });

  group('the sort comparator (issue #268, the pure comparator)', () {
    test('pinned rows sort before unpinned rows', () {
      final pinned = _row('ses_pin', created: 50, pinned: true);
      final unpinned = _row('ses_unpin', created: 300);
      // Even the much-older pinned row goes first (created is 300 vs 50).
      expect(_orderOf([unpinned, pinned], {'ses_pin': 1}), [
        'ses_pin',
        'ses_unpin',
      ]);
      expect(_orderOf([pinned, unpinned], {'ses_pin': 1}), [
        'ses_pin',
        'ses_unpin',
      ]);
    });

    test('both unpinned: newest-created first', () {
      expect(_orderOf([_row('a', created: 100), _row('b', created: 300)]), [
        'b',
        'a',
      ]);
      expect(_orderOf([_row('b', created: 300), _row('a', created: 100)]), [
        'b',
        'a',
      ]);
    });

    test('both unpinned: a created tie keeps the current order', () {
      expect(_orderOf([_row('a', created: 100), _row('b', created: 100)]), [
        'a',
        'b',
      ]);
      // The index is the tie-breaker, so the input order is preserved.
      expect(_orderOf([_row('b', created: 100), _row('a', created: 100)]), [
        'b',
        'a',
      ]);
    });

    test('both pinned with known positions: position ascending', () {
      final positions = {'a': 1, 'b': 2};
      expect(
        _orderOf([
          _row('a', created: 100, pinned: true),
          _row('b', created: 300, pinned: true),
        ], positions),
        ['a', 'b'],
      );
      // Position order wins over created order.
      expect(
        _orderOf([
          _row('b', created: 300, pinned: true),
          _row('a', created: 100, pinned: true),
        ], positions),
        ['a', 'b'],
      );
    });

    test('both pinned with known positions: a position tie breaks by newest-created', () {
      final positions = {'a': 1, 'b': 1};
      expect(
        _orderOf([
          _row('a', created: 100, pinned: true),
          _row('b', created: 300, pinned: true),
        ], positions),
        ['b', 'a'],
      );
      expect(
        _orderOf([
          _row('b', created: 300, pinned: true),
          _row('a', created: 100, pinned: true),
        ], positions),
        ['b', 'a'],
      );
    });

    test('both pinned with known positions: a position AND created tie keeps the current order', () {
      final positions = {'a': 1, 'b': 1};
      expect(
        _orderOf([
          _row('a', created: 100, pinned: true),
          _row('b', created: 100, pinned: true),
        ], positions),
        ['a', 'b'],
      );
      expect(
        _orderOf([
          _row('b', created: 100, pinned: true),
          _row('a', created: 100, pinned: true),
        ], positions),
        ['b', 'a'],
      );
    });

    test('a cold-start pinned row with an unknown position keeps its place '
        '(not dragged out of the block or re-sorted by created)', () {
      // ses_pin is pinned but the list holds no position for it (a cold start
      // the read placed in place); ses_a is pinned with a KNOWN position 1.
      // The pair keeps its CURRENT relative order (the index tie-breaker) —
      // ses_pin is not demoted to unpinned (it stays in the pinned block,
      // ahead of the known row here) nor re-sorted by created (300 vs 50
      // would put ses_a first). It simply holds the place the read gave it.
      final positions = {'ses_a': 1};
      expect(
        _orderOf([
          _row('ses_pin', created: 50, pinned: true), // unknown position, idx 0
          _row('ses_a', created: 300, pinned: true), // known position 1, idx 1
        ], positions),
        ['ses_pin', 'ses_a'],
      );
      // Reversed input: the pair again keeps its CURRENT order — now ses_a
      // is first, so it stays first. The unknown row keeps *its* place
      // (index 1), it is not jumped to the front.
      expect(
        _orderOf([
          _row('ses_a', created: 300, pinned: true), // known position 1, idx 0
          _row('ses_pin', created: 50, pinned: true), // unknown position, idx 1
        ], positions),
        ['ses_a', 'ses_pin'],
      );
    });

    test('one known position + one unknown: the pair keeps its current order '
        '(the app-specific rule, not the bridge\'s)', () {
      // The app-specific rule: when EITHER row's position is unknown, the
      // rows keep their CURRENT relative order (the index tie-breaker). This
      // is the difference from the bridge's `SessionsBackend.homeListOrder`,
      // which treats an unknown position as *unpinned* and would sort the
      // known-position row first (here, created 100 < 300, so the bridge
      // would put ses_known first in *both* directions). The app does not:
      // the unknown row holds the place the read gave it.
      final positions = {'ses_known': 5};
      // Currently: unknown first, known second → that order is kept.
      expect(
        _orderOf([
          _row('ses_unknown', created: 300, pinned: true),
          _row('ses_known', created: 100, pinned: true),
        ], positions),
        ['ses_unknown', 'ses_known'],
      );
      // Currently: known first, unknown second → that order is kept too (the
      // index, not the position, decides — position 5 never gets to rank).
      expect(
        _orderOf([
          _row('ses_known', created: 100, pinned: true),
          _row('ses_unknown', created: 300, pinned: true),
        ], positions),
        ['ses_known', 'ses_unknown'],
      );
    });

    test('a pinned row with a known position sorts before an unpinned row', () {
      final positions = {'ses_pin': 1};
      expect(
        _orderOf([
          _row('ses_unpin', created: 900),
          _row('ses_pin', created: 50, pinned: true),
        ], positions),
        ['ses_pin', 'ses_unpin'],
      );
    });
  });

  group('the reload coalescing state machine (issue #268)', () {
    test('a single request starts exactly one load', () {
      // requestReload → true (start the loop). The driver runs one load.
      expect(list.requestReload(), isTrue);
      // No events arrived during the load: drainReload → false, the loop ends.
      expect(list.drainReload(), isFalse);
      list.endReload();
      // The state is cleared: a later request starts fresh (not queued).
      expect(list.requestReload(), isTrue);
      list.endReload();
    });

    test(
      'a burst during an in-flight load collapses into exactly one extra load',
      () {
        // First request starts the loop.
        expect(list.requestReload(), isTrue);
        // A burst of reload-verdict events arrives while the load is in flight.
        expect(list.requestReload(), isFalse); // queued
        expect(list.requestReload(), isFalse); // queued (same wave)
        expect(list.requestReload(), isFalse); // queued (same wave)
        // The in-flight load lands: drainReload → true, exactly ONE extra load.
        expect(list.drainReload(), isTrue);
        // That extra load runs; nothing else was queued: drainReload → false.
        expect(list.drainReload(), isFalse);
        list.endReload();
        // Two loads total, not four.
      },
    );

    test('a burst during that extra load queues one more (wave by wave)', () {
      expect(list.requestReload(), isTrue); // load 1
      list.requestReload(); // burst → queued (load 2)
      expect(list.drainReload(), isTrue); // load 2 runs
      // A second burst arrives while load 2 is in flight → load 3.
      expect(list.requestReload(), isFalse); // queued
      expect(list.drainReload(), isTrue); // load 3 runs
      // Nothing else: the loop ends.
      expect(list.drainReload(), isFalse);
      list.endReload();
    });

    test('endReload clears both in-flight and pending (a clean exit)', () {
      expect(list.requestReload(), isTrue);
      expect(list.requestReload(), isFalse); // queued behind the in-flight one
      // The loop ends (the widget unmounted, say): endReload clears everything.
      list.endReload();
      // A later request starts fresh — it must NOT be queued behind the stale
      // in-flight flag, and the stale pending flag must not fire an extra load.
      expect(list.requestReload(), isTrue);
      expect(list.drainReload(), isFalse);
      list.endReload();
    });

    test(
      'an aborted loop still clears the state (the unmount mid-load race)',
      () {
        // Request starts a load; a burst is queued; the widget unmounts before the
        // load lands (its `mounted` guard breaks the loop). The driver's `finally`
        // still runs endReload.
        expect(list.requestReload(), isTrue);
        expect(list.requestReload(), isFalse); // queued
        list.endReload(); // aborted: the finally runs
        // The state is clean: no stale flag survives to the next session.
        expect(list.requestReload(), isTrue);
        list.endReload();
      },
    );
  });
}
