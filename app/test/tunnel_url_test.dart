import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/tunnel_url.dart';

void main() {
  group('parseTunnelUrl', () {
    test('a bare hostname is treated as https', () {
      final base = parseTunnelUrl('iacjppks.netauratech.fr');
      expect(base.scheme, 'https');
      expect(base.host, 'iacjppks.netauratech.fr');
    });

    test('an explicit scheme is kept', () {
      expect(parseTunnelUrl('https://host.fr/').toString(), 'https://host.fr/');
      expect(
        parseTunnelUrl('http://127.0.0.1:48201').toString(),
        'http://127.0.0.1:48201',
      );
    });

    test('surrounding whitespace is trimmed', () {
      expect(parseTunnelUrl('  host.fr  ').host, 'host.fr');
    });

    test('an empty value stays hostless', () {
      expect(parseTunnelUrl('   ').hasAuthority, isFalse);
    });
  });
}
