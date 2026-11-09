import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../sessions/paths.dart';
import 'orb_embedded.dart';

/// The app-embedded orb build context (spec §5.2, issue #92), materialized
/// on the host. The app is a built binary — there is no OpenCodeBridge
/// checkout on the host — so the Dockerfile and the boot scripts are embedded
/// in the binary ([OrbEmbedded]) and materialized into the app-owned
/// build-context dir at every startup, under two contracts (issue #145, see
/// [materialize]): the app's code (the boot scripts) follows the app and is
/// re-written from the embedded copy, the user's pins ([OrbEmbedded.pinnedFiles])
/// are create-if-missing and never overwritten. The on-disk context is the
/// single source of truth for image content *at build time*:
///
/// - an app upgrade never overwrites the user's pin edits, so the pinned
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
  /// creating [dir] if it is missing. Safe to call at every startup.
  ///
  /// **Two classes of files, two contracts** (issue #145):
  ///
  /// - The **app's code** ([OrbEmbedded.files] minus [OrbEmbedded.pinnedFiles]
  ///   — here the entrypoint) is
  ///   re-written from the embedded copy on every startup. It is the
  ///   running app's artefact, not the user's: a copy left from an older
  ///   install is a stale binary the user never chose and cannot see. The
  ///   former create-if-missing froze the 2026-11-05 entrypoint forever
  ///   (60 lines, no `GH_CONFIG_DIR`), so every merged boot fix — #94's
  ///   services, #120's staged gh credentials, #149's shell probe —
  ///   silently never reached an orb, and the image stayed in sync with
  ///   that frozen file by construction.
  /// - The **user's pins** ([OrbEmbedded.pinnedFiles] — the Dockerfile)
  ///   stay **create-if-missing, never overwritten**: the ARG defaults are
  ///   the user's to edit, never the running app's. Reset = delete a file;
  ///   the next startup re-materializes the embedded copy.
  ///
  /// An app rewritten file whose on-disk bytes are the embedded ones writes
  /// nothing, so the tag (and the image) is stable across startups.
  Future<void> materialize() async {
    final root = dir.path;
    await dir.create(recursive: true);
    for (final entry in OrbEmbedded.files.entries) {
      final file = File('$root/${entry.key}');
      if (OrbEmbedded.pinnedFiles.contains(entry.key)) {
        // The user's pins: the on-disk copy wins.
        if (file.existsSync()) continue;
      } else if (file.existsSync() && file.readAsStringSync() == entry.value) {
        // The app's code, already current: keep the bytes (and mtime) as they
        // are, so the content hash is the same.
        continue;
      }
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
