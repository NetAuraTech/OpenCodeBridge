import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/tunnel/port_holder.dart';

/// The pid of the test process (dart:io has no current-pid API;
/// `/proc/self` is a symlink to `/proc/<pid>`).
int get selfPid => int.parse(Link('/proc/self').targetSync().split('/').last);

void main() {
  group('portHolderProbe', () {
    test('a port nothing listens on resolves to null', () async {
      // Bind on 0 to get a free port, close the listener, probe the now
      // quiet port.
      final server = await HttpServer.bind('127.0.0.1', 0);
      final port = server.port;
      await server.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(await portHolderProbe(port), isNull);
    });

    test('a live listener resolves to its pid, not cloudflared', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      // Give the listener a moment to be visible in /proc/net/tcp.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final holder = await portHolderProbe(server.port);

      expect(holder, isNotNull);
      expect(holder!.pid, selfPid);
      expect(holder.isCloudflared, isFalse);
    });

    test('isCloudflaredProcess is false for the test runner itself', () {
      expect(isCloudflaredProcess(selfPid), isFalse);
    });

    test('isCloudflaredProcess is false for a dead pid', () {
      expect(isCloudflaredProcess(-1), isFalse);
    });
  });
}
