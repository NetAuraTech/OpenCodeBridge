// The orb lifecycle's state machine (issue #279, spec §2.1/§2.2/§2.7/§2.10/
// §9.4): the named states, the raw-facts composition, and the per-action
// predicates, each tested against the full state set — including the
// `broken:` and `cleanup_pending:` variants.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/orb/orb_state_machine.dart';

/// The full state set (spec §2.2): the base states, the two preparing and
/// cleanup-pending sub-states with a detail, the three broken parts, and
/// one unknown string outside the set (the refusal, not an admission).
const _states = <(String, OrbStateKind?)>[
  ('running', OrbStateKind.running),
  ('stopped', OrbStateKind.stopped),
  ('preparing', OrbStateKind.preparing),
  ('preparing:clone', OrbStateKind.preparing),
  ('cleanup_pending', OrbStateKind.cleanupPending),
  ('cleanup_pending:uncommitted work', OrbStateKind.cleanupPending),
  ('broken:workspace', OrbStateKind.brokenWorkspace),
  ('broken:state', OrbStateKind.brokenState),
  ('broken:shell', OrbStateKind.brokenShell),
  ('orphan', OrbStateKind.orphan),
  ('something:else', null),
  ('', null),
];

void main() {
  group('OrbState.parse / kind / detail', () {
    test('every named state parses to its kind, with its detail', () {
      for (final (wire, kind) in _states) {
        final state = OrbState.parse(wire);
        expect(state.wire, wire, reason: 'wire of $wire');
        expect(state.kind, kind, reason: 'kind of $wire');
        expect(state.isKnown, kind != null, reason: 'isKnown of $wire');
      }
    });

    test('the detail is the sub-state after the colon', () {
      expect(OrbState.parse('preparing:clone').detail, 'clone');
      expect(
        OrbState.parse('cleanup_pending:uncommitted work').detail,
        'uncommitted work',
      );
      expect(OrbState.parse('running').detail, isNull);
      expect(OrbState.parse('preparing:').detail, isNull);
    });

    test('base / detailOf split a wire string tolerantly', () {
      expect(OrbState.base('preparing:clone'), 'preparing');
      expect(OrbState.base('running'), 'running');
      expect(OrbState.base(''), '');
      expect(OrbState.detailOf('preparing:clone'), 'clone');
      expect(OrbState.detailOf('preparing:'), isNull);
      expect(OrbState.detailOf('running'), isNull);
    });

    test('a broken part outside the three is not a named state', () {
      expect(OrbState.parse('broken:disk').kind, isNull);
      expect(OrbState.parse('broken:').kind, isNull);
    });
  });

  group('OrbState.compose — the raw facts map to the named states', () {
    OrbState compose({
      String? dockerStatus = 'running',
      bool workspace = true,
      bool stateDir = true,
      String? bootStage,
      bool? passwordSeen = true,
      String? shellFailed,
      String? cleanup,
    }) =>
      OrbState.compose(
        dockerStatus: dockerStatus,
        workspaceVolumePresent: workspace,
        stateDirPresent: stateDir,
        bootStage: bootStage,
        bootPasswordSeen: passwordSeen,
        shellFailedReason: shellFailed,
        cleanupReason: cleanup,
      );

    test('a running container with a finished boot is running', () {
      expect(compose().wire, 'running');
    });

    test('a created container is preparing (no stage yet)', () {
      expect(compose(dockerStatus: 'created', passwordSeen: null).wire,
          'preparing');
    });

    test('a created container with a boot stage is preparing:<stage>', () {
      expect(
        compose(dockerStatus: 'created', passwordSeen: null, bootStage: 'clone')
            .wire,
        'preparing:clone',
      );
    });

    test('a running container before its password line is still preparing',
        () {
      expect(
        compose(
          dockerStatus: 'running',
          passwordSeen: false,
          bootStage: 'clone',
        ).wire,
        'preparing:clone',
      );
      // No stage yet (the log is empty): plain preparing.
      expect(
        compose(dockerStatus: 'running', passwordSeen: false).wire,
        'preparing',
      );
    });

    test('an exited container with everything present is stopped', () {
      expect(compose(dockerStatus: 'exited', passwordSeen: null).wire,
          'stopped');
    });

    test('a missing workspace volume is broken:workspace (the louder signal)',
        () {
      expect(
        compose(
          dockerStatus: 'exited',
          passwordSeen: null,
          workspace: false,
          cleanup: 'uncommitted work',
        ).wire,
        'broken:workspace',
      );
      // And over a running container that is not booting: the broken checks
      // do not run on the running side — the orb is running.
      expect(compose(workspace: false).wire, 'running');
    });

    test('a missing state dir is broken:state', () {
      expect(
        compose(
          dockerStatus: 'exited',
          passwordSeen: null,
          stateDir: false,
          cleanup: 'uncommitted work',
        ).wire,
        'broken:state',
      );
    });

    test('a stopped container whose boot died at the shell probe is '
        'broken:shell (over the cleanup badge)', () {
      expect(
        compose(
          dockerStatus: 'exited',
          passwordSeen: null,
          shellFailed: 'shell: no login shell found',
          cleanup: 'uncommitted work',
        ).wire,
        'broken:shell',
      );
    });

    test('a stopped container under the lifecycle pass badge is '
        'cleanup_pending:<reason>', () {
      expect(
        compose(
          dockerStatus: 'exited',
          passwordSeen: null,
          cleanup: 'uncommitted work',
        ).wire,
        'cleanup_pending:uncommitted work',
      );
      // An empty badge is no badge.
      expect(
        compose(dockerStatus: 'exited', passwordSeen: null, cleanup: '').wire,
        'stopped',
      );
    });

    test('a running container ignores the shell and cleanup markers '
        '(the finished boot wins)', () {
      expect(
        compose(shellFailed: 'x', cleanup: 'y').wire,
        'running',
      );
    });

    test('no container (volumes only) is orphan', () {
      expect(compose(dockerStatus: null, workspace: true, stateDir: false)
          .wire,
          'orphan');
    });
  });

  group('the per-action predicates — the full state set', () {
    OrbState s(String wire) => OrbState.parse(wire);

    test('isStopable: only running', () {
      expect(s('running').isStopable, isTrue);
      for (final (wire, _) in _states) {
        if (wire == 'running') continue;
        expect(s(wire).isStopable, isFalse, reason: wire);
      }
    });

    test('isWakeable: stopped and the cleanup_pending variants only', () {
      expect(s('stopped').isWakeable, isTrue);
      expect(s('cleanup_pending:uncommitted work').isWakeable, isTrue);
      expect(s('cleanup_pending').isWakeable, isTrue);
      for (final (wire, _) in _states) {
        if (wire == 'stopped' || wire.startsWith('cleanup_pending')) continue;
        expect(s(wire).isWakeable, isFalse, reason: wire);
      }
    });

    test('isUpdatable: running, stopped, and the cleanup_pending variants',
        () {
      expect(s('running').isUpdatable, isTrue);
      expect(s('stopped').isUpdatable, isTrue);
      expect(s('cleanup_pending:uncommitted work').isUpdatable, isTrue);
      for (final (wire, _) in _states) {
        if (wire == 'running' ||
            wire == 'stopped' ||
            wire.startsWith('cleanup_pending')) {
          continue;
        }
        expect(s(wire).isUpdatable, isFalse, reason: wire);
      }
    });

    test('isFreshStateStartable: only broken:state', () {
      expect(s('broken:state').isFreshStateStartable, isTrue);
      for (final (wire, _) in _states) {
        if (wire == 'broken:state') continue;
        expect(s(wire).isFreshStateStartable, isFalse, reason: wire);
      }
    });

    test('isSpawable: running, stopped, and the cleanup_pending variants',
        () {
      expect(s('running').isSpawable, isTrue);
      expect(s('stopped').isSpawable, isTrue);
      expect(s('cleanup_pending:uncommitted work').isSpawable, isTrue);
      for (final (wire, _) in _states) {
        if (wire == 'running' ||
            wire == 'stopped' ||
            wire.startsWith('cleanup_pending')) {
          continue;
        }
        expect(s(wire).isSpawable, isFalse, reason: wire);
      }
    });

    test('isForceDeletable: running, stopped/cleanup-pending, and broken — '
        'not preparing or orphan', () {
      expect(s('running').isForceDeletable, isTrue);
      expect(s('stopped').isForceDeletable, isTrue);
      expect(s('cleanup_pending:uncommitted work').isForceDeletable, isTrue);
      expect(s('broken:workspace').isForceDeletable, isTrue);
      expect(s('broken:state').isForceDeletable, isTrue);
      expect(s('broken:shell').isForceDeletable, isTrue);
      for (final (wire, _) in _states) {
        if (wire == 'running' ||
            wire == 'stopped' ||
            wire.startsWith('cleanup_pending') ||
            wire.startsWith('broken:')) {
          continue;
        }
        expect(s(wire).isForceDeletable, isFalse, reason: wire);
      }
    });

    test('the unknown state refuses every action (the refusal, not an '
        'admission)', () {
      final unknown = s('something:else');
      expect(unknown.isKnown, isFalse);
      expect(unknown.isStopable, isFalse);
      expect(unknown.isWakeable, isFalse);
      expect(unknown.isUpdatable, isFalse);
      expect(unknown.isFreshStateStartable, isFalse);
      expect(unknown.isSpawable, isFalse);
      expect(unknown.isForceDeletable, isFalse);
    });
  });

  group('the base-state accessors', () {
    test('isStoppedLike: the stopped family only', () {
      expect(OrbState.parse('stopped').isStoppedLike, isTrue);
      expect(OrbState.parse('cleanup_pending:x').isStoppedLike, isTrue);
      expect(OrbState.parse('running').isStoppedLike, isFalse);
      expect(OrbState.parse('broken:state').isStoppedLike, isFalse);
    });

    test('isPreparing / isBroken / the broken parts / isOrphan', () {
      expect(OrbState.parse('preparing:x').isPreparing, isTrue);
      expect(OrbState.parse('running').isPreparing, isFalse);
      expect(OrbState.parse('broken:workspace').isBroken, isTrue);
      expect(OrbState.parse('broken:state').isBroken, isTrue);
      expect(OrbState.parse('broken:shell').isBroken, isTrue);
      expect(OrbState.parse('stopped').isBroken, isFalse);
      expect(OrbState.parse('broken:state').isBrokenState, isTrue);
      expect(OrbState.parse('broken:workspace').isBrokenState, isFalse);
      expect(OrbState.parse('broken:shell').isBrokenShell, isTrue);
      expect(OrbState.parse('orphan').isOrphan, isTrue);
      expect(OrbState.parse('running').isOrphan, isFalse);
    });
  });

  group('the composed state round-trips through the predicates', () {
    test('every state the composition can produce is a named one', () {
      final produced = <String>{
        for (final docker in [
          null,
          'running',
          'created',
          'exited',
          'dead',
        ])
          for (final workspace in [true, false])
            for (final stateDir in [true, false])
              for (final stage in [null, 'clone'])
                for (final password in [true, false, null])
                  for (final shell in [null, 'shell: none'])
                    for (final cleanup in [null, 'uncommitted work'])
                      OrbState.compose(
                        dockerStatus: docker,
                        workspaceVolumePresent: workspace,
                        stateDirPresent: stateDir,
                        bootStage: stage,
                        bootPasswordSeen: password,
                        shellFailedReason: shell,
                        cleanupReason: cleanup,
                      ).wire,
      };
      for (final wire in produced) {
        expect(OrbState.parse(wire).isKnown, isTrue, reason: wire);
      }
    });
  });

  group('FileOrbMarkerStore — the marker files behind the seam', () {
    late Directory tmp;
    late FileOrbMarkerStore store;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ocb-orb-state-test');
      store = FileOrbMarkerStore(tmp);
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('the stop marker: absent, set, cleared', () async {
      expect(store.stopped('a'), isFalse);
      await store.setStopped('a');
      expect(store.stopped('a'), isTrue);
      expect(
        File('${tmp.path}/a/stopped').readAsStringSync(),
        isNotEmpty,
        reason: 'the stop marker carries the stop time',
      );
      await store.clearStopped('a');
      expect(store.stopped('a'), isFalse);
      // A clear of an absent marker is a no-op.
      await store.clearStopped('a');
    });

    test(
        'the cleanup-pending marker: mark carries the reason, clear drops '
        'it, and an empty marker is no badge', () async {
      expect(store.cleanupPendingReason('a'), isNull);
      await store.markCleanupPending('a', 'uncommitted work');
      expect(store.cleanupPendingReason('a'), 'uncommitted work');
      await store.markCleanupPending('a', '');
      expect(store.cleanupPendingReason('a'), isNull);
      await store.markCleanupPending('a', 'unpushed work');
      expect(store.cleanupPendingReason('a'), 'unpushed work');
      await store.clearCleanupPending('a');
      expect(store.cleanupPendingReason('a'), isNull);
    });

    test('the push-failed marker: presence, generation, clear', () async {
      expect(store.pushFailed('a'), isFalse);
      expect(store.pushFailedGeneration('a'), isNull);
      final marker = File('${tmp.path}/a/push-failed');
      await store.stateDir('a').create(recursive: true);
      await marker.writeAsString('push failed');
      expect(store.pushFailed('a'), isTrue);
      final generation = store.pushFailedGeneration('a');
      expect(generation, isNotNull);
      expect(store.pushFailedGeneration('a'), generation);
      await store.clearPushFailed('a');
      expect(store.pushFailed('a'), isFalse);
      expect(store.pushFailedGeneration('a'), isNull);
    });

    test('the no-shell marker: the cause, and an empty marker names itself',
        () async {
      expect(store.shellFailedReason('a'), isNull);
      final dir = await store.stateDir('a').create(recursive: true);
      await File('${dir.path}/no-shell').writeAsString('shell: no login');
      expect(store.shellFailedReason('a'), 'shell: no login');
      await File('${dir.path}/no-shell').writeAsString('');
      expect(store.shellFailedReason('a'), 'no usable shell');
    });

    test('the gh-auth marker: mark carries the cause, clear drops it',
        () async {
      expect(store.ghAuthFailedReason('a'), isNull);
      await store.markGhAuthFailed('a', 'token invalid');
      expect(store.ghAuthFailedReason('a'), 'token invalid');
      await store.markGhAuthFailed('a', '');
      expect(store.ghAuthFailedReason('a'), 'gh could not authenticate');
      await store.clearGhAuthFailed('a');
      expect(store.ghAuthFailedReason('a'), isNull);
    });

    test('a composed state from the store agrees with the raw facts',
        () async {
      // A stopped orb the pass has surfaced as guard-blocked.
      await store.stateDir('a').create(recursive: true);
      await store.setStopped('a');
      await store.markCleanupPending('a', 'unpushed work');
      final state = OrbState.compose(
        dockerStatus: 'exited',
        workspaceVolumePresent: true,
        stateDirPresent: store.stateDir('a').existsSync(),
        shellFailedReason: store.shellFailedReason('a'),
        cleanupReason: store.cleanupPendingReason('a'),
      );
      expect(state.wire, 'cleanup_pending:unpushed work');
      expect(state.isWakeable, isTrue);
      expect(state.isUpdatable, isTrue);
      expect(state.isForceDeletable, isTrue);
    });
  });
}
