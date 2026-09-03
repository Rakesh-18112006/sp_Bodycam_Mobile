import 'api_client.dart';

class AuthService {
  /// POST /auth/login -- {"username": "<phone>", "password": "..."} (the
  /// field really is called `username` even though it's the phone number,
  /// see docs/FLUTTER_API_HANDOFF.md §B).
  static Future<Map<String, dynamic>> login(String phone, String password) async {
    final result = await ApiClient.post(
      '/auth/login',
      body: {'username': phone, 'password': password},
      auth: false,
    );
    await ApiClient.setToken(result['access_token']);
    return result['user'];
  }

  static Future<void> logout() => ApiClient.clearToken();

  static Future<bool> isLoggedIn() async => (await ApiClient.getToken()) != null;
}
