// The live orb upstreams (issue #274, spec §7.1/§7.2/§7.3): the per-orb
// service descriptor — the ephemeral service URL (the running orb record's
// port mapping, spec §2.9/§7.1) plus the password (the last `server
// password` line of the orb's container log, spec §7.1) — with one home.
//
// The descriptor has no file to read (spec §7.1: a directly-invoked
// `opencode serve` writes no `service.json`): it is re-derived at every
// refresh from the running orb list and the container log. Today the
// derivation has no home — the orb service derives it for its own reads,
// the sessions composite re-derives the descriptor and re-encodes the
// reachability gate to build its upstreams (spec §7.2), the events
// composite carries the identical gate for the events stream (spec §7.3),
// and the task service guesses at it for 404-conclusiveness (issue #211,
// re-derived as a raw `state == 'running'` compare). The orb↔composite
// seam is two bare closures (the list plus the password) that carry no
// shared fact. This module owns both facts:
//
// - the **live upstream set with credentials** ([OrbUpstreamSource.live]):
//   every running orb that passes the reachability gate, with its url and
//   password;
// - the **per-orb reachability verdict** ([OrbUpstreamSource.verdict] →
//   [UpstreamVerdict]): "is a 404 from the composite meaningful for orb X
//   right now?" — the same gate, answered per orb, distinguishing the
//   reachable / unroutable / gone / unknown cases.
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
// the source cannot read (docker down) yields an empty live set and an
// [UpstreamVerdict.unknown] per orb — the host-only, inconclusive answer.
// A degraded read must never claim an upstream exists, nor that a session
// is gone.
//
// No call site reads this module yet — the composites and the task service
// still carry their own derivations. The contract phases (#275 wires the
// composites and the lifecycle pass, #276 the task service's 404
// conclusiveness, #277 pins their agreement structurally, #278 makes the
// bridge seam the module) switch the call sites over and delete the ad-hoc
// derivations.

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

/// The live-upstream facts (issue #274: one producer, read by every
/// consumer): where the running orb list and each orb's current password
/// come from.
///
/// - [live] — the live upstream set with credentials: every running orb
///   that passes the single gate, with its url and password.
/// - [verdict] — the per-orb conclusiveness fact: "is a 404 from the
///   composite meaningful for [orbId] right now?" / "do you have an
///   upstream for it right now?", answered by the same gate.
///
/// The list read may throw when docker is down (the composites' own
/// degradation contract, spec §7.2): this module translates that into an
/// empty [live] set and [UpstreamVerdict.unknown] — the failure never
/// escapes a read through this module, and a degraded read never claims
/// an upstream exists or a session is gone.
abstract class OrbUpstreamSource {
  /// Every reachable orb right now, with its descriptor (url + password).
  /// Empty — never throwing — when the list cannot be read.
  Future<List<OrbUpstream>> live();

  /// The per-orb reachability verdict for [orbId] (see [UpstreamVerdict]).
  /// [UpstreamVerdict.unknown] — never a throw — when the list cannot be
  /// read.
  Future<UpstreamVerdict> verdict(String orbId);
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
/// composites read through their `orbList`/`orbPassword` closures — so the
/// module is unit-testable without docker (mirroring the marker-store seam
/// of the state-machine module: one abstract fact source, one concrete
/// host implementation). The default constructor derives both seams from
/// [orbService]; [LiveOrbUpstreams.fromSeams] (issue #275) takes the
/// composite's own injected seams directly.
class LiveOrbUpstreams implements OrbUpstreamSource {
  LiveOrbUpstreams({
    required OrbService orbService,
    Future<List<OrbRecord>> Function()? orbList,
    Future<String?> Function(String)? orbPassword,
  }) : orbList = orbList ?? orbService.list,
       orbPassword = orbPassword ?? orbService.lastPassword;

  /// The source over the composite's own seams (issue #275's contract
  /// phase): the composites hold their injected `orbList`/`orbPassword`
  /// closures — the same two facts — not an [OrbService], so this builds
  /// the source directly over them. The derivation, the gate, and the
  /// degradation are the same `live()`/[OrbUpstream.reachable] either way.
  LiveOrbUpstreams.fromSeams({
    required this.orbList,
    required this.orbPassword,
  });

  /// The running orb list (labels; `url` only for a running orb). May
  /// throw when docker is down (the source degrades: empty [live],
  /// [UpstreamVerdict.unknown]).
  final Future<List<OrbRecord>> Function() orbList;

  /// The orb's current `server password` (the last log line wins on a
  /// respawn, spec §7.1), `null` when it cannot be derived.
  final Future<String?> Function(String orbId) orbPassword;

  @override
  Future<List<OrbUpstream>> live() async {
    final records = await _records();
    if (records == null) return const []; // Docker down: host-only, empty.
    final live = <OrbUpstream>[];
    for (final record in records) {
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
    final records = await _records();
    if (records == null) return UpstreamVerdict.unknown;
    for (final record in records) {
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

  /// The running orb list, or `null` when it cannot be read (docker down
  /// or a torn label pass): the degradation is a value here, not an
  /// escape.
  Future<List<OrbRecord>?> _records() async {
    try {
      return await orbList();
    } catch (_) {
      return null;
    }
  }
}
