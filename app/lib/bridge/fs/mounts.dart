/// Parses a Linux host's mount table (`/proc/self/mounts`) into the drives
/// the "New project" file-picker starts from (issue #54, the Linux
/// adapter's half of ADR-0002's per-OS seam).
///
/// The mount table is one line per mount, with the fields
/// `<device> <mountpoint> <fstype> <options> <super> <special>` separated by
/// whitespace (the kernel writes a tab, but some hosts write a space). The
/// kernel octal-escapes a literal space, tab, and newline inside a name as
/// `\040`, `\011`, and `\012`, so a raw space or tab only ever appears
/// between the fields. Only the mountpoint and the fstype matter here:
///
/// - a line needs at least three fields (device, mountpoint, fstype) to
///   count;
/// - a pseudo fstype (proc, sysfs, cgroup2, tmpfs, …) is not a drive;
/// - a user-space FUSE mount (`fuse.*`: gvfs, sshfs, …) is not a drive;
/// - a container rootfs (an `overlay` mount at a deep path) is not a drive;
///   an overlay mounted at `/` is (an app in a container browses its root);
/// - a non-absolute mountpoint is not a drive;
/// - a drive is listed once, sorted.
List<String> mountPoints(String content) {
  final drives = <String>{};
  for (final raw in content.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final fields = line.split(RegExp(r'\s+'));
    if (fields.length < 3) continue;
    final fstype = _unescape(fields[2]);
    if (_pseudoFstypes.contains(fstype)) continue;
    // User-space FUSE mounts (gvfs, sshfs, fuse-overlayfs, …) are not
    // storage a project lives on.
    if (fstype.startsWith('fuse.')) continue;
    final point = _unescape(fields[1]);
    // A container runtime's container rootfs is an overlay mounted at a deep
    // path; the only overlay a desktop user browses is the system root
    // itself (an app in a container has overlay as its root and keeps it).
    if (fstype == 'overlay' && point != '/') continue;
    if (!point.startsWith('/')) continue;
    drives.add(point);
  }
  final points = drives.toList()..sort();
  return points;
}

/// The fstypes that are not a real filesystem: the kernel's virtual and
/// memory-only mounts, never a project drive.
const Set<String> _pseudoFstypes = {
  'proc',
  'procfs',
  'sysfs',
  'devtmpfs',
  'devpts',
  'cgroup',
  'cgroup2',
  'tmpfs',
  'ramfs',
  'mqueue',
  'debugfs',
  'tracefs',
  'securityfs',
  'configfs',
  'pstore',
  'hugetlbfs',
  'bpf',
  'binfmt_misc',
  'rpc_pipefs',
  'nsfs',
  'fusectl',
  'efivarfs',
  'selinuxfs',
  'autofs',
  'squashfs',
};

/// Decodes the kernel's octal escapes (`\040` a space, `\011` a tab,
/// `\012` a newline) in a mount-table field.
String _unescape(String field) {
  if (!field.contains(r'\')) return field;
  return field.replaceAllMapped(
    RegExp(r'\\([0-7]{3})'),
    (match) => String.fromCharCode(int.parse(match[1]!, radix: 8)),
  );
}
