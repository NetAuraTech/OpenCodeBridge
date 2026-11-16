/// The delivery-policy module (issue #259, step D1 — "expand"): the one owner
/// of the named decisions of a push delivery, sitting above the sender and the
/// device registry.
///
/// Push has two producers with two postures (issue #259's finding S4): the
/// event-driven fire-and-forget fan-out ([NotifyService.publish]) and the
/// settle-once with a one-shot push fallback ([OrbTaskService]). Today each
/// posture is the *absence of a call* — "push exactly once" survives only
/// because the retry step does not call the push, and "fire-and-forget" is the
/// absence of any retry. This module turns each of those into a **named
/// decision** the policy owns:
///
/// - **owed** ([DeliveryPlan.isOwed]) — the delivery has not yet landed. A
///   [DeliveryPlan.durable durable] delivery stays owed until it lands; a
///   one-shot delivery stops being owed after its single attempt.
/// - **once-sent** ([DeliveryPlan.fallbackSent]) — the once-sent fallback has
///   fired. It is armed on the primary's first failure and never re-sent: the
///   named stand-in for the retry step "not calling the push".
/// - **durable** ([DeliveryPlan.durable]) — an unlanded delivery is owed
///   across attempts *and restarts* (the settle path), so its
///   [DeliveryState] is persistable, rather than dropped after one attempt
///   (fire-and-forget).
/// - **primary-vs-fallback** ([ChannelRole]) — which channel is retried until
///   it lands (the primary, the settle path's in-app injection) and which
///   fires exactly once as the out-of-band fallback (the push).
///
/// The module decides *what* is owed and *which channel* to attempt; it never
/// performs the send itself. The producer performs it, through the
/// [ChannelSender] the plan is given — the FCM sender, the in-app injection,
/// or a fake in tests. That is what makes the module unit-testable with a fake
/// sender: retry-until-lands, never-re-push, exactly-once, and durable across
/// a restart are all pinned by tests that drive a [DeliveryPlan] with a
/// scripted fake.
///
/// A plan describes **one delivery to one target**: the settle path's
/// completion to its caller (primary = the in-app injection, fallback = the
/// out-of-band push, durable), or the fire-and-forget fan-out's push to one
/// device (a single non-durable primary — the fan-out itself stays the
/// producer's loop over the registry, one plan per device). The **owed**
/// decision is per delivery, not per event: two different completions are two
/// plans, each owed until it lands.
///
/// Expand phase (D1): no producer is rewired to this module yet — the
/// fire-and-forget fan-out and the settle path keep their current code, and
/// the rewiring lands in #260 (the settle path) and #261 (the event-driven
/// path).
library;

/// The outcome of one delivery attempt on a [DeliveryChannel] (issue #259).
enum SendOutcome {
  /// The destination accepted the delivery (it landed).
  landed,

  /// The destination could not take it (a dead caller, a refusing service, a
  /// transient failure). The policy decides whether it is still owed.
  failed,
}

/// The role of a [DeliveryChannel] within a [DeliveryPlan] (issue #259): the
/// named **primary-vs-fallback** decision. The role — not whether the caller
/// happens to call the channel again — is what makes a channel retried or
/// once-sent.
enum ChannelRole {
  /// The **primary** channel: the one the delivery is owed on. Retried until
  /// it [SendOutcome.landed lands] while the delivery is [DeliveryPlan.durable
  /// durable] (the settle path's in-app injection); attempted exactly once
  /// when it is not (the fire-and-forget fan-out's push).
  primary,

  /// The **fallback** channel: sent exactly once, armed on the primary's first
  /// failure, never re-sent — not even re-sent after its own failure (the
  /// settle path's out-of-band push: the in-app retry keeps owning the
  /// delivery). This is the **once-sent** decision.
  fallback,
}

/// One named send destination within a [DeliveryPlan] (issue #259): a channel
/// the policy can decide to attempt, plus the [ChannelRole] that decides how
/// it is attempted.
class DeliveryChannel {
  const DeliveryChannel(this.role, {this.name = ''});

  /// The named **primary-vs-fallback** decision for this channel.
  final ChannelRole role;

  /// A label for the channel (logs, tests); the policy never reads it.
  final String name;

  @override
  String toString() =>
      'DeliveryChannel(${role.name}${name.isEmpty ? '' : ' $name'})';
}

