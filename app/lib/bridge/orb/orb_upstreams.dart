// The live orb upstreams (issue #274, spec §7.1/§7.2/§7.3): the per-orb
// service descriptor — the ephemeral service URL (the running orb record's
// port mapping, spec §2.9/§7.1) plus the password (the last `server
// password` line of the orb's container log, spec §7.1) — with one home.
//
// The descriptor has no file to read (spec §7.1: a directly-invoked
// `opencode serve` writes no `service.json`): it is re-derived at every
// refresh from the running orb list and the container log. The module owns
// both facts:
//
// - the **live upstream set with credentials** ([OrbUpstreamSource.live]):
//   every running orb that passes the reachability gate, with its url and
//   password;
// - the **per-orb reachability verdict** ([OrbUpstreamSource.verdict] →
//   [UpstreamVerdict]): "is a 404 from the composite meaningful for orb X
//   right now?" — the same gate, answered per orb, distinguishing the
//   reachable / unroutable / gone / unknown cases;
// - the **raw running-orb list** ([OrbUpstreamSource.records]): the
//   un-gated fact, for a consumer that needs the list itself (the events
//   composite's boot-retry check, issue #278).
//
// The gate is ONE predicate, owned here: [OrbUpstream.reachable] — a
// running orb whose record carries a non-empty ephemeral url and whose
// container log already carries a `server password` line. The [OrbUpstream]
// value and every verdict the source derives are computed from this single
// predicate, so a change to it changes every consumer's answer together,
// not independently within a single pass (the composites' per-consumer
// drift, issue #274's reason for the module).
//
// Degradation is owned here, the way the composites own it today: a list
// the source cannot read (docker down) yields an empty live set, an
// [UpstreamVerdict.unknown] per orb, and a `null` raw list — the host-only,
// inconclusive answer. A degraded read must never claim an upstream exists,
// nor that a session is gone.
//
// The module is the bridge's orb↔composite seam (issue #278): the
// composition root wires ONE [LiveOrbUpstreams] (over the bridge's orb
// service, degrading to empty list / null password when this machine has no
// orbs service) and every consumer takes it — the sessions composite, the
// events composite, the task service, and the backend-resolution re-arm. A
// new consumer reads the module without a new bridge closure, and the
// reachability gate exists once, in this module. The call sites read the
// module: #275 wired the composites and the lifecycle pass (the sessions
// and events composites reconcile on [LiveOrbUpstreams.live]), #276 wired
// the task service (it asks [OrbUpstreamSource.verdict] and reads the
// answer off [UpstreamVerdictAgreement.missingReadConclusive]), #277 pins
// the agreement structurally (the shared contract
// `test/bridge/orb/orb_upstream_contract.dart` asserts both consumers'
// answers equal the module's derivation for every scenario), and #278
// (this change) makes the bridge seam the module — no ad-hoc derivation
// remains.

import '../../model/orb.dart';
import 'orb_service.dart';

/// One reachable orb's descriptor (spec §7.1): the per-orb service URL
/// with the password its current boot logged.
///
/// The URL is the running record's ephemeral url — the list derives it
/// from the port mapping (spec §2.9), and this value reads it off the
/// record; it does not re-derive the mapping. The password is the last
/// `server password` line of the orb's container log (spec §7.1: every
/// start/respawn mints a fresh one — the last line wins).
///
/// The value is the gate's **answer**: it is only constructed through the
/// [OrbUpstream.reachable] predicate (running + non-empty url + a password
/// line in the log). A record that does not pass the gate has no
/// descriptor at all — there is no "upstream without a password" value.
class OrbUpstream {
  const OrbUpstream._({
    required this.id,
    required this.url,
    required this.password,
  });

