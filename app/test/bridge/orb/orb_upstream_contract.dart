// The 404-conclusiveness agreement (issue #277) pinned structurally:
// both consumers — the sessions composite (spec §7.2, issue #275) and the
// orb task service (issue #211/#276) — obtain their side of the answer from
// the ONE module (`lib/bridge/orb/orb_upstreams.dart`, issue #274), as the
// single derivation [UpstreamVerdictAgreement] of the single gate
// ([OrbUpstream.reachable]). No parallel comparison remains in a consumer:
// the composite reconciles on the module's live set, and the task service
// asks the module for the per-orb verdict and reads the module's
// conclusiveness off it.
//
// This is the shared contract helper (the repo's contract pattern —
// `cancel_contract.dart`'s `runCancelContract`, referenced by each
// consumer's test file the same way): each consumer's test file runs
// [runUpstreamAgreement] with its own **answerer** — that consumer, built
// over the scenario's seams and driven through its real read path,
// answering its side of the agreement — and the helper asserts, for
// EVERY [UpstreamVerdict] scenario, that the consumer's answer equals the
// module's derivation for that scenario's verdict. A consumer whose answer
// diverges has re-derived the routing fact in parallel: the per-consumer
// drift issue #274 deleted.
//
// The helper drives a REAL [LiveOrbUpstreams] over the scenario's
// `orbList`/`orbPassword` seams (the docker stand-in — exactly the two
// facts the consumers read, the way `orb_upstreams_test.dart` fakes
// docker): no fake of the module is involved anywhere. The scenario's
// [UpstreamScenario.verdict] is the module's single fact, and the
// module's [UpstreamVerdictAgreement] derivation is the expected answer
// both consumers are held to.
//
// The two sides of the agreement are deliberately NOT identical (the
// module documents the full table): `gone` is conclusive for the task
// (the orb was deleted out from under it — its sessions are lost with it)
// even though the composite has no live upstream for it, and `reachable`
// is the only verdict with a live upstream.
//
// The behaviour pin stays where it is: `orb_completion_resume_test.dart`
// (issue #210's repros — the tracer bullet for the re-arm fix #211, and
// the no-watcher gate, whose faithful window the repro's own header
// concedes cannot be reproduced in-process). This contract pins the
// structural claim that repro could not: that both consumers' answers are
// the one module's derivation, scenario by scenario.

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/docker/docker_backend.dart';
import 'package:opencodebridge/bridge/orb/orb_upstreams.dart';
import 'package:opencodebridge/model/orb.dart';

/// The ephemeral url every in-gate record in the scenarios carries (spec
/// §2.9/§7.1: the list derives it from the port mapping, the module reads
/// it off the record).
const _url = 'http://127.0.0.1:49153';

/// One scenario row of the running orb list (the seams' raw input, spec
/// §2.1's labels composed by the list): [id] named [state], with the
/// ephemeral [url] only when the record carries one.
OrbRecord _record(String id, String state, {String? url}) => OrbRecord(
  id: id,
  name: 'n-$id',
  project: 'proj',
  branch: 'orb/$id',
  state: state,
  created: '2026-01-01T00:00:00.000Z',
  url: url,
);

/// One verdict scenario (issue #277): the seam scripts — the running orb
/// list, the per-orb passwords, the list read's failure — that make a real
/// [LiveOrbUpstreams] answer the scenario's [UpstreamVerdict] for
/// [orbId], the orb the scenario asks about.
///
/// The same scripts are handed to the consumer under test (its own seams
/// read the same two facts — the composite's `orbList`/`orbPassword`
/// closures, the task service's orb service `list`/`lastPassword`), so
/// the consumer's answer and the module's derivation are consequences of
/// the SAME facts: that is what makes the comparison an agreement check
/// rather than two unrelated numbers.
class UpstreamScenario {
  const UpstreamScenario({
    required this.name,
    required this.records,
    required this.passwords,
    required this.orbId,
    this.listError,
  });

  /// The scenario's name (the [UpstreamVerdict] it scripts).
  final String name;

