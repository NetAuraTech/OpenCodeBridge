import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/client/events_client.dart';
import 'package:opencodebridge/sound/session_sound.dart';

import 'session_sound_mapper_test.dart'
    show bridge, formCreated, opencode, permissionAsked;

/// A scripted [EventSource] (no real SSE connection): the events are
/// emitted through [emit].
class _FakeEventsSource implements EventSource {
  final _controller = StreamController<BridgeEvent>.broadcast();
  final _gaps = StreamController<SessionGap>.broadcast();

  @override
  Stream<BridgeEvent> get events => _controller.stream;

  @override
  Stream<SessionGap> get gaps => _gaps.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {
    await _controller.close();
    await _gaps.close();
  }

  @override
  Future<void> reconnect() async {}

  void emit(BridgeEvent event) => _controller.add(event);
}

void main() {
  late _FakeEventsSource source;
  late List<Uint8List> played;
  late Map<String, Uint8List?> assets;
  late bool enabled;
  late SessionSoundService service;

  setUp(() {
    source = _FakeEventsSource();
    played = [];
    // The real bundled bytes: whatever is on disk (empty in a bare test
    // environment is fine — the asset seam is the point).
    assets = {
      for (final sound in SessionSound.values)
        sound.assetPath: Uint8List.fromList([0x44, 0x49, 0x52, 0x41]),
    };
    enabled = true;
    service = SessionSoundService(
      play: (wav) async {
        played.add(wav);
        return 0;
      },
      asset: (path) async => assets[path],
      platform: () => defaultTargetPlatform,
      enabled: () => enabled,
    );
  });

  tearDown(() async {
    await service.detach();
  });

  /// Emits [event] and lets the (async) listener settle.
  Future<void> emit(BridgeEvent event) async {
    source.emit(event);
    await pumpEventQueue();
  }

  group('the platform gate', () {
    test('every trigger event sounds on desktop (Linux)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await service.attach(source);

      await emit(opencode('session.execution.succeeded'));
      await emit(opencode('session.execution.failed'));
      // The cancelled turn: the cancel and its follow-on terminal arrive in
      // order; only the cancel sounds.
      await emit(bridge('session.turn.cancelled'));
      await emit(opencode('session.execution.interrupted'));
      await emit(permissionAsked());
      await emit(formCreated());

      expect(
        played,
        // success, error, stopped (once), attention, attention: the
        // cancel's follow-on terminal is suppressed (issue #164).
        hasLength(5),
      );
    });

    test('every trigger event is silent on Android', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await service.attach(source);

      await emit(opencode('session.execution.succeeded'));
      await emit(opencode('session.execution.failed'));
      await emit(opencode('session.execution.interrupted'));
      await emit(bridge('session.turn.cancelled'));
      await emit(opencode('session.execution.interrupted'));
      await emit(permissionAsked());
      await emit(formCreated());

      expect(played, isEmpty);
    });

    test(
      'the gate is read per event: a live switch to Android silences',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await service.attach(source);

        await emit(opencode('session.execution.succeeded'));
        expect(played, hasLength(1));

        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await emit(opencode('session.execution.succeeded'));
        expect(played, hasLength(1));
      },
    );
  });

  group('the settings toggle', () {
    test('off is silent for every event', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      enabled = false;
      await service.attach(source);

      await emit(opencode('session.execution.succeeded'));
      await emit(opencode('session.execution.failed'));
      await emit(permissionAsked());
      await emit(formCreated());

      expect(played, isEmpty);
    });

    test('the toggle is read per event: a live change applies', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await service.attach(source);

      enabled = false;
      await emit(opencode('session.execution.succeeded'));
      expect(played, isEmpty);

      enabled = true;
      await emit(opencode('session.execution.succeeded'));
      expect(played, hasLength(1));
    });
  });

  group('the event → asset mapping', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
    });

    test('each tone loads its own bundled asset', () async {
      await service.attach(source);

      await emit(opencode('session.execution.succeeded'));
      await emit(opencode('session.execution.failed'));
      await emit(bridge('session.turn.cancelled'));
      await emit(opencode('session.execution.interrupted')); // suppressed
      await emit(permissionAsked());
      await emit(formCreated());

      expect(played.map((b) => b.buffer.asUint8List()), [
        // success, error, stopped (once — the follow-on is suppressed),
        // attention, attention.
        assets[SessionSound.success.assetPath]!.buffer.asUint8List(),
        assets[SessionSound.error.assetPath]!.buffer.asUint8List(),
        assets[SessionSound.stopped.assetPath]!.buffer.asUint8List(),
        assets[SessionSound.attention.assetPath]!.buffer.asUint8List(),
        assets[SessionSound.attention.assetPath]!.buffer.asUint8List(),
      ], reason: 'each play carries the mapped asset');
    });

    test('a missing asset is silent (no play, no throw)', () async {
      assets[SessionSound.error.assetPath] = null;
      await service.attach(source);

      await emit(opencode('session.execution.failed'));
      expect(played, isEmpty);
    });

    test('a failing play does not break later sounds', () async {
      var calls = 0;
      service = SessionSoundService(
        play: (wav) async {
          calls++;
          if (calls == 1) throw StateError('no sound device');
          played.add(wav);
          return 0;
        },
        asset: (path) async => assets[path],
        platform: () => defaultTargetPlatform,
        enabled: () => enabled,
      );
      await service.attach(source);

      await emit(opencode('session.execution.succeeded'));
      expect(played, isEmpty);
      await emit(opencode('session.execution.failed'));
      expect(played, hasLength(1));
    });

    test('a cancelled turn sounds the stopped asset exactly once', () async {
      await service.attach(source);

      await emit(bridge('session.turn.cancelled'));
      await emit(opencode('session.execution.interrupted'));
      expect(played, hasLength(1));
      expect(
        played.single.buffer.asUint8List(),
        equals(assets[SessionSound.stopped.assetPath]!.buffer.asUint8List()),
      );
    });
  });

  group('attach / detach', () {
    test('attach is idempotent per source (no double play)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await service.attach(source);
      await service.attach(source);

      await emit(opencode('session.execution.succeeded'));
      expect(played, hasLength(1));
    });

    test('detach silences; a fresh attach sounds again', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await service.attach(source);
      await service.detach();

      await emit(opencode('session.execution.succeeded'));
      expect(played, isEmpty);

      await service.attach(source);
      await emit(opencode('session.execution.succeeded'));
      expect(played, hasLength(1));
    });
  });
}
