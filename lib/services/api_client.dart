import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Backend base URL. `10.0.2.2` is the standard Android-emulator alias for
/// the host machine's `localhost` (per docs/FLUTTER_API_HANDOFF.md §A) --
/// change this if running against a physical device or a real server.
const String kApiBaseUrl = 'http://10.0.2.2:8000';

final _secureStorage = FlutterSecureStorage();
const _tokenKey = 'access_token';
const _deviceIdentifierKey = 'device_identifier';

/// Thin authenticated HTTP wrapper. Never logs the token or request/response
/// bodies (see docs/FLUTTER_API_HANDOFF.md §N) -- only exceptions with a
/// short message reach the caller.
class ApiClient {
  static Future<String?> getToken() => _secureStorage.read(key: _tokenKey);
  static Future<void> setToken(String token) => _secureStorage.write(key: _tokenKey, value: token);
  static Future<void> clearToken() => _secureStorage.delete(key: _tokenKey);

  static Future<String?> getDeviceIdentifier() => _secureStorage.read(key: _deviceIdentifierKey);
  static Future<void> setDeviceIdentifier(String id) => _secureStorage.write(key: _deviceIdentifierKey, value: id);

  static Future<Map<String, String>> _headers({bool auth = true}) async {
    final headers = {'Content-Type': 'application/json'};
    if (auth) {
      final token = await getToken();
      if (token != null) headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  static Future<dynamic> post(String path, {Map<String, dynamic>? body, bool auth = true}) async {
    final response = await http.post(
      Uri.parse('$kApiBaseUrl$path'),
      headers: await _headers(auth: auth),
      body: jsonEncode(body ?? {}),
    );
    return _decode(response);
  }

  static Future<dynamic> get(String path) async {
    final response = await http.get(Uri.parse('$kApiBaseUrl$path'), headers: await _headers());
    return _decode(response);
  }

  static dynamic _decode(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return null;
      return jsonDecode(response.body);
    }
    String detail = 'Request failed (${response.statusCode})';
    try {
      final parsed = jsonDecode(response.body);
      if (parsed is Map && parsed['detail'] != null) detail = parsed['detail'].toString();
    } catch (_) {
      // Non-JSON error body -- fall back to the generic message above.
    }
    throw ApiException(response.statusCode, detail);
  }
}

class ApiException implements Exception {
  final int statusCode;
  final String detail;
  ApiException(this.statusCode, this.detail);
  @override
  String toString() => detail;
}