  /// The running orb list the seams read (readable unless [listError]).
  final List<OrbRecord> records;

  /// The per-orb passwords (the last `server password` line each orb's
  /// container log carries, spec §7.1; an absent id has no line yet).
  final Map<String, String?> passwords;

  /// The orb the scenario asks about: "does the composite have a live
  /// upstream for it? / is a 404 from the composite conclusive for it?"
  final String orbId;

  /// The list read's failure (docker down → [UpstreamVerdict.unknown]);
  /// `null` when the list is readable.
  final Object? listError;

  /// The `orbList` seam: the running orb list read, throwing [listError]
  /// when docker is down (the composites' own degradation contract,
  /// spec §7.2 — the failure is a value for the module, never an escape).
  Future<List<OrbRecord>> orbList() =>
      listError == null ? Future.value(records) : Future.error(listError!);

  /// The `orbPassword` seam: the orb's current `server password`
  /// ([passwords], spec §7.1 — the last log line wins), `null` when it
  /// has not landed.
  Future<String?> orbPassword(String id) => Future.value(passwords[id]);

  /// The real source over the scenario's seams (the module's concrete
  /// implementation — no fake of it anywhere in this contract).
  OrbUpstreamSource source() =>
      LiveOrbUpstreams(orbList: orbList, orbPassword: orbPassword);

  /// The module's single fact for the scenario: the per-orb verdict
  /// ([OrbUpstreamSource.verdict] — the same gate, answered per orb).
  Future<UpstreamVerdict> verdict() => source().verdict(orbId);

  /// The module's routing answer for the scenario (the composite's side
  /// of the agreement): does [orbId] have a live upstream? The ONE
  /// derivation [UpstreamVerdictAgreement.hasLiveUpstream] of the
  /// verdict.
  Future<bool> hasUpstream() async => (await verdict()).hasLiveUpstream;

  /// The module's 404-conclusiveness answer for the scenario (the task
  /// service's side of the agreement): is a 404 from the composite
  /// conclusive for [orbId]? The ONE derivation
  /// [UpstreamVerdictAgreement.missingReadConclusive] of the verdict.
  Future<bool> missingReadConclusive() async =>
      (await verdict()).missingReadConclusive;
}

/// The four verdict scenarios (issue #277): one per [UpstreamVerdict] —
/// the gate's in row, its in-list out row, the absent-from-a-readable-list
/// row, and the unreadable-list degradation. The same four every consumer
/// of the module is held to by [runUpstreamAgreement].
final upstreamScenarios = <UpstreamScenario>[
  // The gate's in row (spec §7.1): running, a non-empty url, a password
  // line in the log. The only verdict with a live upstream.
  UpstreamScenario(
    name: 'reachable',
    records: [_record('a', 'running', url: _url)],
    passwords: {'a': 'pwa'},
    orbId: 'a',
  ),
  // In the readable list, but no upstream: still booting — its `server
  // password` line has not landed (issue #211's mid-boot 404: the read
  // falls back to a host that cannot know the orb session).
  UpstreamScenario(
    name: 'unroutable',
    records: [_record('b', 'running', url: _url)],
    passwords: const {},
    orbId: 'b',
  ),
  // Absent from a readable list: deleted out from under the reader — its
  // in-orb sessions are lost with it. The list is readable (the other orb
  // still runs), so this is `gone`, never `unknown`.
  UpstreamScenario(
    name: 'gone',
    records: [_record('a', 'running', url: _url)],
    passwords: {'a': 'pwa'},
    orbId: 'deleted',
  ),
  // The list cannot be read (docker down): the degraded host-only answer —
  // nothing may be concluded, neither "upstream exists" nor "session
  // gone". The would-be-reachable orb in the records is not the point:
  // with docker down even its row is unreadable.
  UpstreamScenario(
    name: 'unknown',
    records: [_record('a', 'running', url: _url)],
    passwords: {'a': 'pwa'},
    orbId: 'a',
    listError: const DockerUnavailableError('docker is down'),
  ),
];

