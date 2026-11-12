import 'dart:io';

import '../sessions/paths.dart';

/// The app-managed opencode binary (issue #153, the ADR-0002 app-owned
/// binary pattern): a pinned version, downloaded into the app's own data
/// directory, updated with the app.
///
/// It is the **last** resolution step of the opencode CLI (issue #153): the
/// `OPENCODE_CLI` environment override, then `opencode` on the PATH (the
/// host install), then this app-managed pinned install. A host with no
/// opencode at all still gets one: the bridge boots the service from the
/// binary it manages itself.
///
/// Pinning is the update mechanism: bump [pinnedVersion] in the app source,
/// and the next app start re-downloads the binary.
class OpencodeBinary {
  OpencodeBinary({
    Directory? dir,
    Future<String> Function()? resolveArch,
    Future<void> Function(Uri url, File target)? downloader,
    Future<void> Function(String archive, File target)? extractor,
    Future<void> Function(String path)? makeExecutable,
  }) : dir = dir ?? OpencodeBinary._hostDir(),
       _resolveArch = resolveArch ?? OpencodeBinary._hostArch,
       _downloader = downloader ?? OpencodeBinary._download,
       _extractor = extractor ?? OpencodeBinary._extract,
       _makeExecutable = makeExecutable ?? OpencodeBinary._chmod;

  /// The pinned opencode version, kept in step with the orb base image's
  /// `OPENCODE_VERSION` (the client/service mix must not drift, issue #173).
  static const String pinnedVersion = '2.2.7';

  static const String _fileName = 'opencode';
  static const String _versionFileName = 'version';

  /// Where the binary lives: the app's own data directory.
  final Directory dir;

  final Future<String> Function() _resolveArch;
  final Future<void> Function(Uri url, File target) _downloader;
  final Future<void> Function(String archive, File target) _extractor;
  final Future<void> Function(String path) _makeExecutable;

  /// The installed binary, after making sure the pinned version is present
  /// (downloading and extracting it first when missing or outdated).
  ///
  /// The download is staged in a temp file and renamed onto the installed
  /// binary only on success (the `CloudflaredBinary` pattern): a failed
  /// re-download of an outdated binary keeps the previously installed one.
  Future<File> ensure() async {
    final binary = File('${dir.path}/$_fileName');
    final versionFile = File('${dir.path}/$_versionFileName');
    if (binary.existsSync() && await _readPinned(versionFile)) {
      return binary;
    }
    final arch = await _resolveArch();
    final url = Uri.parse(_releaseUrl(arch));
    await dir.create(recursive: true);
    final archive = File('${dir.path}/$_fileName.download.tar.gz');
    final staged = File('${dir.path}/$_fileName.download');
    try {
      await _downloader(url, archive);
      // The release asset is a tarball holding a single top-level `opencode`
      // member; extract just that to the staging file, then promote it.
      await _extractor(archive.path, staged);
      await _makeExecutable(staged.path);
      await staged.rename(binary.path);
      await versionFile.writeAsString(pinnedVersion);
    } catch (e) {
      for (final cleanup in [archive, staged]) {
        try {
          await cleanup.delete();
        } catch (_) {
          // The file already does not exist.
        }
      }
      if (e is OpencodeBinaryError) rethrow;
      throw OpencodeBinaryError('the opencode download failed: $e');
    }
    try {
      await archive.delete();
    } catch (_) {
      // The archive already does not exist.
    }
    return binary;
  }

  /// Whether the installed binary already carries [pinnedVersion].
  Future<bool> _readPinned(File versionFile) async {
    try {
      return await versionFile.readAsString() == pinnedVersion;
    } catch (_) {
      return false;
    }
  }

  /// The GitHub release asset for [arch] (`opencode-linux-<arch>.tar.gz`,
  /// the v2 single-binary asset — the tag carries the `v` prefix).
  static String _releaseUrl(String arch) =>
      'https://github.com/anomalyco/opencode/releases/download/'
      'v$pinnedVersion/opencode-linux-$arch.tar.gz';

  /// The app's own data directory (per-user, owned by the app).
  static Directory _hostDir() {
    final dataHome =
        Platform.environment['XDG_DATA_HOME'] ??
        '${homeDirectory()}/.local/share';
    return Directory('$dataHome/opencodebridge/opencode');
  }

  /// The host CPU architecture, as the opencode release asset names it
  /// (`x64` / `arm64`).
  static Future<String> _hostArch() async {
    try {
      final result = await Process.run('uname', ['-m']);
      if (result.exitCode == 0) {
        switch (result.stdout.toString().trim()) {
          case 'x86_64':
            return 'x64';
          case 'aarch64':
          case 'arm64':
            return 'arm64';
        }
      }
    } catch (_) {
      // Fall through to the common default.
    }
    return 'x64';
  }

  /// The default executable-bit setter: `chmod 755` (the app-managed binary
  /// lives on Linux; Dart's `File` exposes no permissions API).
  static Future<void> _chmod(String path) async {
    final result = await Process.run('chmod', ['755', path]);
    if (result.exitCode != 0) {
      throw OpencodeBinaryError('could not make the binary executable');
    }
  }

  /// The default extractor: pull the single `opencode` member of the
  /// tarball to [target] (the member is a top-level file, so `-xOf` streams
  /// its contents).
  static Future<void> _extract(String archive, File target) async {
    final result = await Process.run('tar', ['-xOf', archive, _fileName]);
    if (result.exitCode != 0) {
      throw OpencodeBinaryError(
        'the opencode archive could not be extracted: '
        '${result.stderr.toString().trim()}',
      );
    }
    await target.writeAsBytes(result.stdout as List<int>);
  }

  /// The default downloader: stream the release asset to [target].
  static Future<void> _download(Uri url, File target) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw OpencodeBinaryError(
          'download failed (HTTP ${response.statusCode})',
        );
      }
      final sink = File(target.path).openWrite();
      await response.pipe(sink);
      await sink.close();
    } finally {
      client.close(force: true);
    }
  }
}

/// The opencode binary could not be made available (download failure,
/// network down, …).
class OpencodeBinaryError implements Exception {
  const OpencodeBinaryError(this.message);

  final String message;

  @override
  String toString() => 'OpencodeBinaryError: $message';
}
