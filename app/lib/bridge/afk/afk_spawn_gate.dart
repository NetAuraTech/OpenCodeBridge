/// The AFK spawn-boundary state (spec #376, T4): what the orb-spawn boundary
/// reads live at the moment an orb is spawned, to enforce the parallel-orbs
/// cap. It is the bridge's **own** attribution fact — not the generic
/// spawn-tree record — so it lives in the AFK subsystem, not on the task
/// record.
///
/// A spawn is **AFK-attributed** when its caller session is the AFK session
/// (the session id the bridge created for the armed agent, persisted in the
/// AFK store). The cap is scoped to AFK orbs only: orbs the developer spawns
/// (any other caller session) are never capped, and with no AFK session there
/// are no AFK orbs to count.
class AfkSpawnGate {
  const AfkSpawnGate({required this.afkSessionId, required this.cap});

  /// The AFK session id (the bridge's own persisted fact, from the AFK store).
  /// `null` when the system is not armed: there is no AFK session, so no spawn
  /// is AFK-attributed and the cap never applies.
  final String? afkSessionId;

  /// The parallel-orbs cap, read live from Settings (effective from the next
  /// spawn, spec #376 "Settings").
  final int cap;

  /// Whether [callerSession] is the AFK session — the attribution fact: a
  /// spawn with this caller session is an AFK-attributed orb, the one the
  /// parallel-orbs cap is scoped to and counted. A `null`/empty AFK session id
  /// (unarmed) attributes nothing.
  bool isAfk(String? callerSession) =>
      afkSessionId != null &&
      afkSessionId!.isNotEmpty &&
      callerSession == afkSessionId;
}
