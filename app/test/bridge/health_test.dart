import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/health.dart';

void main() {
  group('HealthReport', () {
    test('serializes to the wire statuses', () {
      const report = HealthReport(
        bridge: ComponentStatus.ok,
        opencode: ComponentStatus.unreachable,
        docker: ComponentStatus.notConfigured,
      );
      expect(report.toJson(), {
        'bridge': 'ok',
        'opencode': 'unreachable',
        'docker': 'not_configured',
      });
    });

    test('round-trips from JSON', () {
      const report = HealthReport(
        bridge: ComponentStatus.ok,
        opencode: ComponentStatus.unreachable,
        docker: ComponentStatus.notConfigured,
      );
      final decoded = HealthReport.fromJson(report.toJson());
      expect(decoded, report);
      expect(decoded.bridge, ComponentStatus.ok);
      expect(decoded.opencode, ComponentStatus.unreachable);
      expect(decoded.docker, ComponentStatus.notConfigured);
    });

    test('parses from a plain map as sent over HTTP', () {
      const json = {
        'bridge': 'ok',
        'opencode': 'unreachable',
        'docker': 'not_configured',
      };
      final report = HealthReport.fromJson(json);
      expect(report.toJson(), json);
    });
  });
}
