import 'package:flutter_test/flutter_test.dart';
import 'package:opencodebridge/access/token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AccessTokenStore store;
  final expiresAt = DateTime.fromMillisecondsSinceEpoch(1_900_000_000_000);

  AccessLoginRecord record({
    String clientId = 'dyn-client-1',
    String? refreshToken = 'refresh-1',
  }) => AccessLoginRecord(
    clientId: clientId,
    accessToken: 'oauth:opaque-1',
    refreshToken: refreshToken,
    accessTokenExpiresAt: expiresAt,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await AccessTokenStore.load();
  });

  test('nothing stored: load returns null', () {
    expect(store.recordFor('bridge.example.com'), isNull);
  });

  test('save and load round-trip the record for one host', () {
    store.save('bridge.example.com', record());
    final reloaded = store.recordFor('bridge.example.com');
    expect(reloaded, isNotNull);
    expect(reloaded!.clientId, 'dyn-client-1');
    expect(reloaded.accessToken, 'oauth:opaque-1');
    expect(reloaded.refreshToken, 'refresh-1');
    expect(reloaded.accessTokenExpiresAt, expiresAt);
  });

  test('a null refresh token round-trips', () {
    store.save('bridge.example.com', record(refreshToken: null));
    expect(store.recordFor('bridge.example.com')!.refreshToken, isNull);
  });

  test('hosts are keyed independently', () {
    store.save('a.example.com', record(clientId: 'client-a'));
    store.save('b.example.com', record(clientId: 'client-b'));
    expect(store.recordFor('a.example.com')!.clientId, 'client-a');
    expect(store.recordFor('b.example.com')!.clientId, 'client-b');
    expect(store.recordFor('c.example.com'), isNull);
  });

  test('delete removes only that host', () {
    store.save('a.example.com', record());
    store.save('b.example.com', record());
    store.delete('a.example.com');
    expect(store.recordFor('a.example.com'), isNull);
    expect(store.recordFor('b.example.com'), isNotNull);
  });

  test('the record persists across a store reload (app restart)', () async {
    store.save('bridge.example.com', record());
    final reloaded = await AccessTokenStore.load();
    expect(reloaded.recordFor('bridge.example.com')!.clientId, 'dyn-client-1');
  });
}
