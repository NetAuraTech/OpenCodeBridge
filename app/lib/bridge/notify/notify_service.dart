import 'delivery_policy.dart';
import 'fcm_sender.dart';
import '../../notify/notify_kind.dart';

/// The bridge's push dispatch (issue #24): who is registered for what, and
/// the fan-out of the three push events.
///
/// The registry is in-process and volatile on purpose: push is outbound
/// from the running bridge only — independent of tunnel state, and only
/// while the app (server mode) runs — so a device that stops
/// re-registering simply stops receiving.
///
/// The event-driven fire-and-forget posture is **named, not absent** (issue
/// #261, the D3 step of the push-delivery series): [publish] no longer
/// carries "push exactly once" as the fact that its loop happens not to retry
/// a device — each eligible device is delivered through a [DeliveryPlan] from
/// the delivery-policy module (issue #259, #260's settle path uses the same
/// module for the durable posture). The plan is the producer's loop's unit:
///
/// - The fan-out itself stays the producer's loop over the registry (one
///   [DeliveryPlan] per eligible device), and the per-kind toggle filtering
///   stays here — the policy knows a delivery to one device, not a fan-out.
/// - Each device's plan is a **single non-durable primary** channel:
///   [ChannelRole.primary] (the push — the fan-out has no fallback, so no
///   **primary-vs-fallback** split) and `durable: false`. A non-durable
///   primary is attempted exactly once and then drops off the books whether
///   it landed or not — the **durable** decision flipped off: nothing is
///   **owed** across attempts *or* events, and a failed device is never
///   re-attempted (fire-and-forget, now the policy's named decision rather
///   than the absence of a retry call).
/// - The producer never decides retry/once itself: it names the policy it
///   wants and drives `plan.attempt()`. The one device's-failure-does-not-
///   stop-the-rest guarantee is the plan's — one device's plan is a delivery
///   independent of every other device's, so a failed attempt on one leaves
///   the rest (and the count) untouched.
class NotifyService {
  NotifyService({required this.sender});

  /// The FCM transport (the Admin SDK by default; the raw HTTP v1 fallback
  /// when `OPENCODEBRIDGE_FCM_TRANSPORT=http`).
  final FcmSender sender;

  /// token → the kinds its Settings toggles have enabled.
  final Map<String, Set<NotifyKind>> _devices = {};

  /// The number of registered device tokens (tests/observability).
  int get deviceCount => _devices.length;

  /// The kinds [token] currently has enabled, or `null` when it is not
  /// registered (tests/observability).
  Set<NotifyKind>? enabledKinds(String token) => _devices[token]?.toSet();

  /// Registers (or re-registers) [token] with exactly the enabled
  /// [events]. The app calls this on connect and on every Settings toggle
  /// change; the latest call wins.
  void registerDevice(String token, Set<NotifyKind> events) {
    _devices[token] = Set.of(events);
  }

  /// Releases the sender (the bridge's `stop`).
  Future<void> close() => sender.close();

  /// The delivery channels of one device's push (issue #261): a single
  /// non-durable **primary** (the push — the fan-out has no fallback, so no
  /// **primary-vs-fallback** split), in the policy's order.
  List<DeliveryChannel> _deliveryChannels() => [
    const DeliveryChannel(ChannelRole.primary, name: 'push'),
  ];

  /// The one-shot (fire-and-forget) plan a device's push goes out through
  /// (issue #261): a [DeliveryPlan] on the single non-durable primary, driven
  /// once by [publish] — the **durable** decision flipped off, so the delivery
  /// is not **owed** after its single attempt and a failure is never retried.
  DeliveryPlan _newPlan(
    String token, {
    required String title,
    required String body,
    required String link,
  }) {
    return DeliveryPlan(
      channels: _deliveryChannels(),
      send: (channel) =>
          _sendOn(channel, token, title: title, body: body, link: link),
      durable: false,
    );
  }

  /// The [DeliveryPlan.send] this service hands its per-device plans (issue
  /// #261): the producer's sender, mapping the real send to the policy's
  /// [SendOutcome]. A [FcmSender.send] that completes is a landed delivery;
  /// one that throws (a dead token, a refusing service, a transient failure)
  /// is a [SendOutcome.failed]. The policy never sees a throw (a throwing
  /// send is a [SendOutcome.failed] to it) — the producer's sender throws,
  /// and the mapping here is the only place that becomes an outcome.
  Future<SendOutcome> _sendOn(
    DeliveryChannel channel,
    String token, {
    required String title,
    required String body,
    required String link,
  }) async {
    try {
      await sender.send(token: token, title: title, body: body, link: link);
      return SendOutcome.landed;
    } catch (_) {
      return SendOutcome.failed;
    }
  }

  /// Sends the push to every device that has [kind] enabled, one device's
  /// delivery going through its own non-durable single-primary [DeliveryPlan]
  /// (issue #261); a delivery failure on one device does not stop the rest.
  /// Returns how many devices' sends **landed** (the count keeps its current
  /// semantics).
  Future<int> publish(
    NotifyKind kind, {
    required String title,
    required String body,
    required String link,
  }) async {
    var landed = 0;
    for (final entry in _devices.entries) {
      if (!entry.value.contains(kind)) continue;
      // One plan per device: a fresh non-durable single-primary plan per
      // event (nothing is owed across events — a later publish re-delivers
      // to the same device), attempted once (fire-and-forget, the policy's
      // named decision). One device's failed attempt is isolated to its own
      // plan — the rest of the fan-out is independent of it.
      final plan = _newPlan(entry.key, title: title, body: body, link: link);
      final attempt = await plan.attempt();
      // The plan's own sends: exactly one (the non-durable primary), landed or
      // failed. A landing is counted; a failure is not (it is not re-attempted
      // — the next [publish] builds a fresh plan for this device again).
      for (final send in attempt.sends) {
        if (send.outcome == SendOutcome.landed) landed++;
      }
    }
    return landed;
  }
}
