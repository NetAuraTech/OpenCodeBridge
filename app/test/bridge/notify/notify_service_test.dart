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
    sender.failTokens.add('tok_a');

    final sent = await service.publish(
      NotifyKind.turnEnded,
      title: 'Turn finished',
      body: 'one',
      link: 'opencodebridge://session/ses_1',
    );
    expect(sent, 1);
    expect(sender.sent.map((s) => s.token), ['tok_b']);
  });

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
  final failTokens = <String>{};
  var closed = false;

  @override
  Future<void> send({
    required String token,
    required String title,
    required String body,
    required String link,
  }) async {
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