/// A side of the agreement (issue #277): which consumer's answer
/// [runUpstreamAgreement] is checking. The expected answer is ALWAYS the
/// module's derivation for the scenario's verdict (read off
/// [UpstreamVerdictAgreement] — never re-typed by the caller): that is
/// what makes "both consumers obtain the answer from the one module"
/// literal.
enum AgreementSide {
  /// The sessions composite's routing answer (spec §7.2, issue #275):
  /// "does the composite have a live upstream for the orb?" — read off the
  /// module's live set, reconciled by the composite, asserted here as
  /// [UpstreamVerdictAgreement.hasLiveUpstream] of the verdict.
  hasUpstream,

  /// The task service's missing-read answer (issue #211/#276): "is a 404
  /// from the composite conclusive for the orb?" — read off the module's
  /// per-orb verdict, asserted here as
  /// [UpstreamVerdictAgreement.missingReadConclusive].
  missingReadConclusive,
}

/// Runs the shared 404-conclusiveness agreement (issue #277) for one
/// consumer: for EVERY [UpstreamVerdict] scenario in [upstreamScenarios],
/// the consumer's answer must equal the module's derivation for that
/// scenario's verdict.
///
/// [label] is the full, human-readable group title for the suite it runs
/// in (the consumer under test, e.g. `the sessions composite's has-upstream
/// answer (issue #277)`) — each consumer's test file runs its own titled
/// group, so the agreement is literally referenced by both consumers'
/// test files through this one helper.
///
/// [side] selects which answer of the agreement is being checked
/// ([AgreementSide.hasUpstream] for the sessions composite,
/// [AgreementSide.missingReadConclusive] for the task service); the
/// expected answer is then read from the module's
/// [UpstreamVerdictAgreement] derivation for the scenario's verdict — the
/// caller cannot substitute its own copy of the mapping.
///
/// [answer] is the consumer under test's answerer: it builds THAT
/// consumer over the scenario's seams (the same `orbList`/`orbPassword`
/// facts the module's real [LiveOrbUpstreams] reads here) and returns the
/// consumer's answer to the scenario's question — the composite's "does
/// orb X have an upstream?" (its reconciled upstream set, observed
/// through its own read path), the task service's "is a 404 from the
/// composite conclusive for orb X?" (its missing-read window, observed
/// through the settle it does or does not do). A scenario in which the
/// consumer's answer deviates from the module's derivation means the
/// consumer re-derived the routing fact in parallel — the per-consumer
/// drift issue #274 deleted.
void runUpstreamAgreement(
  String label, {
  required AgreementSide side,
  required Future<bool> Function(UpstreamScenario scenario) answer,
}) {
  group(label, () {
    for (final scenario in upstreamScenarios) {
      test('the ${scenario.name} verdict: the consumer answers as the '
          'module derives', () async {
        // The module's single fact for the scenario (a real
        // [LiveOrbUpstreams] over the scenario's seams): the scenario's
        // verdict must be the one it scripts, or the scenario itself is
        // wrong and the rest of the comparison is meaningless.
        final verdict = await scenario.verdict();
        expect(
          verdict,
          UpstreamVerdict.values.byName(scenario.name),
          reason:
              'the ${scenario.name} scenario scripted the wrong '
              'verdict — the scenario is broken, not the consumer',
        );
        // The expected answer: the ONE module-owned derivation
        // ([UpstreamVerdictAgreement]) of that verdict — the same
        // derivation the consumer is supposed to read, never a
        // re-typed copy.
        final expected = side == AgreementSide.hasUpstream
            ? await scenario.hasUpstream()
            : await scenario.missingReadConclusive();
        // The consumer's answer, through its own read path over the same
        // seams.
        final actual = await answer(scenario);
        expect(
          actual,
          expected,
          reason:
              'on the ${scenario.name} verdict (${side.name}: '
              '$expected) the consumer answered $actual — it re-derived '
              'the routing fact in parallel instead of reading the module '
              '(issue #277: the 404 agreement is structural)',
        );
      });
    }
  });
}
