import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/notify/delivery_policy.dart';

/// The delivery-policy module (issue #259, step D1): the named decisions —
/// **owed**, **once-sent**, **durable**, **primary-vs-fallback** — driven
/// through a fake sender (a scripted [ChannelSender]): retry-until-lands,
/// never-re-push, exactly-once, durable across a restart, and the
/// fire-and-forget posture as one named policy.
void main() {
  late DeliveryChannel primary;
  late DeliveryChannel fallback;

  setUp(() {
    primary = const DeliveryChannel(ChannelRole.primary, name: 'injection');
    fallback = const DeliveryChannel(ChannelRole.fallback, name: 'push');
  });

  group('the named decisions', () {
    test('owed: a fresh delivery is owed, and stops being owed when it '
        'lands', () async {
      final plan = DeliveryPlan(
        channels: [primary, fallback],
        send: alwaysLands,
      );
      expect(plan.isOwed, isTrue);
      expect(plan.state, const DeliveryState(owed: true, fallbackSent: false));

      final attempt = await plan.attempt();
      // The primary landed on the first try: the delivery is no longer owed.
      expect(plan.isOwed, isFalse);
      expect(attempt.sends, hasLength(1));
      expect(attempt.sends.single.channel, primary);
      // And a further opportunity does nothing (the "do nothing" decision is
      // explicit, not the absence of a call the producer forgot to make).
      expect((await plan.attempt()).isEmpty, isTrue);
    });

    test('primary-vs-fallback: the primary is attempted before the fallback, '
        'and the fallback is owed only on the primary failure', () async {
      final sender = _FakeSender(
        script: {
          primary: [SendOutcome.failed],
          fallback: [SendOutcome.landed],
        },
      );
      final plan = DeliveryPlan(
        channels: [primary, fallback],
        send: sender.send,
      );

      final attempt = await plan.attempt();
      // The first opportunity attempts the primary first, and — it failed —
      // the armed fallback goes out in the same pass.
      expect(attempt.sends.map((s) => s.channel), [primary, fallback]);

      // The fallback went out, so the next opportunity is the primary alone
      // (the retry).
      final retry = await plan.attempt();
      expect(retry.sends.map((s) => s.channel), [primary]);
    });

    test(
      'retry-until-lands: a durable primary is retried until it lands',
      () async {
        final sender = _FakeSender(
          script: {
            primary: [
              SendOutcome.failed,
              SendOutcome.failed,
              SendOutcome.landed,
            ],
          },
        );
        final plan = DeliveryPlan(
          channels: [primary, fallback],
          send: sender.send,
        );

        // The producer's retry loop (the settle, then each watcher pass):
        // attempt while owed.
        var pass = 0;
        while (plan.isOwed && pass < 10) {
          await plan.attempt();
          pass++;
        }

        // Three attempts (two failures, the landing one) — the delivery lands,
        // and the delivery stops being owed.
        expect(pass, 3);
        expect(plan.isOwed, isFalse);
        expect(sender.callsTo(primary), 3);
        // The push went out exactly once (the first failure), never more.
        expect(sender.callsTo(fallback), 1);
      },
    );

    test(
      'never-re-push: the fallback fires once and is never re-sent',
      () async {
        final sender = _FakeSender(
          script: {
            primary: const [SendOutcome.failed], // the caller stays unreachable
          },
        );
        final plan = DeliveryPlan(
          channels: [primary, fallback],
          send: sender.send,
        );

        // The primary never lands, so the delivery stays owed and is retried
        // pass after pass — the push is not among them.
        for (var pass = 0; pass < 5 && plan.isOwed; pass++) {
          await plan.attempt();
        }

        expect(plan.isOwed, isTrue); // still owed: the retry continues …
        expect(sender.callsTo(primary), 5); // … the primary is retried …
        expect(sender.callsTo(fallback), 1); // … and the push is not re-sent.
        expect(plan.fallbackSent, isTrue);
      },
    );

    test(
      'exactly-once: a delivery that lands is sent once, never again',
      () async {
        final sender = _FakeSender(
          script: {
            primary: [SendOutcome.landed],
          },
        );
        final plan = DeliveryPlan(
          channels: [primary, fallback],
          send: sender.send,
        );

        await plan.attempt();
        expect(sender.callsTo(primary), 1);
        expect(sender.callsTo(fallback), 0);

        // Not owed anymore: no further opportunity re-sends anything.
        for (var pass = 0; pass < 3; pass++) {
          final attempt = await plan.attempt();
          expect(attempt.isEmpty, isTrue);
        }
        expect(sender.callsTo(primary), 1);
        expect(sender.callsTo(fallback), 0);
      },
    );

    test('the fallback is sent once even when it itself fails (never '
        're-pushed)', () async {
      final sender = _FakeSender(
        script: {
          primary: const [SendOutcome.failed],
          fallback: const [SendOutcome.failed],
        },
      );
      final plan = DeliveryPlan(
        channels: [primary, fallback],
        send: sender.send,
      );

      await plan.attempt();
      await plan.attempt();
      // The push failed — the in-app retry keeps owning the delivery, and the
      // push is not re-sent (best-effort out-of-band, once).
      expect(sender.callsTo(fallback), 1);
      expect(plan.fallbackSent, isTrue);
      expect(plan.isOwed, isTrue);
    });

    test('durable: a not-yet-landed delivery is owed across a restart, and '
        'the once-sent fallback is not re-sent by the restore', () async {
      final sender = _FakeSender(
        script: {
          primary: const [SendOutcome.failed],
        },
      );
      final plan = DeliveryPlan(
        channels: [primary, fallback],
        send: sender.send,
      );
      await plan.attempt();
      // Settled with the injection failed: owed, and the push went out once.
      expect(plan.state, const DeliveryState(owed: true, fallbackSent: true));

      // The bridge restarts (the producer persists the state with the task
      // record and restores it over the same sender).
      final restarted = DeliveryPlan.restore(
        channels: [primary, fallback],
        send: sender.send,
        durable: true,
        state: plan.state,
      );

      // The retry resumes: the primary is owed again …
      expect(restarted.isOwed, isTrue);
      await restarted.attempt();
      expect(sender.callsTo(primary), 2);
      // … and the push is NOT re-sent by the restore.
      expect(sender.callsTo(fallback), 1);
      expect(restarted.fallbackSent, isTrue);
    });

    test('durable: a restore that has not sent the fallback yet lets the '
        'primary fail first, then sends it once', () async {
      final sender = _FakeSender(
        script: {
          primary: const [SendOutcome.failed],
        },
      );
      // The persisted state says the delivery is owed and the push has not
      // gone out (a crash between the first failure and the push — or a
      // record written before the push could be sent).
      final restarted = DeliveryPlan.restore(
        channels: [primary, fallback],
        send: sender.send,
        durable: true,
        state: const DeliveryState(owed: true, fallbackSent: false),
      );

      // The restore does not assume the primary failed: the primary is
      // attempted first, and its failure is what arms the fallback.
      await restarted.attempt();
      expect(sender.sent.map((s) => s.channel), [primary, fallback]);
      expect(sender.callsTo(fallback), 1);
      expect(
        restarted.state,
        const DeliveryState(owed: true, fallbackSent: true),
      );
    });

    test('fire-and-forget: a non-durable delivery is attempted once, never '
        'retried, and not owed afterwards', () async {
      final sender = _FakeSender(
        // The device's send fails — fire-and-forget does not retry it.
        script: {
          primary: const [SendOutcome.failed],
        },
      );
      // The fan-out's per-device plan: one channel, the primary, not
      // durable — the posture is the named [DeliveryPlan.durable] decision,
      // not the absence of a retry the producer forgot.
      final plan = DeliveryPlan(
        channels: [primary],
        send: sender.send,
        durable: false,
      );

      final attempt = await plan.attempt();
      expect(attempt.sends.map((s) => s.channel), [primary]);
      expect(
        plan.isOwed,
        isFalse,
      ); // not owed: a failure drops it off the books

      // The next opportunity does nothing (one device's failure does not
      // stop the rest — the producer moves on to the next device's plan).
      expect((await plan.attempt()).isEmpty, isTrue);
      expect(sender.callsTo(primary), 1);
    });

    test('fire-and-forget: a non-durable delivery that lands is sent once and '
        'not owed afterwards', () async {
      final sender = _FakeSender(
        script: {
          primary: [SendOutcome.landed],
        },
      );
      final plan = DeliveryPlan(
        channels: [primary],
        send: sender.send,
        durable: false,
      );
      await plan.attempt();
      expect(plan.isOwed, isFalse);
      expect(sender.callsTo(primary), 1);
      expect((await plan.attempt()).isEmpty, isTrue);
    });

    test('a throwing send is a failed attempt (the policy reasons about '
        'outcomes, never exceptions)', () async {
      final sender = _FakeSender(
        script: {
          primary: const [SendOutcome.failed],
          fallback: const [SendOutcome.failed],
        },
      );
      Future<SendOutcome> thrower(DeliveryChannel channel) async =>
          throw StateError('the transport is down');
      final plan = DeliveryPlan(channels: [primary, fallback], send: thrower);

      final attempt = await plan.attempt();
      expect(attempt.sends.map((s) => s.outcome), [
        SendOutcome.failed,
        SendOutcome.failed,
      ]);
      // The decisions updated as if the send had answered `failed`.
      expect(plan.isOwed, isTrue);
      expect(plan.fallbackSent, isTrue);
      expect(sender.sent, isEmpty); // the fake was never used
    });

    test('the primary channel comes first (the plan shape is enforced)', () {
      // A malformed channel list is a client error, not a posture the policy
      // can silently absorb.
      expect(
        () => DeliveryPlan(channels: [fallback], send: alwaysLands),
        throwsArgumentError,
      );
      expect(
        () => DeliveryPlan(channels: const [], send: alwaysLands),
        throwsArgumentError,
      );
    });
  });
}

/// A fake sender (issue #259's test seam): one scripted [SendOutcome] per
/// channel, in order — a channel's last scripted outcome repeats (a primary
/// scripted `failed` fails on every retry). Records every send it is asked to
/// make.
class _FakeSender {
  _FakeSender({this.script = const {}});

  final Map<DeliveryChannel, List<SendOutcome>> script;
  final _cursors = <DeliveryChannel, int>{};
  final sent = <DeliverySend>[];

  Future<SendOutcome> send(DeliveryChannel channel) async {
    final sequence = script[channel] ?? const [SendOutcome.landed];
    final i = _cursors[channel] ?? 0;
    _cursors[channel] = i + 1;
    final outcome = i < sequence.length ? sequence[i] : sequence.last;
    sent.add(DeliverySend(channel, outcome));
    return outcome;
  }

  int callsTo(DeliveryChannel channel) =>
      sent.where((s) => s.channel == channel).length;
}

/// A sender that lands everything (the "the caller is reachable" default).
Future<SendOutcome> alwaysLands(DeliveryChannel channel) async =>
    SendOutcome.landed;
