import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/events/bridge_event.dart';
import 'package:opencodebridge/bridge/events/event_hub.dart';
import 'package:opencodebridge/bridge/events/opencode_event_service.dart';
import 'package:opencodebridge/bridge/sessions/order_cleanup.dart';
import 'package:opencodebridge/bridge/sessions/order_store.dart';

/// The bridge's order-store cleanup listener (issue #292): the entry of a
/// session the bridge observes being deleted or closed is removed from the
/// order store on the event — the replacement for the read-time prune that
/// dropped the pin of every session invisible on one read.
void main() {
  // A session-scoped opencode event (a durable seq names the session).
  String ev(
    String type, {
    String session = 'ses_1',
    Map<String, Object?>? data,
  }) => jsonEncode({
    'id': 'evt_$type',
    'type': type,
    'data': data ?? const <String, Object?>{},
    'durable': {'aggregateID': session, 'seq': 1, 'version': 1},
  });

  late Directory dir;
  late File file;
  late SessionOrderStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('oc-order-cleanup');
    file = File('${dir.path}/session-order.json');
    store = SessionOrderStore(file: file);
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('a session.deleted (durable aggregateID) clears the entry', () async {
    await store.set('ses_1', 0);
    final cleanup = OrderStoreCleanup(store: store);
    await cleanup.write(ev('session.deleted'));
    expect(store.load(), isEmpty);
    expect(file.existsSync(), isFalse, reason: 'the emptied store is removed');
  });

  test(
    'a bridge-native session.closed (data.sessionID) clears the entry',
    () async {
      await store.set('ses_1', 0);
      final cleanup = OrderStoreCleanup(store: store);
      await cleanup.write(
        bridgeEvent(
          type: BridgeEventType.sessionClosed,
          data: {'sessionID': 'ses_1'},
        ),
      );
      expect(store.load(), isEmpty);
    },
  );

  test('the durable aggregate id wins over data.sessionID', () async {
    await store.set('ses_1', 0);
    final cleanup = OrderStoreCleanup(store: store);
    // Both names are present and disagree: the durable id is the
    // authoritative session identity (the same read as the turn tracker's).
    await cleanup.write(
      ev('session.deleted', data: {'sessionID': 'ses_other'}),
    );
    expect(store.load(), isEmpty, reason: 'ses_1 was cleared, not ses_other');
  });

  test('keeps the other sessions\' entries', () async {
    await store.set('ses_1', 0);
    await store.set('ses_2', 1);
    final cleanup = OrderStoreCleanup(store: store);
    await cleanup.write(ev('session.deleted', session: 'ses_1'));
    expect(store.load(), {'ses_2': 1});
  });

  test('is a no-op for an id with no entry', () async {
    await store.set('ses_1', 0);
    final cleanup = OrderStoreCleanup(store: store);
    await cleanup.write(ev('session.deleted', session: 'ses_unknown'));
    expect(store.load(), {'ses_1': 0});
  });

  test(
    'ignores other event types and a deleted frame that names no session',
    () async {
      await store.set('ses_1', 0);
      final cleanup = OrderStoreCleanup(store: store);
      await cleanup.write(ev('session.created'));
      await cleanup.write(ev('session.renamed'));
      await cleanup.write(ev('session.archived'));
      await cleanup.write(
        jsonEncode({
          'id': 'evt_nose',
          'type': 'session.deleted',
          'data': const <String, Object?>{},
        }),
      );
      expect(store.load(), {'ses_1': 0});
    },
  );

  test('a malformed payload is ignored, never a throw', () async {
    await store.set('ses_1', 0);
    final cleanup = OrderStoreCleanup(store: store);
    await cleanup.write('not json at all');
    await cleanup.write('[1, 2, 3]');
    await cleanup.write(jsonEncode({'type': 7}));
    await cleanup.write(jsonEncode({'data': 'nope'}));
    expect(store.load(), {'ses_1': 0});
  });

  test('close() completes done (the hub can drop the connection)', () async {
    final cleanup = OrderStoreCleanup(store: store);
    var done = false;
    unawaited(cleanup.done.then((_) => done = true));
    await cleanup.close();
    await Future<void>.delayed(Duration.zero);
    expect(done, isTrue, reason: 'the done future completes on close');
  });

  test('attached to the hub it cleans off the fanned-out stream', () async {
    await store.set('ses_1', 0);
    final upstream = _FakeUpstream();
    final hub = EventHub(service: upstream);
    final cleanup = OrderStoreCleanup(store: store);
    hub.add(cleanup);
    upstream.add(
      OpencodeEvent(raw: ev('session.deleted'), type: 'session.deleted'),
    );
    await _until(() => store.load().isEmpty);
    expect(file.existsSync(), isFalse);
    hub.emit(
      bridgeEvent(
        type: BridgeEventType.sessionClosed,
        data: {'sessionID': 'ses_1'},
      ),
    );
    await hub.close();
  });
}

class _FakeUpstream implements OpencodeEventService {
  final StreamController<OpencodeEvent> controller =
      StreamController<OpencodeEvent>.broadcast();
  void add(OpencodeEvent event) => controller.add(event);
  @override
  Stream<OpencodeEvent> get events => controller.stream;
  @override
  Future<void> close() async {}
}

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for the entry to be cleaned');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