  /// The single reachability gate (spec §7.1/§7.2/§7.3 — one predicate,
  /// owned here, read by every consumer): a descriptor exists only for a
  /// **running** orb whose record carries a **non-empty** ephemeral url
  /// and whose container log already carries a `server password` line
  /// ([password] non-`null` and non-empty). Everything else — stopped,
  /// booting, broken, url-less, no password line yet — has no upstream.
  ///
  /// [state] is the composed record string: only the `running` base passes
  /// — a `preparing`/`stopped`/`cleanup_pending`/`broken:*`/`orphan`
  /// record has no upstream whatever else it carries.
  static OrbUpstream? reachable({
    required String id,
    required String? state,
    required String? url,
    required String? password,
  }) {
    if (state != 'running') return null;
    if (url == null || url.isEmpty) return null;
    if (password == null || password.isEmpty) return null;
    return OrbUpstream._(id: id, url: url, password: password);
  }

  /// The orb id (the label `ocb.id`; the routing table's key).
  final String id;

  /// The service URL (`http://127.0.0.1:<ephemeral-port>`, spec §7.1).
  final String url;

  /// The service password: the last `server password` line of the orb's
  /// container log (spec §7.1).
  final String password;

  /// The `(url, password)` key the composites reconcile on (spec §7.2/§7.3):
  /// a respawn's new port/password changes it, which is what replaces a
  /// stale upstream client.
  String get key => '$url|$password';

  @override
  bool operator ==(Object other) =>
      other is OrbUpstream &&
      other.id == id &&
      other.url == url &&
      other.password == password;

  @override
  int get hashCode => Object.hash(OrbUpstream, id, url, password);

  @override
  String toString() => 'OrbUpstream($id, $url)';
}

/// The per-orb reachability verdict the composites' 404 handling and the
/// task service's missing-read window read (issue #211/#276): for one orb,
/// what does a composite 404 mean **right now**?
///
/// - [reachable]: the orb passes the gate — the composite has an upstream
///   for it, so a session it 404s is a gone one (a meaningful 404).
/// - [unroutable]: the orb is in a readable list but has no upstream —
///   booting (its `server password` line has not landed yet), stopped,
///   broken, or url-less. The composite has no upstream for it and the
///   read fell back to the host, which cannot know the orb session — the
///   404 is "not routable yet", not "session gone".
/// - [gone]: the list is readable and the orb is absent from it (deleted
///   out from under the reader): its in-orb sessions are lost with it —
///   the 404 is the truth.
/// - [unknown]: the list itself cannot be read (docker down): the composite
///   degrades host-only and nothing may be concluded — neither "upstream
///   exists" nor "session gone". A degraded read must never settle.
///
/// The two consumers' answers for a verdict are ONE shared derivation,
/// owned here ([UpstreamVerdictAgreement]): the sessions composite's
/// routing answer ("does the composite have a live upstream for the
/// orb?") and the task service's 404-conclusiveness answer ("is a 404
/// from the composite conclusive for the orb?"). Both are consequences of
/// the single [OrbUpstream.reachable] gate this verdict is computed from,
/// and they are deliberately **not** identical: [gone] is conclusive for
/// the task (the orb was deleted out from under it — its sessions are
/// lost with it) even though the composite has no live upstream for it,
/// and [reachable] is the only verdict with a live upstream. The
/// structural contract (issue #277, `orb_upstream_contract.dart`)
/// asserts both consumers' answers equal this derivation for every
/// scenario, so a change to the gate moves every consumer's answer
/// together, not independently.
enum UpstreamVerdict {
  /// The orb passes the reachability gate: an upstream exists, and a 404
  /// for one of its sessions is conclusive.
  reachable,

  /// The orb is in the readable list but has no upstream (not running, no
  /// url, or no password line yet): a 404 is the host fallback, not proof
  /// of a lost session — inconclusive.
  unroutable,

  /// The orb is absent from a readable list: its sessions are gone with it
  /// — the 404 is conclusive.
  gone,

  /// The orb list cannot be read (docker down): no conclusion of any kind
  /// — the degraded host-only answer is inconclusive.
  unknown,
}

