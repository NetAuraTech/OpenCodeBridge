// The per-row orb record composition (issue #291, spec §2.2): the raw facts
// of ONE labeled orb — its labels, its docker status, its port mapping, the
// preparing facts of its log, its workspace-volume and state-dir presence,
// and its host-side marker files behind the [OrbMarkerStore] seam — mapped
// to the one [OrbRecord] the fleet list and the per-orb read compose.
//
// This is the orb service's state-composition concern (issue #291): the
// full-fleet enumeration (the docker `ps` / batched `inspect` / `volume ls`)
// stays in `OrbService.list` because it owns the docker seam, but the
// per-row composition — the pure facts → record mapping — has its own home
// here. That is what lets the service's per-orb read compose a single row
// from a single container's facts instead of paying the whole-fleet
// composition for one row (a one-orb operation that used to loop the fleet
// list).
//
// The record's STATE is composed by [OrbState.compose] (the state machine,
// issue #279): this module feeds it the raw facts and then adds the record
// fields that are not the state string itself — the ephemeral url (the
// running record's port mapping, spec §2.9), the boot-failure reason
// (issue #149), and the push-failed / gh-auth badges (issues #120/#145).
// The precedence and the marker gating are the state machine's, not
// re-derived here.

import 'dart:convert';

import '../../model/orb.dart';
import 'orb_state_machine.dart';

/// Composes the record of ONE labeled container from its raw facts.
///
/// [labels] is the container's `Config.Labels` (the `ocb.*` label set);
/// `null` when the labels carry no `ocb.id` (not an orb). [dockerStatus] is
/// the container's `State.Status` (`running`, `created`, `exited`, …).
/// [portsJson] is the `NetworkSettings.Ports` mapping (the ephemeral url's
/// source, spec §2.9). [bootStage] is the entrypoint's last
/// `[orb] stage: <word>` word of the container log (spec §9.3) and
/// [bootPasswordSeen] whether the log already carries a `server password`
/// line (the boot's completion, spec §7.1) — the two preparing facts, read
/// from the log by the caller. [workspaceVolumePresent] is the labeled
/// workspace volume's presence (`orb-<id>-workspace`) and [stateDirPresent]
/// the per-orb state dir's presence (`<stateRoot>/<id>`), the two broken
/// checks' facts (spec §2.2/§9.4). [markers] is the host-side marker seam
/// (the shell / cleanup-pending / push-failed / gh-auth reads).
/// [inContainerPort] is the fixed in-container port the ephemeral url is
/// mapped from (spec §2.9).
///
/// Returns the composed [OrbRecord], or `null` when [labels] name no orb
/// (no `ocb.id`). The record's state is [OrbState.compose]'s answer for the
/// facts; the url rides on a `running` record only (a booting `preparing`
/// record carries none, as the fleet list composes it); the boot-failure
/// reason rides on a `broken:shell` record; the push-failed and gh-auth
/// badges ride on every record that is neither an orphan nor broken.
OrbRecord? composeOrbRow({
  required Map<String, Object?> labels,
  required String dockerStatus,
  required String portsJson,
  required String? bootStage,
  required bool? bootPasswordSeen,
  required bool workspaceVolumePresent,
  required bool stateDirPresent,
  required OrbMarkerStore markers,
  required int inContainerPort,
}) {
  final id = labels['ocb.id'];
  if (id is! String || id.isEmpty) return null;

  // The shell marker's cause (issue #149, spec §6.8): it feeds the state
  // composition (the `broken:shell` badge) and rides on the record as the
  // boot-failure reason — read once, used for both.
  final shellFailedReason = markers.shellFailedReason(id);

  // The state from the state machine's raw-facts composition (issue #279):
  // the marker reads feed it (the shell / cleanup-pending badges), and its
  // precedence owns when they apply (the stopped branch only).
  final state = OrbState.compose(
    dockerStatus: dockerStatus,
    workspaceVolumePresent: workspaceVolumePresent,
    stateDirPresent: stateDirPresent,
    bootStage: bootStage,
    bootPasswordSeen: bootPasswordSeen,
    shellFailedReason: shellFailedReason,
    cleanupReason: markers.cleanupPendingReason(id),
  );

  // The ephemeral url (spec §2.9): the running record's port mapping, read
  // off the `running` state — a `preparing` record (a running container
  // before its password line) carries none, matching the fleet list.
  final url = state.isRunning ? _portUrl(portsJson, inContainerPort) : null;

  var record = OrbRecord(
    id: id,
    name: labels['ocb.name'] as String? ?? '',
    project: labels['ocb.project'] as String? ?? '',
    branch: labels['ocb.branch'] as String? ?? '',
    state: state.wire,
    created: labels['ocb.created'] as String? ?? '',
    url: url,
    base: labels['ocb.base'] as String?,
  );

  // The boot-failure reason (issue #149, spec §6.8): the shell probe's fatal
  // line rides on the record, not the state string.
  if (state.kind == OrbStateKind.brokenShell) {
    record = _withBootReason(record, shellFailedReason ?? 'no usable shell');
  }

  // The push-failed (#120) and gh-auth (#145) badges: every record that is
  // neither an orphan (its marker is stale by construction) nor broken (the
  // missing volume/dir is the louder signal) — read off the composed state's
  // own predicates, the state string is not re-parsed here.
  if (!state.isOrphan && !state.isBroken) {
    if (markers.pushFailed(id)) record = _withPushFailing(record);
    final ghAuthFailed = markers.ghAuthFailedReason(id);
    if (ghAuthFailed != null) record = _withGhAuthFailure(record, ghAuthFailed);
  }
  return record;
}

