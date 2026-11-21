/// The push event kinds (issue #24), each with its own per-device toggle.
/// The [wire] value is what the app sends in the registration's `events`
/// array (`POST /api/notify/device-token`).
enum NotifyKind {
  /// A session asked for a permission (its banner is waiting for a reply).
  permissionAsked('permissionAsked'),

  /// A session's turn ended (succeeded, failed, or interrupted).
  turnEnded('turnEnded'),

  /// A container stopped (clean exit) or crashed (non-zero exit).
  dockerContainer('dockerContainer'),

  /// An AFK run reached one of its two "look now" moments (spec #376, T5): its
  /// PR opened, or it failed terminally — high priority. Its own toggle,
  /// distinct from the arming toggle (armed-but-silenced is legitimate).
  afkRun('afkRun');

  const NotifyKind(this.wire);

  /// The wire value on the registration contract.
  final String wire;

  /// Parses a registration body's `events` array into the enabled kinds.
  /// Returns `null` on any malformed entry (the caller maps it to a 400);
  /// an empty array parses to the empty set (no push enabled).
  static Set<NotifyKind>? parseEvents(Object? events) {
    if (events is! List) return null;
    final kinds = <String, NotifyKind>{};
    for (final entry in events) {
      if (entry is! String) return null;
      final kind = NotifyKind.values.where((k) => k.wire == entry).firstOrNull;
      if (kind == null) return null;
      kinds[kind.wire] = kind;
    }
    return kinds.values.toSet();
  }
}