/// The policy's only outward effect (issue #259): one send of the delivery on
/// one [channel]. The producer implements it against its real sender (the FCM
/// sender, the in-app injection); a test implements it with a fake that
/// records the sends and scripts the [SendOutcome]. It returns the
/// [SendOutcome] — the policy never sees a throw: a throwing send is a
/// [SendOutcome.failed] to the policy, and the send's own error is the
/// producer's to handle.
typedef ChannelSender = Future<SendOutcome> Function(DeliveryChannel channel);

/// The persistable named-decision state of a [DeliveryPlan] (issue #259).
///
/// This is the **durable** decision made concrete: a not-yet-landed delivery
/// is owed across attempts *and restarts*, so the producer persists this
/// state (with the task record) and restores it after a restart — the retry
/// resumes (the primary is still owed) and the once-sent fallback is never
/// re-sent. The module owns the *shape* of the fact; the producer owns where
/// it is written (the tasks file, today).
class DeliveryState {
  const DeliveryState({required this.owed, required this.fallbackSent});

  /// **owed**: the delivery has not yet landed (it is still outstanding).
  final bool owed;

  /// **once-sent**: the once-sent fallback has already fired (it must never
  /// go out again, even after a restart).
  final bool fallbackSent;

  @override
  bool operator ==(Object other) =>
      other is DeliveryState &&
      other.owed == owed &&
      other.fallbackSent == fallbackSent;

  @override
  int get hashCode => Object.hash(owed, fallbackSent);

  @override
  String toString() =>
      'DeliveryState(owed: $owed, fallbackSent: $fallbackSent)';
}

/// One send within a [DeliveryAttempt]: the channel and its [SendOutcome].
class DeliverySend {
  const DeliverySend(this.channel, this.outcome);

  /// The channel the send went out on.
  final DeliveryChannel channel;

  /// Whether it landed.
  final SendOutcome outcome;
}

/// The record of one [DeliveryPlan.attempt] (issue #259): the sends the plan
/// performed on this call, in the order they were attempted — or empty when
/// nothing was owed (the delivery is already satisfied, or a one-shot attempt
/// already went out).
class DeliveryAttempt {
  const DeliveryAttempt(this.sends);

  /// The sends performed, in order.
  final List<DeliverySend> sends;

  /// Whether nothing was owed (no send was attempted).
  bool get isEmpty => sends.isEmpty;
}

/// The delivery policy for one logical delivery (issue #259, step D1): the
/// owner of its four named decisions — **owed**, **once-sent**, **durable**,
/// and **primary-vs-fallback** — driven step by step by the producer through
/// [attempt].
///
/// The producer calls [attempt] on each opportunity — the settle's first pass,
/// then each watcher pass (and, after a restart, the passes of the restarted
/// bridge, through a [DeliveryPlan.restore]d plan); each fan-out device once.
/// The plan decides, from its named decisions, which channels are owed this
/// opportunity: the [ChannelRole.primary primary] first (retried while owed),
/// then the [ChannelRole.fallback fallback] (owed exactly once — armed on the
/// primary's first failure, discharged when sent). The producer performs the
/// sends through its [send] and holds the returned [DeliveryAttempt]; the
/// plan's state afterwards is the new truth ([state]).
class DeliveryPlan {
  DeliveryPlan({
    required Iterable<DeliveryChannel> channels,
    required this.send,
    this.durable = true,
  }) : _channels = List.unmodifiable(channels),
       _primaryOwed = true,
       _primaryFailed = false,
       _fallbackSent = false {
    _resolve();
  }

  /// Restores a plan from its persisted [DeliveryState] (the **durable**
  /// decision, issue #259): the primary is still [DeliveryState.owed owed]
  /// (the retry resumes on the next [attempt]), and the once-sent
  /// [DeliveryState.fallbackSent fallback] is never re-sent.
  ///
  /// A restore never re-sends what was already sent, and it never arms the
  /// fallback on an attempt that has not happened: a restored
  /// `(owed: true, fallbackSent: false)` is the *fresh* reading — the primary
  /// is unattempted again, and the fallback is re-armed only if the primary
  /// fails again (which still sends it at most once for the delivery's whole
  /// life). The producer supplies the same [channels], [send], and [durable]
  /// it used before the restart — its posture does not change across a
  /// restart.
  DeliveryPlan.restore({
    required Iterable<DeliveryChannel> channels,
    required this.send,
    required this.durable,
    required DeliveryState state,
  }) : _channels = List.unmodifiable(channels),
       _primaryOwed = state.owed,
       _primaryFailed = false,
       _fallbackSent = state.fallbackSent {
    _resolve();
  }

  /// The channels in priority order (the primary first, then the fallback).
  /// Unmodifiable; the order is the policy's.
  final List<DeliveryChannel> _channels;

