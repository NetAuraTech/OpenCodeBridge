import '../docker/docker_backend.dart';
import '../events/bridge_event.dart';
import 'orb_build_context.dart';

/// The bridge-side builder of the orb shared base image (spec §5.3, issue
/// #92): it ensures the image for the expected tag exists (auto-build when
/// it is missing) and rebuilds it on demand. The docker CLI invocations go
/// through the same [DockerRunner]/[DockerSpawner] seams as the Docker
/// backend, and the build logs stream onto the unified event stream as
/// [BridgeEventType.orbImageBuild] events, like container logs.
class OrbImageBuilder {
  OrbImageBuilder({
    required this.context,
    required this.run,
    required this.spawn,
    this.emit,
  });

  /// The build context the image is built from (the on-disk build context
  /// is the single source of truth for image content).
  final OrbBuildContext context;

  /// The docker CLI runner (`docker image inspect`).
  final DockerRunner run;

  /// The docker CLI spawner (`docker build`, long-running).
  final DockerSpawner spawn;

  /// Where the build-log events go (the event hub's `emit`); `null` when
  /// this machine has no event hub, in which case the build output is only
  /// drained.
  final void Function(String)? emit;

  /// The expected image tag for what is on disk right now: `orb:<hash>`
  /// (spec §5.3).
  String get expectedTag => context.expectedTag();

  /// Ensure the expected image exists (the auto path, spec §5.3; the first
  /// step of orb creation): when the image for [expectedTag] is missing,
  /// build it (the logs stream as events); when it is present, reuse it
  /// without touching it. Returns the tag.
  Future<String> ensureImage() async {
    final tag = expectedTag;
    if (await imageExists(tag)) return tag;
    return _build(tag);
  }

  /// Always rebuild the expected image (the explicit path, spec §5.3: the
  /// "rebuild" action for when the user bumped the pins and wants the image
  /// without creating an orb). A rebuild never deletes the previous image —
  /// it tags the freshly built one under the current expected tag. Returns
  /// the tag.
  Future<String> rebuild() => _build(expectedTag);

  /// Whether the image [tag] exists on the host (`docker image inspect`). A
  /// daemon failure surfaces as [DockerUnavailableError], not as "missing".
  Future<bool> imageExists(String tag) async {
    final result = await run(['image', 'inspect', tag]);
    if (result.exitCode == 0) return true;
    final stderr = result.stderr.toLowerCase();
    if (stderr.contains('no such image') ||
        stderr.contains('no such object') ||
        stderr.contains('image not found')) {
      return false;
    }
    throw DockerUnavailableError(result.stderr.trim());
  }

  /// Run `docker build -t <tag> <context dir>`, streaming the build's stdout
  /// and stderr lines onto the event stream as [BridgeEventType.orbImageBuild]
  /// events.
  Future<String> _build(String tag) async {
    final process = await spawn(['build', '-t', tag, context.dir.path]);
    void line(String l) {
      final emitter = emit;
      if (emitter == null) return;
      emitter(
        bridgeEvent(
          type: BridgeEventType.orbImageBuild,
          data: {'tag': tag, 'line': l},
        ),
      );
    }

    // Both streams are drained unconditionally (a full pipe would stall the
    // build); the lines only become events when there is a hub.
    final out = process.stdout.listen(line).asFuture<void>();
    final err = process.stderr.listen(line).asFuture<void>();
    await out;
    await err;
    final code = await process.exitCode;
    if (code != 0) throw OrbImageBuildError(tag, code);
    return tag;
  }
}

/// The `docker build` for an orb image exited non-zero (spec §5.3): the
/// streamed build logs carry the reason.
class OrbImageBuildError implements Exception {
  const OrbImageBuildError(this.tag, this.exitCode);

  /// The tag the failed build was for.
  final String tag;

  /// The docker CLI's exit code.
  final int exitCode;

  @override
  String toString() => 'OrbImageBuildError($tag, exit $exitCode)';
}
