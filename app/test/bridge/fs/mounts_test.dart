import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/fs/mounts.dart';

void main() {
  group('mountPoints', () {
    test('keeps the absolute mountpoints of real fstypes, sorted', () {
      const content =
          '/dev/sda1\t/\text4\t0 0\n'
          '/dev/nvme0n1p1\t/home\text4\t0 0\n'
          '/dev/sda2\t/old\text4\t0 0\n';
      expect(mountPoints(content), ['/', '/home', '/old']);
    });

    test('drops pseudo fstypes', () {
      const content =
          'tmpfs\t/dev/shm\ttmpfs\t0 0\n'
          'proc\t/proc\tproc\t0 0\n'
          'sysfs\t/sys\tsysfs\t0 0\n'
          'cgroup2\t/sys/fs/cgroup\tcgroup2\t0 0\n'
          'devtmpfs\t/dev\tdevtmpfs\t0 0\n'
          'fusectl\t/sys/fs/fuse/connections\tfusectl\t0 0\n'
          '/dev/sda1\t/\text4\t0 0\n';
      expect(mountPoints(content), ['/']);
    });

    test('a repeated mountpoint is one drive', () {
      const content =
          '/dev/sda1\t/home\text4\t0 0\n'
          '/dev/sda1\t/home\text4\t0 0\n';
      expect(mountPoints(content), ['/home']);
    });

    test('a mountpoint listed under several fstypes is one drive', () {
      const content =
          '/dev/sda1\t/home\text4\t0 0\n'
          'none\t/home\tsysfs\t0 0\n'
          'none\t/home\ttmpfs\t0 0\n';
      expect(mountPoints(content), ['/home']);
    });

    test('a non-absolute mountpoint is not a drive', () {
      const content = '/dev/sda1\trelpath\text4\t0 0\n';
      expect(mountPoints(content), isEmpty);
    });

    test('malformed lines are dropped', () {
      const content =
          '\n' // blank
          'no tabs at all\n'
          '/dev/sda1\t/\n' // missing the fstype
          '/dev/sda1\t/\text4\t0 0\n';
      expect(mountPoints(content), ['/']);
    });

    // In the mount table the fields are real tabs; a literal space, tab, or
    // newline inside a name is the kernel's octal escape.
    test('decodes the kernel octal escape for a space in a mountpoint', () {
      const content =
          '/dev/sda1\t'
          r'/mnt\040x'
          '\text4\t0 0\n';
      expect(mountPoints(content), ['/mnt x']);
    });

    test('an escaped tab in a mountpoint is part of the name', () {
      const content =
          '/dev/sda1\t'
          r'/a\011b'
          '\text4\t0 0\n';
      expect(mountPoints(content), ['/a\tb']);
    });

    test('an escaped newline in a mountpoint is part of the name', () {
      const content =
          '/dev/sda1\t'
          r'/a\012b'
          '\text4\t0 0\n';
      expect(mountPoints(content), ['/a\nb']);
    });
  });
}