/// The agreement (issue #277): the ONE shared derivation from a
/// [UpstreamVerdict] to the two consumers' answers — the sessions
/// composite's routing answer (spec §7.2) and the task service's
/// 404-conclusiveness answer (issue #211/#276).
///
/// Both answers are consequences of the single [OrbUpstream.reachable]
/// gate the verdict is computed from, never independently re-derived:
/// each consumer *asks* the module ([OrbUpstreamSource.live] /
/// [OrbUpstreamSource.verdict]) and reads its answer off this derivation.
/// A consumer that re-derived either answer from its own comparison would
/// drift from the other the moment the gate changed — the per-consumer
/// drift issue #274 deleted. The structural contract
/// (`test/bridge/orb/orb_upstream_contract.dart`, issue #277) drives both
/// consumers through every [UpstreamVerdict] scenario and asserts their
/// answers equal this derivation, so the agreement is pinned, not
/// assumed.
///
/// The two answers are deliberately **not** identical:
/// [UpstreamVerdict.gone] is conclusive for the task (the orb was deleted
/// out from under it — its in-orb sessions are lost with it) even though
/// the composite has no live upstream for it; and
/// [UpstreamVerdict.reachable] is the only verdict with a live upstream.
extension UpstreamVerdictAgreement on UpstreamVerdict {
  /// The sessions composite's routing answer for this verdict (spec §7.2):
  /// does the composite have a live upstream for the orb? Only
  /// [UpstreamVerdict.reachable] — the gate's sole in row — has one:
  /// [UpstreamVerdict.unroutable] (in a readable list, no upstream),
  /// [UpstreamVerdict.gone] (absent from a readable list), and
  /// [UpstreamVerdict.unknown] (the list unreadable — a degraded read must
  /// never claim an upstream exists) all have none.
  bool get hasLiveUpstream => this == UpstreamVerdict.reachable;

  /// The task service's 404-conclusiveness answer for this verdict
  /// (issue #211/#276): is a 404 from the composite conclusive for the
  /// orb — is its missing session actually gone?
  ///
  /// - [UpstreamVerdict.reachable] — the composite has an upstream for the
  ///   orb, so a session it 404s is a gone one: **conclusive**.
  /// - [UpstreamVerdict.gone] — the orb is absent from a readable list
  ///   (deleted out from under the reader): its in-orb sessions are lost
  ///   with it, the 404 is the truth: **conclusive**.
  /// - [UpstreamVerdict.unroutable] — the orb is in a readable list but
  ///   has no upstream (still booting, stopped, broken, url-less, no
  ///   password line yet): the read fell back to a host that cannot know
  ///   the orb session — the 404 is "not routable yet," not "session
  ///   gone": **inconclusive**.
  /// - [UpstreamVerdict.unknown] — the list cannot be read (docker down):
  ///   the composite degrades host-only and nothing may be concluded:
  ///   **inconclusive** (one fact, one conclusion — a degraded read must
  ///   never settle a mid-flight task `failed`).
  bool get missingReadConclusive => switch (this) {
    UpstreamVerdict.reachable || UpstreamVerdict.gone => true,
    UpstreamVerdict.unroutable || UpstreamVerdict.unknown => false,
  };
}

/// The live-upstream facts (issue #274: one producer, read by every
/// consumer): where the running orb list and each orb's current password
/// come from.
///
/// - [live] — the live upstream set with credentials: every running orb
///   that passes the single gate, with its url and password.
/// - [verdict] — the per-orb conclusiveness fact: "is a 404 from the
///   composite meaningful for [orbId] right now?" / "do you have an
///   upstream for it right now?", answered by the same gate.
/// - [records] — the raw running-orb list, un-gated: for a consumer that
///   needs the list itself (the events composite's boot-retry check,
///   issue #278), not the gate's answer for it.
///
/// The list read may throw when docker is down (the composites' own
/// degradation contract, spec §7.2): this module translates that into an
/// empty [live] set, [UpstreamVerdict.unknown], and a `null` [records] —
/// the failure never escapes a read through this module, and a degraded
/// read never claims an upstream exists or a session is gone.
abstract class OrbUpstreamSource {
  /// Every reachable orb right now, with its descriptor (url + password).
  /// Empty — never throwing — when the list cannot be read.
  Future<List<OrbUpstream>> live();

