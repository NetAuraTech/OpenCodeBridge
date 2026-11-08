import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/docker/docker_backend.dart';
import 'package:opencodebridge/bridge/events/composite_event_service.dart';
import 'package:opencodebridge/bridge/events/opencode_event_service.dart';
import 'package:opencodebridge/model/orb.dart';

/// A scripted [OpencodeEventService]: an emittable broadcast stream plus a
/// [closed] flag (close semantics).
class FakeEventService implements OpencodeEventService {
  FakeEventService()
    : _controller = StreamController<OpencodeEvent>.broadcast();

  final StreamController<OpencodeEvent> _controller;
  bool closed = false;

  /// Whether a listener (the composite's subscription) is attached.
  bool get hasListener => _controller.hasListener;

  void emit(OpencodeEvent event) {
    if (!_controller.isClosed) _controller.add(event);
  }

  @override
  Stream<OpencodeEvent> get events => _controller.stream;

  @override
  Future<void> close() async {
    closed = true;
    await _controller.close();
  }
}

OpencodeEvent event(String type, {String? aggregateID, int? seq}) =>
    OpencodeEvent(
      raw: '{"type":"$type"}',
      type: type,
      aggregateID: aggregateID,
      seq: seq,
    );

OrbRecord runningOrb(String id, {String url = 'http://127.0.0.1:41234'}) =>
    OrbRecord(
      id: id,
      name: 'n-$id',
      project: 'proj',
      branch: 'orb/$id',
      state: 'running',
      created: '2026-01-01T00:00:00Z',
      url: url,
    );

CompositeOpencodeEventService makeComposite({
  required FakeEventService host,
  Future<List<OrbRecord>> Function()? orbs,
  Future<String?> Function(String)? passwords,
  Map<String, FakeEventService>? upstreams,
  Duration? bootRetryInterval,
}) {
  final upstreamMap = upstreams ?? const {};
  return CompositeOpencodeEventService(
    host: host,
    orbList: orbs ?? () async => const [],
    orbPassword: passwords ?? ((_) async => null),
    upstreamFactory: (baseUrl, password) {
      final fake = upstreamMap['$baseUrl|$password'];
      if (fake == null) {
        throw StateError('no scripted upstream for $baseUrl|$password');
      }
      return fake;
    },
    refreshInterval: const Duration(milliseconds: 5),
    bootRetryInterval: bootRetryInterval ?? const Duration(milliseconds: 5),
  );
}

