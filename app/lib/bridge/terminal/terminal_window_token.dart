import 'dart:math';

/// The window token (spec §10, §14): the bridge generates a random
/// per-bridge-startup token, passes it in the spawn command of each attach
/// client, and never persists it. The attach client authenticates to the
/// bridge with it (endpoint 10). The in-process local client (server mode) is
/// implicit and needs no token.
///
/// It is deliberately in-memory only: it is regenerated on every bridge
/// startup and lives nowhere on disk, so a restart invalidates every token
/// handed out before it.
class TerminalWindowToken {
  const TerminalWindowToken._(this.value);

  /// The number of random bytes (256 bits) backing the token.
  static const int _bytes = 32;

  /// A fresh token. Backed by [Random.secure] unless a [Random] is supplied
  /// (tests pass a seeded one for determinism).
  factory TerminalWindowToken.generate({Random? random}) {
    final rng = random ?? Random.secure();
    final bytes = List<int>.generate(_bytes, (_) => rng.nextInt(256));
    return TerminalWindowToken._(
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    );
  }

  /// The opaque token value (lowercase hex), what goes on the spawn command
  /// line and in the attach client's `?token=` query parameter.
  final String value;

  /// Whether [presented] is this token. A missing/empty value never matches.
  bool verify(String? presented) {
    if (presented == null) return false;
    if (presented.length != value.length) return false;
    var difference = 0;
    for (var i = 0; i < value.length; i++) {
      difference |= value.codeUnitAt(i) ^ presented.codeUnitAt(i);
    }
    return difference == 0;
  }
}
