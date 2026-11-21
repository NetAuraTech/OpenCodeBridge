/// The AFK spawn-boundary state (spec #376, T4; reshaped by spec #407, T3):
/// what the orb-spawn boundary reads live at the moment an orb is spawned, to
/// enforce the parallel-orbs cap. It is the bridge's **own** attribution fact
/// — not the generic spawn-tree record — so it lives in the AFK subsystem,
/// not on the task record.
///
/// A spawn is **AFK-attributed** when its caller session is *any* armed
/// repo's AFK session: the gate holds the **set** of AFK session ids
/// (every armed repo's stored session id, spec #407 — the session is per
/// repo) and the attribution is membership in the set. The cap is the host
/// total, scoped to AFK orbs only: orbs the developer spawns (any other
/// caller session) are never capped, and with no AFK session (an empty set)
/// there are no AFK orbs to count.
class AfkSpawnGate {
  const AfkSpawnGate({required this.afkSessionIds, required this.cap});

  /// The set of AFK session ids (every armed repo's stored session id — the
  /// bridge's own persisted facts, from the AFK store). An empty set (no repo
  /// armed, or no stored id) attributes nothing: no spawn is AFK-attributed
  /// and the cap never applies. Read live on every spawn (the bridge's
  /// closure re-builds the gate from the store per spawn).
  final Set<String> afkSessionIds;

  /// The parallel-orbs cap, read live from Settings (effective from the next
  /// spawn, spec #376 "Settings"): the host total — AFK orbs in flight
  /// across **all** armed repos, not per repo.
  final int cap;

  /// Whether [callerSession] is one of the AFK sessions — the attribution
  /// fact: a spawn with this caller session is an AFK-attributed orb, the
  /// one the parallel-orbs cap is scoped to and counted. An empty AFK
  /// session set (unarmed) attributes nothing.
  bool isAfk(String? callerSession) =>
      callerSession != null && afkSessionIds.contains(callerSession);
}