  /// The send the policy drives (the producer's sender, wrapped — see
  /// [ChannelSender]).
  final ChannelSender send;

  /// The **durable** decision: an unlanded delivery stays owed across attempts
  /// and restarts (`true`, the settle path) rather than dropping off the
  /// books after its single attempt (`false`, fire-and-forget).
  final bool durable;

  /// **owed** (internal): the primary — the channel the delivery is owed on —
  /// has not yet landed.
  bool _primaryOwed;

  /// Whether the primary was attempted and failed at least once: the fact that
  /// arms the once-sent fallback (a fresh plan has not failed yet, a restored
  /// owed one has).
  bool _primaryFailed;

  /// **once-sent** (internal): the fallback went out; it is never sent again.
  bool _fallbackSent;

  late final DeliveryChannel _primary;
  late final DeliveryChannel? _fallback;

  /// Resolves the channels' roles into the primary and (optional) fallback,
  /// enforcing the shape: at least one channel, the primary first (a
  /// malformed list is a client error — [ArgumentError] — not a posture the
  /// policy can silently absorb). The primary-vs-fallback decision is
  /// structural from here on — the attempts below never re-derive it.
  void _resolve() {
    if (_channels.isEmpty) {
      throw ArgumentError.value(
        _channels,
        'channels',
        'a delivery plan needs at least one channel',
      );
    }
    if (_channels.first.role != ChannelRole.primary) {
      throw ArgumentError.value(
        _channels,
        'channels',
        'the primary channel comes first (it is the channel the delivery is owed on)',
      );
    }
    _primary = _channels.first;
    _fallback = _channels
        .where((c) => c.role == ChannelRole.fallback)
        .firstOrNull;
  }

  /// **owed** (issue #259): whether the delivery is still outstanding — the
  /// primary has not yet landed. The producer's retry loop (and its
  /// "does this task still owe work" read) reads this.
  bool get isOwed => _primaryOwed;

  /// **once-sent** (issue #259): whether the once-sent fallback has already
  /// fired. A `true` here is the named fact that the fallback must never go
  /// out again — the stand-in for the retry step "not calling the push".
  bool get fallbackSent => _fallbackSent;

  /// The **primary-vs-fallback** decision as channels: the primary first,
  /// then the fallback (absent when the plan has none — the fire-and-forget
  /// fan-out's single channel).
  List<DeliveryChannel> get channels => List.unmodifiable(_channels);

  /// The plan's named-decision state, for the producer to persist (the
  /// **durable** decision): feed it back through [DeliveryPlan.restore] after
  /// a restart and the decisions resume where they left off.
  DeliveryState get state =>
      DeliveryState(owed: isOwed, fallbackSent: fallbackSent);

  /// One delivery opportunity (issue #259): attempts the channels owed this
  /// pass, in role order — the [ChannelRole.primary primary] while it is still
  /// [isOwed owed] (retried until it lands, for a [durable durable] plan),
  /// then the [ChannelRole.fallback fallback] when it is owed exactly once
  /// (armed on the primary's first failure, discharged when sent).
  ///
  /// Returns what went out ([DeliveryAttempt.sends], in order) — empty when
  /// nothing was owed, which is the "do nothing" decision made explicit.
  Future<DeliveryAttempt> attempt() async {
    final sends = <DeliverySend>[];
    if (_primaryOwed) {
      final outcome = await _send(_primary);
      sends.add(DeliverySend(_primary, outcome));
      if (outcome == SendOutcome.landed) {
        // Landed: the delivery is no longer owed (and so is the fallback
        // never owed — it is armed on failure, not on attempt).
        _primaryOwed = false;
      } else {
        // The first failure arms the once-sent fallback; a one-shot (not
        // durable) delivery stops being owed after this single attempt.
        _primaryFailed = true;
        if (!durable) _primaryOwed = false;
      }
    }
    if (_fallback != null && _primaryFailed && !_fallbackSent) {
      final outcome = await _send(_fallback);
      sends.add(DeliverySend(_fallback, outcome));
      _fallbackSent =
          true; // Sent once: never again, even after its own failure.
    }
    return DeliveryAttempt(sends);
  }

  /// Performs one send on [channel] through [send], mapping a throwing send to
  /// [SendOutcome.failed] (the policy reasons about outcomes, never about
  /// exceptions).
  Future<SendOutcome> _send(DeliveryChannel channel) async {
    try {
      return await send(channel);
    } catch (_) {
      return SendOutcome.failed;
    }
  }

  @override
  String toString() =>
      'DeliveryPlan(${_channels.join(', ')}; durable: $durable; $state)';
}
