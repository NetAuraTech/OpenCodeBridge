/// The AFK spawn-boundary state (spec #407, T5 — reshaped from #376): what
/// the orb-spawn boundary reads live at the moment an orb is spawned, to
/// enforce the parallel-orbs cap. It is the bridge's **own** attribution
/// fact — not the generic spawn-tree record — so it lives in the AFK
/// subsystem, not on the task record.
///
/// A spawn is **AFK-attributed** when its caller session is **any** AFK
/// session (the session ids the bridge created for the armed agents,
/// persisted in the AFK store per repo). The cap is the **host total**
/// (spec #407): it counts all AFK-attributed orbs in flight across all
/// repos — arming two repos never doubles orbs in flight. Orbs the
/// developer spawns (a caller session not in the set) are never capped,
/// and with no AFK session there are no AFK orbs to count.
class AfkSpawnGate {
  const AfkSpawnGate({required this.sessionIds, required this.cap});

  /// The set of AFK session ids (the store's **disarming-stable** set —
  /// every stored `afk.session.<owner/repo>` id, fresh from the AFK store
  /// on every gate read). A disarm never deletes a stored session id (the
  /// session outlives a disarm), so a repo disarmed while its orb is in
  /// flight keeps its id in the set until that orb settles: the in-flight
  /// fact is the creating task's caller, not the current arming. An empty
  /// set is equivalent to no gate — nothing is AFK-attributed, so the cap
  /// never applies. The caller is [isAfk] by **membership**.
  final Set<String> sessionIds;

  /// The parallel-orbs cap, read live from Settings (effective from the next
  /// spawn, spec #376 "Settings"): the host-wide total across all repos.
  final int cap;

  /// Whether [callerSession] is any armed repo's AFK session — the
  /// attribution fact: a spawn with this caller session is an
  /// AFK-attributed orb, the one the parallel-orbs cap is scoped to and
  /// counted. An empty set attributes nothing.
  bool isAfk(String? callerSession) =>
      callerSession != null &&
      callerSession.isNotEmpty &&
      sessionIds.contains(callerSession);
}
