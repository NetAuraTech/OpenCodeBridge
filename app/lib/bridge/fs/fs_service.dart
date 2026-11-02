/// The bridge's seam over the host filesystem for the "New project" flow
/// (issue #54): the drives the file-picker dialog starts from and the
/// subdirectories of a directory, one level at a time. A per-OS adapter
/// (ADR-0002): the Linux adapter parses the host's mount table and stats
/// directories; a future Windows adapter is a new implementation of this
/// seam.
abstract class FsService {
  /// The host's drives (the picker's top level), sorted.
  Future<List<String>> drives();

  /// The subdirectories of [path] (directories only, no files), sorted.
  Future<List<String>> subdirectories(String path);
}

/// A failure reading the host filesystem for the "New project" flow, with
/// the [kind] the bridge maps to its HTTP contract and the [path] that
/// failed.
class FsError implements Exception {
  const FsError(this.kind, this.path);

  final FsErrorKind kind;
  final String path;

  @override
  String toString() => 'FsError($kind: $path)';
}

/// The failure kinds of an [FsError]: the bridge maps [badPath] to a 400,
/// [notFound] to a 404, and [permissionDenied] to a 403.
enum FsErrorKind { badPath, notFound, permissionDenied }

final RegExp _windowsDrive = RegExp(r'^[A-Za-z]:[\\/]');

/// Whether [path] is absolute on a host the bridge runs on: POSIX
/// (`/…`) or a Windows drive-letter form (`C:\…` or `C:/…`).
bool isAbsolutePath(String path) =>
    path.startsWith('/') || _windowsDrive.hasMatch(path);