  /// The per-orb reachability verdict for [orbId] (see [UpstreamVerdict]).
  /// [UpstreamVerdict.unknown] — never a throw — when the list cannot be
  /// read.
  Future<UpstreamVerdict> verdict(String orbId);

  /// The raw running-orb list (labels; `url` only for a running orb),
  /// un-gated — `null` when it cannot be read (docker down). The
  /// degradation is a value here, not an escape.
  Future<List<OrbRecord>?> records();
}

/// The source over the real host (issue #274's concrete implementation):
/// the running orb list from [orbService] and the password from the orb's
/// container log — the last `server password` line, parsed by the orb
/// service's own pure parser.
///
/// The password path reuses [OrbService.lastPassword] (and, behind it, the
/// pure [OrbService.lastServerPassword] static): no parser duplication, no
/// caller change — the boot/wake logic keeps reading the same statics off
/// [OrbService]. That method already owns the `docker logs` read and the
/// docker-down → `null` translation, so a single unreadable log is a
/// legitimate gate input (still booting, or docker down for this one
/// read), never an error.
///
/// The list and password are injectable seams — the same two facts the
/// host derives from [orbService] — so the module is unit-testable without
/// docker (mirroring the marker-store seam of the state-machine module: one
/// abstract fact source, one concrete host implementation). When not
/// injected, the seams resolve from [orbService] ([OrbService.list] /
/// [OrbService.lastPassword]); when [orbService] is `null` (a machine with
/// no orbs service) they default to an empty list and a `null` password —
/// the host-only degradation the bridge used for those machines.
class LiveOrbUpstreams implements OrbUpstreamSource {
  LiveOrbUpstreams({
    OrbService? orbService,
    Future<List<OrbRecord>> Function()? orbList,
    Future<String?> Function(String)? orbPassword,
  }) : orbList =
           orbList ??
           (orbService == null
               ? () async => const <OrbRecord>[]
               : orbService.list),
       orbPassword =
           orbPassword ??
           (orbService == null
               ? (String _) async => null
               : orbService.lastPassword);

  /// The running orb list (labels; `url` only for a running orb). May
  /// throw when docker is down (the source degrades: empty [live],
  /// [UpstreamVerdict.unknown], [records] `null`).
  final Future<List<OrbRecord>> Function() orbList;

  /// The orb's current `server password` (the last log line wins on a
  /// respawn, spec §7.1), `null` when it cannot be derived.
  final Future<String?> Function(String orbId) orbPassword;

  @override
  Future<List<OrbUpstream>> live() async {
    final list = await records();
    if (list == null) return const []; // Docker down: host-only, empty.
    final live = <OrbUpstream>[];
    for (final record in list) {
      final upstream = OrbUpstream.reachable(
        id: record.id,
        state: record.state,
        // The url is read off the running record (the list's port-mapping
        // derivation, spec §2.9) — never re-derived here.
        url: record.url,
        password: await orbPassword(record.id),
      );
      if (upstream != null) live.add(upstream);
    }
    return live;
  }

  @override
  Future<UpstreamVerdict> verdict(String orbId) async {
    final list = await records();
    if (list == null) return UpstreamVerdict.unknown;
    for (final record in list) {
      if (record.id != orbId) continue;
      final reachable =
          OrbUpstream.reachable(
            id: record.id,
            state: record.state,
            url: record.url,
            password: await orbPassword(record.id),
          ) !=
          null;
      return reachable ? UpstreamVerdict.reachable : UpstreamVerdict.unroutable;
    }
    return UpstreamVerdict.gone;
  }

  @override
  Future<List<OrbRecord>?> records() async {
    try {
      return await orbList();
    } catch (_) {
      // Docker down (or a torn label pass): the degradation is a value here,
      // not an escape.
      return null;
    }
  }
}
