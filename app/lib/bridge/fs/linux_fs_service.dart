import 'dart:io';

import 'fs_service.dart';
import 'mounts.dart';

/// The [FsService] for a Linux host (ADR-0002's Linux adapter): the drives
/// come from the host's mount table ([mountsPath], `/proc/self/mounts` by
/// default) kept while still mounted and stat-able, and the
/// subdirectories come from the host's filesystem.
class LinuxFsService implements FsService {
  const LinuxFsService({this.mountsPath = '/proc/self/mounts'});

  /// The mount table the drives come from; tests point it at a fixture.
  final String mountsPath;

  @override
  Future<List<String>> drives() async {
    final String content;
    try {
      content = File(mountsPath).readAsStringSync();
    } on FileSystemException {
      // No readable mount table: the picker shows no drives rather than fail.
      return const [];
    }
    return [
      for (final point in mountPoints(content))
        if (_isDirectory(point)) point,
    ];
  }

  @override
  Future<void> createDirectory(String path) async {
    if (!isAbsolutePath(path)) {
      throw FsError(FsErrorKind.badPath, path);
    }
    final parent = _parentOf(path);
    if (_statType(parent) != FileSystemEntityType.directory) {
      throw FsError(FsErrorKind.notFound, parent);
    }
    // A pre-check: dart:io's createSync is idempotent on an existing
    // directory, so the already-exists case would otherwise slip through.
    final existing = _statType(path);
    if (existing != null && existing != FileSystemEntityType.notFound) {
      throw FsError(FsErrorKind.alreadyExists, path);
    }
    // The EACCES of a mode-000 parent surfaces here, not on the stat above
    // (the kernel answers ENOENT for a missing path under a directory it
    // refuses to search).
    try {
      Directory(path).createSync();
    } on FileSystemException catch (e) {
      final message = e.osError?.message ?? '';
      if (message.contains('Permission denied')) {
        throw FsError(FsErrorKind.permissionDenied, path);
      }
      if (message.contains('File exists')) {
        throw FsError(FsErrorKind.alreadyExists, path);
      }
      rethrow;
    }
  }

  /// The type of [path] for the create check; a permission denial is an
  /// [FsError]([FsErrorKind.permissionDenied]) (the entry exists but is not
  /// ours to stat), a missing entry is [FileSystemEntityType.notFound], and
  /// some other stat failure is `null`.
  static FileSystemEntityType? _statType(String path) {
    try {
      return File(path).statSync().type;
    } on FileSystemException catch (e) {
      if (e.osError?.message.contains('Permission denied') ?? false) {
        throw FsError(FsErrorKind.permissionDenied, path);
      }
      return null;
    }
  }

  /// The parent directory of the absolute path [path] (`/` for a root entry).
  static String _parentOf(String path) {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '/' : path.substring(0, i);
  }

  @override
  Future<List<String>> subdirectories(String path) async {
    if (!isAbsolutePath(path)) {
      throw FsError(FsErrorKind.badPath, path);
    }
    final FileSystemEntityType type;
    try {
      type = FileSystemEntity.typeSync(path);
    } on FileSystemException {
      throw FsError(FsErrorKind.notFound, path);
    }
    if (type != FileSystemEntityType.directory) {
      throw FsError(FsErrorKind.notFound, path);
    }
    final dir = Directory(path);
    final names = _entryNames(dir, path);
    final subdirectories = <String>[
      for (final name in names)
        if (_isDirectory(_join(dir.path, name))) _join(dir.path, name),
    ];
    subdirectories.sort();
    return subdirectories;
  }

  /// The entry names of [dir], or an [FsError]
  /// ([FsErrorKind.permissionDenied]) when it cannot be read.
  static List<String> _entryNames(Directory dir, String path) {
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync();
    } on FileSystemException catch (e) {
      // A refusal to list (a mode-000 directory, …) is the bridge contract's
      // [FsErrorKind.permissionDenied].
      if (e.osError?.message.contains('Permission denied') ?? false) {
        throw FsError(FsErrorKind.permissionDenied, path);
      }
      rethrow;
    }
    return [for (final entity in entries) _nameOf(entity)];
  }

  static String _nameOf(FileSystemEntity entity) {
    final p = entity.path;
    final i = p.lastIndexOf('/');
    return i < 0 ? p : p.substring(i + 1);
  }

  /// Joins [name] onto the directory [dir] without doubling the root's
  /// slash.
  static String _join(String dir, String name) =>
      dir.endsWith('/') ? '$dir$name' : '$dir/$name';

  /// Whether [path] is a directory (a symlink to a directory counts); a
  /// broken symlink or any stat failure is not.
  static bool _isDirectory(String path) {
    try {
      return File(path).statSync().type == FileSystemEntityType.directory;
    } on FileSystemException {
      return false;
    }
  }
}
