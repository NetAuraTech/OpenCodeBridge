import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/bridge/tunnel/tunnel_metrics.dart';

void main() {
  group('parseRegisteredConnections', () {
    test('sums the registered edge connections', () {
      const body = '''
# HELP cloudflared_tunnel_ha_connections The number of active HA connections.
# TYPE cloudflared_tunnel_ha_connections gauge
cloudflared_tunnel_ha_connections 3
''';
      expect(parseRegisteredConnections(body), 3);
    });

    test('sums across labelled series', () {
      const body = '''
cloudflared_tunnel_ha_connections{region="sfo"} 2
cloudflared_tunnel_ha_connections{region="lax"} 1
''';
      expect(parseRegisteredConnections(body), 3);
    });

    test('ignores other metrics and comments', () {
      const body = '''
# some comment
process_cpu_seconds_total 1.5
cloudflared_tunnel_ha_connections 0
''';
      expect(parseRegisteredConnections(body), 0);
    });

    test('an empty body has no connections', () {
      expect(parseRegisteredConnections(''), 0);
    });

    test('a body without the metric has no connections', () {
      const body = 'process_cpu_seconds_total 1.5\n';
      expect(parseRegisteredConnections(body), 0);
    });
  });
}