/// The orphan's record from a labeled volume's [labels] (spec §2.2): labeled
/// volumes without a container, surfaced for explicit cleanup, never
/// auto-deleted. [id] is the volume's `ocb.id` (== the volume-name id).
OrbRecord orphanOrbRow(String id, Map<String, Object?> labels) => OrbRecord(
  id: id,
  name: labels['ocb.name'] as String? ?? '',
  project: labels['ocb.project'] as String? ?? '',
  branch: labels['ocb.branch'] as String? ?? '',
  state: OrbState.orphanWire,
  created: labels['ocb.created'] as String? ?? '',
  base: labels['ocb.base'] as String?,
);

/// The orb id a labeled volume name encodes (`orb-<id>-workspace` /
/// `orb-<id>-data`), or `null` for an unrelated volume name.
String? orbVolumeId(String volumeName) {
  final match = RegExp(r'^orb-(.+)-(workspace|data)$').firstMatch(volumeName);
  return match?.group(1);
}

/// The ephemeral url of [portsJson] (spec §2.9): the host port bound to
/// [inContainerPort], as `http://127.0.0.1:<port>` — `null` when the mapping
/// carries no binding (the record then has no url, as the fleet list composes
/// it). Parsed with [jsonDecode] exactly as the fleet list's container record
/// parsed it (`'null'` → no binding; a malformed mapping is an error).
String? _portUrl(String portsJson, int inContainerPort) {
  final parsed = jsonDecode(portsJson);
  final ports = parsed is Map<String, Object?> ? parsed : const {};
  final bindings = ports['$inContainerPort/tcp'];
  if (bindings is List) {
    for (final entry in bindings) {
      if (entry is Map<String, Object?>) {
        final hostPort = entry['HostPort'];
        if (hostPort is String && hostPort.isNotEmpty) {
          return 'http://127.0.0.1:$hostPort';
        }
      }
    }
  }
  return null;
}

/// [record] with its boot-failure reason set (issue #149) — every other
/// field a copy.
OrbRecord _withBootReason(OrbRecord record, String reason) => OrbRecord(
  id: record.id,
  name: record.name,
  project: record.project,
  branch: record.branch,
  state: record.state,
  created: record.created,
  url: record.url,
  pr: record.pr,
  base: record.base,
  pushFailing: record.pushFailing,
  ghAuthFailed: record.ghAuthFailed,
  bootReason: reason,
);

/// [record] with its push-failed badge set (issue #120) — every other field
/// a copy.
OrbRecord _withPushFailing(OrbRecord record) => OrbRecord(
  id: record.id,
  name: record.name,
  project: record.project,
  branch: record.branch,
  state: record.state,
  created: record.created,
  url: record.url,
  pr: record.pr,
  base: record.base,
  pushFailing: true,
  ghAuthFailed: record.ghAuthFailed,
  bootReason: record.bootReason,
);

/// [record] carrying its gh-auth failure cause (issue #145) — every other
/// field a copy.
OrbRecord _withGhAuthFailure(OrbRecord record, String reason) => OrbRecord(
  id: record.id,
  name: record.name,
  project: record.project,
  branch: record.branch,
  state: record.state,
  created: record.created,
  url: record.url,
  pr: record.pr,
  base: record.base,
  pushFailing: record.pushFailing,
  ghAuthFailed: reason,
  bootReason: record.bootReason,
);