Future<void> _until(
  bool Function() condition, {
  String message = 'condition',
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $message');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('CompositeOpencodeEventService', () {
    test('host events pass through raw (no envelope)', () async {
      final host = FakeEventService();
      final composite = makeComposite(host: host);
      final seen = <OpencodeEvent>[];
      final subscription = composite.events.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      host.emit(event('session.idle', aggregateID: 'ses_host'));

      await _until(() => seen.length == 1, message: 'expected the host event');
      expect(seen.single.type, 'session.idle');
      expect(
        seen.single.raw,
        '{"type":"session.idle"}',
        reason: 'raw must pass through verbatim',
      );
      await subscription.cancel();
      await composite.close();
    });

    test('a running orb gets an upstream; its events flow', () async {
      final host = FakeEventService();
      final orb1 = FakeEventService();
      final composite = makeComposite(
        host: host,
        orbs: () async => [runningOrb('orb1')],
        passwords: (_) async => 'pw1',
        upstreams: {'http://127.0.0.1:41234|pw1': orb1},
      );
      final seen = <OpencodeEvent>[];
      final subscription = composite.events.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      orb1.emit(event('session.idle', aggregateID: 'ses_orb'));

      await _until(() => seen.length == 1, message: 'expected the orb event');
      expect(seen.single.raw, '{"type":"session.idle"}');
      await subscription.cancel();
      await composite.close();
    });

    test('a newly started orb is picked up on the next refresh', () async {
      final host = FakeEventService();
      final orb1 = FakeEventService();
      final orbs = <OrbRecord>[]; // nothing running at first
      final composite = makeComposite(
        host: host,
        orbs: () async => orbs,
        passwords: (_) async => 'pw1',
        upstreams: {'http://127.0.0.1:41234|pw1': orb1},
      );
      final seen = <OpencodeEvent>[];
      final subscription = composite.events.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The orb starts: the periodic refresh adds its upstream.
      orbs.add(runningOrb('orb1'));
      await _until(
        () => orb1.hasListener,
        message: 'the orb upstream to subscribe',
      );
      orb1.emit(event('session.idle', aggregateID: 'ses_orb'));

      await _until(
        () => seen.length == 1,
        message: 'expected the late orb event',
      );
      await subscription.cancel();
      await composite.close();
    });

    test('a stopped orb closes its upstream', () async {
      final host = FakeEventService();
      final orb1 = FakeEventService();
      final orbs = [runningOrb('orb1')];
      final composite = makeComposite(
        host: host,
        orbs: () async => orbs,
        passwords: (_) async => 'pw1',
        upstreams: {'http://127.0.0.1:41234|pw1': orb1},
      );
      final subscription = composite.events.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(orb1.closed, isFalse);

      orbs.clear(); // the orb stops

      await _until(
        () => orb1.closed,
        message: 'expected the upstream to close',
      );
      await subscription.cancel();
      await composite.close();
    });

    test(
      'a password rotation closes the old upstream and opens the new one',
      () async {
        final host = FakeEventService();
        final orb1a = FakeEventService();
        final orb1b = FakeEventService();
        String password = 'pw1';
        final composite = makeComposite(
          host: host,
          orbs: () async => [runningOrb('orb1')],
          passwords: (_) async => password,
          upstreams: {
            'http://127.0.0.1:41234|pw1': orb1a,
            'http://127.0.0.1:41234|pw2': orb1b,
          },
        );
        final seen = <OpencodeEvent>[];
        final subscription = composite.events.listen(seen.add);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // The orb respawns: new password.
        password = 'pw2';
        await _until(
          () => orb1b.hasListener,
          message: 'the rotated upstream to subscribe',
        );
        orb1b.emit(event('session.idle', aggregateID: 'ses_orb'));

        await _until(
          () => orb1a.closed && seen.length == 1,
          message: 'expected the rotated upstream to take over',
        );
        expect(seen.single.raw, '{"type":"session.idle"}');
        await subscription.cancel();
        await composite.close();
      },
    );

    test(
      'an orb still booting (no password yet) is attached shortly after '
      'its log line lands, without waiting for the next full refresh',
      () async {
        final host = FakeEventService();
        final orb1 = FakeEventService();
        final password = <String?>[null]; // Running, no `server password` yet.
        final composite = CompositeOpencodeEventService(
          host: host,
          orbList: () async => [runningOrb('orb1')],
          orbPassword: (_) async => password.single,
          upstreamFactory: (baseUrl, _) => orb1,
          // A full pass so rare the boot retry is the only thing that can
          // attach the orb within this
          refreshInterval: const Duration(seconds: 30),
          bootRetryInterval: const Duration(milliseconds: 5),
        );
        final seen = <OpencodeEvent>[];
        final subscription = composite.events.listen(seen.add);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(orb1.hasListener, isFalse);

        // The orb finishes booting: the log now carries its password.
        password[0] = 'pw1';
        await _until(
          () => orb1.hasListener,
          message: 'the boot retry to attach the orb upstream',
        );

        orb1.emit(event('session.created', aggregateID: 'ses_orb'));
        await _until(() => seen.isNotEmpty, message: 'the orb event');
        expect(seen.single.aggregateID, 'ses_orb');
        await subscription.cancel();
        await composite.close();
      },
    );

    test('an orb-list failure keeps the host flowing', () async {
      final host = FakeEventService();
      final composite = makeComposite(
        host: host,
        orbs: () async => throw const DockerUnavailableError('docker down'),
      );
      final seen = <OpencodeEvent>[];
      final subscription = composite.events.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      host.emit(event('session.idle', aggregateID: 'ses_host'));

      await _until(
        () => seen.length == 1,
        message: 'expected the host event after the orb-list failure',
      );
      await subscription.cancel();
      await composite.close();
    });

    test(
      'close() closes the host, every upstream, and completes the stream',
      () async {
        final host = FakeEventService();
        final orb1 = FakeEventService();
        final composite = makeComposite(
          host: host,
          orbs: () async => [runningOrb('orb1')],
          passwords: (_) async => 'pw1',
          upstreams: {'http://127.0.0.1:41234|pw1': orb1},
        );
        var done = false;
        final subscription = composite.events.listen(
          (_) {},
          onDone: () => done = true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        await composite.close();

        expect(host.closed, isTrue);
        expect(orb1.closed, isTrue);
        expect(done, isTrue, reason: 'the events stream completes on close');
        await subscription.cancel();
      },
    );

    test(
      'the default factory wires a real SSE upstream: orb events flow',
      () async {
        const password = 'orb-secret';
        final server = await HttpServer.bind('127.0.0.1', 0);
        final base = Uri.parse('http://127.0.0.1:${server.port}/');
        var connections = 0;
        String? lastAuth;
        server.listen((req) async {
          final resp = req.response;
          if (req.uri.path != '/api/event') {
            resp.statusCode = HttpStatus.notFound;
            await resp.close();
            return;
          }
          lastAuth = req.headers.value(HttpHeaders.authorizationHeader);
          ++connections;
          resp.headers.contentType = ContentType.parse('text/event-stream');
          resp.bufferOutput = false;
          resp.write(
            'data: {"type":"session.idle","durable":{"aggregateID":"ses_orb","seq":1,"version":1}}\n\n',
          );
          await resp.done; // Hold until the client disconnects.
        });

        final composite = CompositeOpencodeEventService(
          host: FakeEventService(),
          orbList: () async => [runningOrb('orb1', url: base.toString())],
          orbPassword: (_) async => password,
          refreshInterval: const Duration(milliseconds: 5),
        );
        final seen = <OpencodeEvent>[];
        final subscription = composite.events.listen(seen.add);
        await _until(
          () => seen.length == 1,
          message: 'expected the real orb event',
        );
        expect(seen.single.type, 'session.idle');
        expect(seen.single.aggregateID, 'ses_orb');
        expect(
          lastAuth,
          'Basic ${base64Encode(utf8.encode('opencode:$password'))}',
          reason: 'the orb upstream authenticates as opencode:<password>',
        );
        expect(connections, greaterThanOrEqualTo(1));
        await subscription.cancel();
        await composite.close();
        await server.close(force: true);
      },
    );
  });
}
