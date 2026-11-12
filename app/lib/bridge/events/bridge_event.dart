import 'dart:convert';
import 'dart:math';

/// The event types the bridge itself produces, multiplexed onto the unified
/// `GET /api/events` stream (spec §8). They are not opencode events: they carry
/// no durable seq (so they never collide with the per-session durable `seq`
/// gap detection) and are applied by the app as side-effects keyed on `type`.
abstract class BridgeEventType {
  /// A session was deleted (the app-initiated `DELETE`), so every connected
  /// app drops it from its list.
  static const String sessionClosed = 'session.closed';

  /// A session's turn was cancelled (a Stop from a panel, issue #164): the
  /// bridge carries it out and reports the outcome to every watcher, not only
  /// the panel that asked. `data` carries `sessionID` and — when a message was
  /// in flight — `messageID`. No durable seq (a bridge-native side-effect,
  /// like `session.closed`); an idle session's cancel emits no event at all.
  static const String turnCancelled = 'session.turn.cancelled';

  /// A container transitioned to stopped (clean). (Wired as Docker lands.)
  static const String dockerContainerStopped = 'docker.container.stopped';

  /// A container exited abnormally (non-zero exit). (Wired as Docker lands.)
  static const String dockerContainerCrashed = 'docker.container.crashed';

  /// The local llama.cpp server's live throughput, from its `/stream` SSE
  /// (the bridge's [LlamaSpeedFeed]). `data` carries `prefill` and `decode`
  /// (each a tok/s number or `null`); at most one is set at a time.
  static const String llamaSpeed = 'llama.speed';

  /// One line of the orb shared base image's `docker build` output (spec
  /// §5.3, issue #92): the build's logs stream as events, like container
  /// logs. `data` carries `tag` (the `orb:<hash>` being built) and `line`
  /// (one line of the build log).
  static const String orbImageBuild = 'orb.image.build';

  /// One line of an orb's container output during its boot (issue #93):
  /// the staged boot log the create flow streams as the entrypoint runs
  /// (clone, hook, gitconfig — spec §6.3) and `opencode serve` starts.
  /// `data` carries `id` (the orb id) and `line` (one line of the
  /// container log).
  static const String orbBoot = 'orb.boot';

  /// One line of the host opencode service's boot log (issue #153): the
  /// `opencode serve` child's output (the `server listening on …` /
  /// `server password …` lines, the ready line, and the boot's reason on
  /// failure). `data` carries `line`. This is the "log surface" a failed
  /// boot is visible on; the health report carries the outcome.
  static const String opencodeBoot = 'opencode.boot';
}

/// Build the wire payload for a bridge-native event: the same `data:` envelope
/// shape as an opencode event (`{id, created, type, data}`) but with **no**
/// `durable` field. The returned string is what [EventHub.emit] fans out, so it
/// is written to the stream verbatim as `data: <payload>`.
String bridgeEvent({
  required String type,
  required Map<String, Object?> data,
  String? id,
  int? created,
  Random? random,
}) {
  final payload = <String, Object?>{
    'id': id ?? _eventId(random ?? _random),
    'created': created ?? DateTime.now().millisecondsSinceEpoch,
    'type': type,
    'data': data,
  };
  return jsonEncode(payload);
}

final Random _random = Random();

String _eventId(Random random) =>
    'evt_${random.nextInt(1 << 32).toRadixString(32)}';
