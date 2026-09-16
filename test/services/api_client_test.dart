// Tests ApiClient against a fake HTTP server (package:http/testing.dart's
// MockClient) rather than a real backend -- no network/database needed.
// Covers: successful login + token persistence, the centralized 401
// handler firing exactly once per genuine auth failure (and NOT for a
// login failure, which is a different thing per docs/FLUTTER_API_HANDOFF.md
// §B), and Pydantic-style {"detail": "..."} error parsing (§28 of the
// implementation brief).
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:police_body_cam/services/api_client.dart';
import 'package:police_body_cam/services/auth_service.dart';

class InMemoryTokenStore implements TokenStore {
  final Map<String, String> _values = {};
  @override
  Future<void> delete(String key) async => _values.remove(key);
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}

/// Counts real reads against the underlying store, to prove getToken() only
/// ever hits the platform keystore once per process (see api_client.dart's
/// [ApiClient._cachedToken] doc comment -- a real physical-device bug on an
/// OPPO CPH2717/ColorOS, and previously a Redmi Note 10 Pro/MIUI, found the
/// keystore read hanging on EVERY single authenticated call, not just the
/// first one).
class _CountingTokenStore implements TokenStore {
  int readCount = 0;
  String? token;
  _CountingTokenStore({this.token});
  @override
  Future<String?> read(String key) async {
    readCount++;
    return token;
  }

  @override
  Future<void> write(String key, String value) async => token = value;
  @override
  Future<void> delete(String key) async => token = null;
}

void main() {
  late InMemoryTokenStore store;

  setUp(() {
    store = InMemoryTokenStore();
    ApiClient.tokenStore = store;
    ApiClient.onUnauthorized = null;
  });

  test('login stores the access token and returns the parsed user', () async {
    ApiClient.httpClient = MockClient((request) async {
      expect(request.url.path, '/auth/login');
      final body = jsonDecode(request.body) as Map;
      expect(body['username'], '9990001111');
      expect(body['password'], 'secret');
      return http.Response(
        jsonEncode({
          'access_token': 'jwt-token-abc',
          'token_type': 'bearer',
          'expires_in': 3600,
          'user': {
            'id': 'u1',
            'phone': '9990001111',
            'role': 'constable',
            'is_active': true,
            'station_id': null,
            'created_at': '2026-01-01T00:00:00Z',
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final user = await AuthService.login('9990001111', 'secret');
    expect(user.phone, '9990001111');
    expect(await ApiClient.getToken(), 'jwt-token-abc');
  });

  test('a wrong-password login failure does NOT trigger onUnauthorized', () async {
    var unauthorizedFired = false;
    ApiClient.onUnauthorized = () => unauthorizedFired = true;
    ApiClient.httpClient = MockClient((request) async {
      return http.Response(jsonEncode({'detail': 'Incorrect username or password'}), 401);
    });

    await expectLater(
      () => AuthService.login('9990001111', 'wrong'),
      throwsA(isA<ApiException>()),
    );
    expect(unauthorizedFired, isFalse, reason: 'login itself failing is not a session expiry');
  });

  test('a 401 on an authenticated call fires onUnauthorized exactly once', () async {
    var callCount = 0;
    ApiClient.onUnauthorized = () => callCount++;
    await store.write('access_token', 'stale-token');
    ApiClient.httpClient = MockClient((request) async {
      return http.Response(jsonEncode({'detail': 'Could not validate credentials'}), 401);
    });

    await expectLater(
      () => ApiClient.get('/devices/'),
      throwsA(isA<ApiException>()),
    );
    expect(callCount, 1);
  });

  test('ApiException carries the backend detail message and status code', () async {
    ApiClient.httpClient = MockClient((request) async {
      return http.Response(jsonEncode({'detail': 'Chunk 3 was already uploaded for this recording'}), 409);
    });
    await store.write('access_token', 't');

    try {
      await ApiClient.post('/recordings/rec-1/complete');
      fail('expected ApiException');
    } on ApiException catch (e) {
      expect(e.statusCode, 409);
      expect(e.isConflict, isTrue);
      expect(e.detail, 'Chunk 3 was already uploaded for this recording');
    }
  });

  test('getToken() reads the store at most once per process -- repeated calls use the in-memory cache', () async {
    final counting = _CountingTokenStore(token: 'cached-jwt');
    ApiClient.tokenStore = counting;

    final first = await ApiClient.getToken();
    final second = await ApiClient.getToken();
    final third = await ApiClient.getToken();

    expect([first, second, third], everyElement('cached-jwt'));
    expect(counting.readCount, 1, reason: 'a real device found the keystore read can hang -- it must only ever be attempted once per process, not once per call');
  });

  test('setToken() updates the in-memory cache directly, without requiring a store read', () async {
    final counting = _CountingTokenStore();
    ApiClient.tokenStore = counting;

    await ApiClient.setToken('fresh-jwt');
    expect(await ApiClient.getToken(), 'fresh-jwt');
    expect(counting.readCount, 0, reason: 'the token just written is already known -- no read is needed to confirm it');
  });

  test('clearToken() updates the in-memory cache directly -- a logged-out state never falls back to a real read', () async {
    final counting = _CountingTokenStore(token: 'stale-jwt');
    ApiClient.tokenStore = counting;
    await ApiClient.getToken(); // populate the cache first
    expect(counting.readCount, 1);

    await ApiClient.clearToken();
    expect(await ApiClient.getToken(), isNull);
    expect(counting.readCount, 1, reason: 'clearToken() already knows the new state is null -- getToken() must not read again');
  });

  test('reassigning tokenStore resets the cache -- a freshly installed store is always read for real', () async {
    final first = _CountingTokenStore(token: 'a');
    ApiClient.tokenStore = first;
    expect(await ApiClient.getToken(), 'a');

    final second = _CountingTokenStore(token: 'b');
    ApiClient.tokenStore = second;
    expect(await ApiClient.getToken(), 'b', reason: 'must not still return the previous store\'s cached value');
    expect(second.readCount, 1);
  });

  test('a non-JSON error body falls back to a generic message instead of crashing', () async {
    ApiClient.httpClient = MockClient((request) async {
      return http.Response('<html>502 Bad Gateway</html>', 502);
    });
    await store.write('access_token', 't');

    try {
      await ApiClient.get('/devices/');
      fail('expected ApiException');
    } on ApiException catch (e) {
      expect(e.statusCode, 502);
      expect(e.detail, contains('502'));
    }
  });
}
