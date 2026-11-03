import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../sessions/paths.dart';
import 'orb_embedded.dart';

/// The app-embedded orb build context (spec §5.2, issue #92), materialized
/// on the host. The app is a built binary — there is no OpenCodeBridge
/// checkout on the host — so the Dockerfile and the boot scripts are embedded
/// in the binary ([OrbEmbedded]) and materialized, **create-if-missing**,
/// into the app-owned build-context dir. From then on the on-disk copy is the
/// single source of truth for image content:
///
/// - an app upgrade never overwrites an existing file, so the pinned
///   versions are under the user's control, never under the running app's;
/// - the tag derives from a content hash of the on-disk context, so the
///   image is in sync with the files by construction (no stale state);
/// - reset = the user deletes the files, and the next startup re-materializes
///   them from the embedded copy.
class OrbBuildContext {
  OrbBuildContext({Directory? dir}) : dir = dir ?? OrbBuildContext.hostDir();

  /// The app-owned build-context dir on the host, `~/.config/opencodebridge/
  /// orb/`: the `docker build` context, same "app-owned files" pattern as the
  /// tunnel's `cloudflared.yml` (ADR-0002).
  static Directory hostDir() =>
      Directory('${homeDirectory()}/.config/opencodebridge/orb');

  /// The build-context dir on disk (the `docker build` context).
  final Directory dir;

  /// The image tag prefix (spec §5.3): tags look like `orb:<hash>`.
  static const String tagPrefix = 'orb:';

  /// How many leading hex characters of [contentHash] go into the tag.
  static const int tagHashLength = 12;

  /// Materialize the embedded build context ([OrbEmbedded.files]) into [dir],
  /// creating [dir] if it is missing. **Create-if-missing, never overwrite**:
  /// a file that already exists on disk is left untouched, because the
  /// on-disk copy is the single source of truth for image content (the
  /// user's pin edits). Safe to call at every startup.
  Future<void> materialize() async {
    final root = dir.path;
    await dir.create(recursive: true);
    for (final entry in OrbEmbedded.files.entries) {
      final file = File('$root/${entry.key}');
      if (file.existsSync()) continue; // The on-disk copy wins.
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
  }

  /// The expected image tag for what is on disk right now (spec §5.3):
  /// `orb:<hash>`, `<hash>` the first [tagHashLength] hex characters of
  /// [contentHash]. The bridge computes the *expected tag* without comparing
  /// anything — the image is missing or it is not.
  String expectedTag() {
    final hash = contentHash();
    return '$tagPrefix${hash.substring(0, tagHashLength)}';
  }

  /// The SHA-256 hex digest over the whole on-disk build context (spec
  /// §5.3): every file under [dir], recursively, in relative-path order, each
  /// contributing its relative path, a NUL, and its raw bytes. The digest
  /// tracks *content*, so an edit to any file (e.g. the user bumping a pin)
  /// changes the tag — and a build for the new tag leaves the existing
  /// image untouched.
  String contentHash() {
    final files = _files();
    final root = dir.path;
    final bytes = BytesBuilder(copy: false);
    for (final file in files) {
      final relative = file.path.substring(root.length + 1);
      bytes.add(utf8.encode(relative));
      bytes.add(const [0]);
      bytes.add(file.readAsBytesSync());
      bytes.add(const [0]);
    }
    return sha256.convert(bytes.takeBytes()).toString();
  }

  /// Every file under [dir], recursively, in relative-path order (a dir
  /// that is not there yet is simply empty).
  List<File> _files() {
    if (!dir.existsSync()) return const [];
    final files = [
      for (final entity in dir.listSync(recursive: true, followLinks: false))
        if (entity is File) entity,
    ];
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }
}
