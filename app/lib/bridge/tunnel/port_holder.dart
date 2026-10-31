import 'dart:io';

/// The process listening on a port, as resolved on the host.
class PortHolder {
  const PortHolder({required this.pid, required this.isCloudflared});

  /// The pid of the listening process.
  final int pid;

  /// Whether the listener is a cloudflared process (an orphaned tunnel).
  final bool isCloudflared;
}

/// Resolves who listens on [port], or `null` when nothing does.
typedef PortHolderProbe = Future<PortHolder?> Function(int port);

/// The default [PortHolderProbe] for the host (Linux, /proc).
Future<PortHolder?> portHolderProbe(int port) async {
  final inodes = _listenInodes(port);
  if (inodes.isEmpty) return null;
  for (final pid in _processPids()) {
    if (_pidHoldsSocket(pid, inodes)) {
      return PortHolder(pid: pid, isCloudflared: isCloudflaredProcess(pid));
    }
  }
  return null;
}

const String procPath = '/proc/';

/// Whether the process [pid] is a cloudflared process (argv[0] named
/// `cloudflared`, app-managed or installed).
bool isCloudflaredProcess(int pid) {
  try {
    final cmdline = File('$procPath$pid/cmdline').readAsStringSync();
    final first = cmdline.split('\x00').first;
    if (first.isEmpty) return false;
    final base = first.split('/').last;
    return base == 'cloudflared' || base.startsWith('cloudflared-');
  } catch (_) {
    return false;
  }
}

/// The socket inodes of the tcp listeners on [port], from
/// `/proc/net/tcp` and `/proc/net/tcp6`.
Set<int> _listenInodes(int port) {
  final inodes = <int>{};
  final target = port.toRadixString(16);
  for (final table in ['$procPath/net/tcp', '$procPath/net/tcp6']) {
    String? content;
    try {
      content = File(table).readAsStringSync();
    } catch (_) {
      continue; // No such table on this kernel.
    }
    for (final line in content.split('\n').skip(1)) {
      final fields = line.trim().split(RegExp(r'\s+'));
      // sl local rem st tx:rx tr:tm retrnsmt uid timeout inode ...
      if (fields.length < 10) continue;
      if (fields[1].split(':').last.toLowerCase() != target) continue;
      if (fields[3] != '0A') continue; // Not LISTEN.
      final inode = int.tryParse(fields[9]);
      if (inode != null && inode != 0) inodes.add(inode);
    }
  }
  return inodes;
}

List<int> _processPids() {
  final pids = <int>[];
  try {
    for (final entry in Directory(procPath).listSync()) {
      final pid = int.tryParse(entry.path.split('/').last);
      if (pid != null) pids.add(pid);
    }
  } catch (_) {
    // /proc not listable: no holder resolvable.
  }
  return pids;
}

/// Whether process [pid] has an open fd bound to one of [inodes]
/// (`socket:[<inode>]`).
bool _pidHoldsSocket(int pid, Set<int> inodes) {
  final wanted = inodes.map((i) => 'socket:[$i]').toSet();
  try {
    for (final fd in Directory('$procPath$pid/fd').listSync()) {
      try {
        // /proc/<pid>/fd/<n> is a symlink to the target; `socket:[<inode>]`
        // for the socket's listening fd.
        if (wanted.contains(Link(fd.path).targetSync())) return true;
      } catch (_) {
        // The fd vanished or is not a readable link.
      }
    }
  } catch (_) {
    // The process vanished mid-scan.
  }
  return false;
}
