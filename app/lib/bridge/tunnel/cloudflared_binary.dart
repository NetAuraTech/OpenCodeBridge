import 'dart:io';

import '../sessions/paths.dart';

/// The app-managed cloudflared binary (ADR-0002): a pinned version,
/// downloaded into the app's own directory, updated with the app.
///
/// Pinning is the update mechanism: bump [pinnedVersion] in the app source,
/// and the next app start re-downloads the binary. `--no-autoupdate` is
/// always passed at spawn (see `TunnelSupervisor`) — cloudflared's 24 h
/// self-update is incompatible with child supervision and pinning.
class CloudflaredBinary {
  CloudflaredBinary({
    Directory? dir,
    Future<String> Function()? resolveArch,
    Future<void> Function(Uri url, File target)? downloader,
    Future<void> Function(String path)? makeExecutable,
  }) : dir = dir ?? CloudflaredBinary._hostDir(),
       _resolveArch = resolveArch ?? CloudflaredBinary._hostArch,
       _downloader = downloader ?? CloudflaredBinary._download,
       _makeExecutable = makeExecutable ?? CloudflaredBinary._chmod;

  /// The pinned cloudflared version, updated with the app.
  static const String pinnedVersion = '2026.10.7';

  static const String _fileName = 'cloudflared';
  static const String _versionFileName = 'version';

  /// Where the binary lives: the app's own data directory.
  final Directory dir;

  final Future<String> Function() _resolveArch;
  final Future<void> Function(Uri url, File target) _downloader;
  final Future<void> Function(String path) _makeExecutable;

  /// The installed binary, after making sure the pinned version is present
  /// (downloading it first when missing or outdated).
  Future<File> ensure() async {
    final binary = File('${dir.path}/$_fileName');
    final versionFile = File('${dir.path}/$_versionFileName');
    if (binary.existsSync() && await _readPinned(versionFile)) {
      return binary;
    }
    final arch = await _resolveArch();
    final url = Uri.parse(
      'https://github.com/cloudflare/cloudflared/releases/download/'
      'v$pinnedVersion/cloudflared-linux-$arch',
    );
    await dir.create(recursive: true);
    final tmp = File('${dir.path}/$_fileName.download');
    try {
      await _downloader(url, tmp);
      await _makeExecutable(tmp.path);
      await tmp.rename(binary.path);
      await versionFile.writeAsString(pinnedVersion);
    } catch (e) {
      try {
        await tmp.delete();
      } catch (_) {
        // The temp file already does not exist.
      }
      if (e is CloudflaredBinaryError) rethrow;
      throw CloudflaredBinaryError('the cloudflared download failed: $e');
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

  /// The app's own data directory (per-user, owned by the app).
  static Directory _hostDir() {
    final dataHome =
        Platform.environment['XDG_DATA_HOME'] ??
        '${homeDirectory()}/.local/share';
    return Directory('$dataHome/opencodebridge/cloudflared');
  }

  /// The host CPU architecture, as the cloudflared release asset names it.
  static Future<String> _hostArch() async {
    try {
      final result = await Process.run('uname', ['-m']);
      if (result.exitCode == 0) {
        switch (result.stdout.toString().trim()) {
          case 'x86_64':
            return 'amd64';
          case 'aarch64':
            return 'arm64';
          case 'armv7l':
            return 'armhf';
        }
      }
    } catch (_) {
      // Fall through to the common default.
    }
    return 'amd64';
  }

  /// The default executable-bit setter: `chmod 755` (the app-managed binary
  /// lives on Linux; Dart's `File` exposes no permissions API).
  static Future<void> _chmod(String path) async {
    final result = await Process.run('chmod', ['755', path]);
    if (result.exitCode != 0) {
      throw CloudflaredBinaryError('could not make the binary executable');
    }
  }

  /// The default downloader: stream the release asset to [target].
  static Future<void> _download(Uri url, File target) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw CloudflaredBinaryError(
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

/// The cloudflared binary could not be made available (download failure,
/// network down, …).
class CloudflaredBinaryError implements Exception {
  const CloudflaredBinaryError(this.message);

  final String message;

  @override
  String toString() => 'CloudflaredBinaryError: $message';
}
