import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/bridge_server.dart';
import 'package:opencodebridge/client/connection_monitor.dart';

extension on ConnectionMonitor {
  /// Completes when the monitor first reports [s], failing after [timeout].
  Future<void> whenState(
    LinkState s, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    final completer = Completer<void>();
    if (state == s) {
      completer.complete();
      return completer.future;
    }
    void listener() {
      if (state == s) {
        removeListener(listener);
        completer.complete();
      }
    }

    addListener(listener);
    return completer.future.timeout(
      timeout,
      onTimeout: () =>
          fail('timed out waiting for state $s (stayed at $state)'),
    );
  }
}

void main() {
  group('ConnectionMonitor', () {
    test('probe answers reachable -> connected', () async {
      final monitor = ConnectionMonitor(probe: (Uri uri) async => true);
      monitor.connect(() => Uri.parse('http://127.0.0.1:1/api/health'));
      await monitor.whenState(LinkState.connected);
      expect(monitor.state, LinkState.connected);
      monitor.dispose();
    });

    test('probe answers unreachable -> disconnected', () async {
      final monitor = ConnectionMonitor(probe: (Uri uri) async => false);
      monitor.connect(() => Uri.parse('http://127.0.0.1:1/api/health'));
      await monitor.whenState(LinkState.disconnected);
      expect(monitor.state, LinkState.disconnected);
      monitor.dispose();
    });

    test('probe throws -> disconnected', () async {
      final monitor = ConnectionMonitor(
        probe: (Uri uri) async => throw Exception('boom'),
      );
      monitor.connect(() => Uri.parse('http://127.0.0.1:1/api/health'));
      await monitor.whenState(LinkState.disconnected);
      monitor.dispose();
    });

    test('recovers on a later tick', () async {
      var up = false;
      final monitor = ConnectionMonitor(
        interval: const Duration(milliseconds: 10),
        probe: (Uri uri) async => up,
      );
      monitor.connect(() => Uri.parse('http://127.0.0.1:1/api/health'));
      await monitor.whenState(LinkState.disconnected);
      up = true;
      await monitor.whenState(LinkState.connected);
      monitor.dispose();
    });

    test('disconnect() drops to disconnected', () async {
      final monitor = ConnectionMonitor(probe: (Uri uri) async => true);
      monitor.connect(() => Uri.parse('http://127.0.0.1:1/api/health'));
      await monitor.whenState(LinkState.connected);
      monitor.disconnect();
      expect(monitor.state, LinkState.disconnected);
      monitor.dispose();
    });

    test('default probe: live bridge up, then down', () async {
      final server = await BridgeServer.start(port: 0);
      final monitor = ConnectionMonitor();
      monitor.connect(() => server.healthUri);
      await monitor.whenState(LinkState.connected);
      await server.stop();
      await monitor.whenState(LinkState.disconnected);
      monitor.dispose();
    });
  });
}
