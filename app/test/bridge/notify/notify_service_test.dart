import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/notify/fcm_sender.dart';
import 'package:opencodebridge/bridge/notify/notify_service.dart';
import 'package:opencodebridge/notify/notify_kind.dart';

void main() {
  late _FakeSender sender;
  late NotifyService service;

  setUp(() {
    sender = _FakeSender();
    service = NotifyService(sender: sender);
  });

  test('registerDevice records the token and its enabled kinds', () {
    service.registerDevice('tok_a', {NotifyKind.turnEnded});
    expect(service.deviceCount, 1);
    expect(service.enabledKinds('tok_a'), {NotifyKind.turnEnded});
    expect(service.enabledKinds('tok_b'), isNull);
  });

  test('a re-registration replaces the kinds (the latest call wins)', () {
    service.registerDevice('tok_a', {NotifyKind.turnEnded});
    service.registerDevice('tok_a', {});
    expect(service.deviceCount, 1);
    expect(service.enabledKinds('tok_a'), isEmpty);
  });

  test('publish reaches only the devices that have the kind enabled', () async {
    service.registerDevice('tok_a', {NotifyKind.turnEnded});
    service.registerDevice('tok_b', {
      NotifyKind.permissionAsked,
      NotifyKind.turnEnded,
    });
    service.registerDevice('tok_c', {});

    final sent = await service.publish(
      NotifyKind.turnEnded,
      title: 'Turn finished',
      body: 'one',
      link: 'opencodebridge://session/ses_1',
    );
    expect(sent, 2);
    expect(sender.sent.map((s) => s.token), ['tok_a', 'tok_b']);
    expect(
      sender.sent.every(
        (s) =>
            s.title == 'Turn finished' &&
            s.body == 'one' &&
            s.link == 'opencodebridge://session/ses_1',
      ),
      isTrue,
    );
  });

  test('a delivery failure on one device does not stop the rest', () async {
    service.registerDevice('tok_a', {NotifyKind.turnEnded});
    service.registerDevice('tok_b', {NotifyKind.turnEnded});
    service.registerDevice('tok_c', {NotifyKind.turnEnded});
    sender.failTokens.add('tok_b');

    final sent = await service.publish(
      NotifyKind.turnEnded,
      title: 'Turn finished',
      body: 'one',
      link: 'opencodebridge://session/ses_1',
    );
    // The middle device's failed plan does not stop the rest: the other two
    // land, and only the landings are counted (issue #261, acceptance #2).
    expect(sent, 2);
    expect(sender.sent.map((s) => s.token), ['tok_a', 'tok_c']);
  });

  test('a failed device is not re-attempted within the call (fire-and-forget)', () async {
    service.registerDevice('tok_a', {NotifyKind.turnEnded});
    service.registerDevice('tok_b', {NotifyKind.turnEnded});
    sender.failTokens.add('tok_a');

    final sent = await service.publish(
      NotifyKind.turnEnded,
      title: 'Turn finished',
      body: 'one',
      link: 'opencodebridge://session/ses_1',
    );

    // Each eligible device's push is one non-durable single-primary plan,
    // attempted once (issue #261, acceptance #1): the policy — not the service
    // — decides the retry, and a non-durable primary is not retried. tok_a's
    // send was attempted exactly once (it failed and dropped off the books);
    // tok_b's exactly once (it landed).
    expect(sent, 1);
    expect(sender.attempts['tok_a'], 1);
    expect(sender.attempts['tok_b'], 1);
    expect(sender.sent.map((s) => s.token), ['tok_b']);
  });

  test(
    'a later publish re-delivers to the same device (a fresh plan per event)',
    () async {
      service.registerDevice('tok_a', {NotifyKind.turnEnded});
      service.registerDevice('tok_b', {NotifyKind.turnEnded});
      sender.failTokens.add('tok_a');

      // First event: tok_a fails (attempted once, not retried), tok_b lands.
      var sent = await service.publish(
        NotifyKind.turnEnded,
        title: 'Turn finished',
        body: 'one',
        link: 'opencodebridge://session/ses_1',
      );
      expect(sent, 1);
      expect(sender.attempts['tok_a'], 1);
      expect(sender.attempts['tok_b'], 1);

      // tok_a recovers between events, and a later publish re-delivers to it:
      // nothing is owed across events (the **owed** decision is per delivery,
      // not per event), so a fresh plan is built for every eligible device on
      // the next event — tok_a is not remembered as failed and quietly skipped.
      sender.failTokens.remove('tok_a');
      sent = await service.publish(
        NotifyKind.turnEnded,
        title: 'Turn finished',
        body: 'two',
        link: 'opencodebridge://session/ses_1',
      );
      // Both devices land on the second event: the previously-failed tok_a is
      // re-delivered (it now lands) and tok_b is delivered again.
      expect(sent, 2);
      // Each device's plan is fresh per event: tok_a was attempted in both
      // events (the second attempt lands), tok_b in both.
      expect(sender.attempts['tok_a'], 2);
      expect(sender.attempts['tok_b'], 2);
      expect(sender.sent.map((s) => s.token), ['tok_b', 'tok_a', 'tok_b']);
    },
  );

  test('a kind no one has enabled sends nothing', () async {
    service.registerDevice('tok_a', {NotifyKind.turnEnded});
    final sent = await service.publish(
      NotifyKind.dockerContainer,
      title: 'Container stopped',
      body: 'postgres',
      link: 'opencodebridge://container/postgres',
    );
    expect(sent, 0);
    expect(sender.sent, isEmpty);
  });

  test('close() releases the sender', () async {
    await service.close();
    expect(sender.closed, isTrue);
  });
}

class _FakeSender extends FcmSender {
  final sent = <_Sent>[];

  /// token → how many sends were attempted (landed or not): the test's read of
  /// "was this device re-attempted" (issue #261, acceptance #1).
  final Map<String, int> attempts = {};
  final failTokens = <String>{};
  var closed = false;

  @override
  Future<void> send({
    required String token,
    required String title,
    required String body,
    required String link,
  }) async {
    attempts.update(token, (n) => n + 1, ifAbsent: () => 1);
    if (failTokens.contains(token)) throw StateError('delivery failed');
    sent.add(_Sent(token, title, body, link));
  }

  @override
  Future<void> close() async => closed = true;
}

class _Sent {
  const _Sent(this.token, this.title, this.body, this.link);

  final String token;
  final String title;
  final String body;
  final String link;
}
