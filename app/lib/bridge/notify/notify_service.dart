import 'fcm_sender.dart';
import '../../notify/notify_kind.dart';

/// The bridge's push dispatch (issue #24): who is registered for what, and
/// the fan-out of the three push events.
///
/// The registry is in-process and volatile on purpose: push is outbound
/// from the running bridge only — independent of tunnel state, and only
/// while the app (server mode) runs — so a device that stops
/// re-registering simply stops receiving.
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

  /// Sends the push to every device that has [kind] enabled; a delivery
  /// failure on one device does not stop the rest. Returns how many
  /// deliveries succeeded.
  Future<int> publish(
    NotifyKind kind, {
    required String title,
    required String body,
    required String link,
  }) async {
    var sent = 0;
    for (final entry in _devices.entries) {
      if (!entry.value.contains(kind)) continue;
      try {
        await sender.send(
          token: entry.key,
          title: title,
          body: body,
          link: link,
        );
        sent++;
      } catch (_) {
        // One device's failure does not stop the rest.
      }
    }
    return sent;
  }
}
