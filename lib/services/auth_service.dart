import 'api_client.dart';
import '../models/auth_models.dart';

class AuthService {
  /// POST /auth/login -- {"username": "<phone>", "password": "..."} (the
  /// field really is called `username` even though it's the phone number,
  /// see docs/FLUTTER_API_HANDOFF.md §B).
  static Future<UserPublic> login(String phone, String password) async {
    final result = await ApiClient.post(
      '/auth/login',
      body: {'username': phone, 'password': password},
      auth: false,
    );
    final token = TokenResponse.fromJson(result as Map<String, dynamic>);
    await ApiClient.setToken(token.accessToken);
    return token.user;
  }

  /// Clears the stored token and stops nothing else itself -- callers
  /// (HomeScreen._logout, or ApiClient.onUnauthorized) are responsible for
  /// tearing down heartbeat/location/WebSocket/foreground-service state
  /// *before* or immediately after calling this, since this alone does not
  /// stop any background activity.
  static Future<void> logout() => ApiClient.clearToken();

  static Future<bool> isLoggedIn() async => (await ApiClient.getToken()) != null;
}
