import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/model/tunnel_report.dart';

void main() {
  group('TunnelStatusJson', () {
    test('parses the wire values', () {
      expect(TunnelStatusJson.fromWire('up'), TunnelStatus.up);
      expect(TunnelStatusJson.fromWire('down'), TunnelStatus.down);
      expect(
        TunnelStatusJson.fromWire('not_configured'),
        TunnelStatus.notConfigured,
      );
    });

    test('an unknown value is down', () {
      expect(TunnelStatusJson.fromWire('weird'), TunnelStatus.down);
      expect(TunnelStatusJson.fromWire(null), TunnelStatus.down);
    });

    test('the wire values match the contract', () {
      expect(TunnelStatus.up.toWire(), 'up');
      expect(TunnelStatus.down.toWire(), 'down');
      expect(TunnelStatus.notConfigured.toWire(), 'not_configured');
    });
  });

  group('TunnelReport', () {
    const report = TunnelReport(
      status: TunnelStatus.up,
      running: true,
      registeredConnections: 3,
      metricsPort: 20241,
      hostname: 'bridge.example.com',
      missing: ['credentials'],
      missingDetails: ['the tunnel credentials are missing'],
    );

    test('round-trips through the wire format', () {
      final decoded = TunnelReport.fromJson(report.toJson());
      expect(decoded, report);
    });

    test('a report without the optional fields round-trips too', () {
      const none = TunnelReport(
        status: TunnelStatus.notConfigured,
        running: false,
        registeredConnections: 0,
      );
      expect(TunnelReport.fromJson(none.toJson()), none);
    });

    test('a non-map body is an empty down report', () {
      final decoded = TunnelReport.fromJson('nope');
      expect(decoded.status, TunnelStatus.down);
      expect(decoded.running, isFalse);
      expect(decoded.registeredConnections, 0);
      expect(decoded.metricsPort, isNull);
      expect(decoded.hostname, isNull);
      expect(decoded.missing, isEmpty);
      expect(decoded.missingDetails, isEmpty);
    });
  });
}
