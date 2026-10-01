import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

/// Backend base URL. Configurable at build/run time via
/// `--dart-define=API_BASE_URL=http://<host>:8000` -- never hardcode a
/// specific developer's LAN IP in source (see the original audit finding).
///
/// Defaults to the real deployed production backend (Render). Override
/// for local/emulator development, e.g.:
///   flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000            # Android emulator
///   flutter run --dart-define=API_BASE_URL=http://192.168.1.50:8000        # physical device, local backend
const String kApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://bodycam-backend-qo1e.onrender.com',
);

const _tokenKey = 'access_token';
const _deviceIdentifierKey = 'device_identifier';

/// Every network call below is bounded by this. Real-device validation
/// (Redmi Note 10 Pro, over a USB/adb-reverse tunnel) found that a stalled
/// connection with NO timeout left `http.Client.send()` awaiting forever:
/// for chunk uploads specifically, that meant ChunkUploader.drain()'s
/// `_draining` reentrancy guard was set to true and NEVER released (its
/// `finally` block never ran), permanently wedging all future upload
/// attempts -- not just the stuck one -- for the rest of the app's
/// process lifetime, with zero chunks ever reaching the backend. A
/// stalled call must fail (and be retried, per the existing retry/backoff
/// logic in ChunkUploader/RecordingService) rather than hang forever.
const kNetworkTimeout = Duration(seconds: 30);

/// Longer bound for multipart segment uploads specifically -- a real video
/// file is bigger than any JSON body and may legitimately take longer than
/// [kNetworkTimeout] on a slow/USB-tunneled connection, but it must still
/// eventually fail and be retried rather than hang forever (see
/// [kNetworkTimeout]'s doc comment for why an unbounded hang here is
/// actively dangerous, not just slow).
///
/// 60s (the original value) was calibrated against a fast local/USB
/// connection and was found, via a real public-Internet (Cloudflare
/// Tunnel + mobile data) reproduction, to be tight for a full-size video
/// segment on genuine mobile upload speeds -- a chunk that is still
/// legitimately in flight at 60s is aborted and retried rather than
/// allowed to finish, which both wastes the upload and (see
/// chunk_uploader.dart's drain() doc comment) widens the window for a
/// since-fixed concurrency race between the periodic pump timer and
/// RecordingEngine.stop()'s final-chunk enqueue. 120s is a deliberately
/// bounded increase -- not "huge" -- sized for one realistic worst-case
/// segment over slow cellular, not an unbounded/infinite wait.
const kUploadTimeout = Duration(seconds: 120);

/// Small storage seam so tests can swap in an in-memory fake instead of
/// hitting the real platform keystore (which has no implementation inside
/// `flutter test`'s VM environment). Production always uses
/// [SecureTokenStore]; nothing about where the token is stored changes --
/// it is still exclusively the platform keystore via flutter_secure_storage.
abstract class TokenStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureTokenStore implements TokenStore {
  // encryptedSharedPreferences: true switches the Android backend to
  // androidx.security.crypto's EncryptedSharedPreferences (Google's
  // actively-maintained implementation) instead of the plugin's legacy
  // custom AES+Keystore scheme, which has documented hang/deadlock reports
  // on OEM ROMs (MIUI included) when reading a previously-persisted value
  // on a fresh process. Real-device validation (Redmi Note 10 Pro,
  // Android 13/MIUI) found a cold-start read hang; this is part of the
  // fix alongside main.dart's single-read-per-process correction.
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Thin authenticated HTTP wrapper. Never logs the token or request/response
/// bodies (see docs/FLUTTER_API_HANDOFF.md §N) -- only exceptions with a
/// short message reach the caller.
class ApiClient {
  /// Swappable for tests (see test/services/api_client_test.dart) via
  /// package:http/testing.dart's MockClient. Production never overrides
  /// this.
  static http.Client httpClient = http.Client();

  /// Swappable for tests -- see [TokenStore] above. Reassigning this (as
  /// every test's setUp() does) also resets the in-memory token cache
  /// below, so a fresh store always starts with a real read rather than a
  /// stale cached value from whatever store was previously installed.
  static TokenStore _tokenStore = SecureTokenStore();
  static TokenStore get tokenStore => _tokenStore;
  static set tokenStore(TokenStore store) {
    _tokenStore = store;
    _cachedToken = null;
    _tokenCacheLoaded = false;
  }

  /// In-memory cache for the access token, populated by the first
  /// successful [getToken] read (or by [setToken]/[clearToken] directly)
  /// and reused for the rest of the process's lifetime instead of hitting
  /// the platform keystore again. Real-device validation (Redmi Note 10
  /// Pro/MIUI, then an OPPO CPH2717/ColorOS) found that
  /// flutter_secure_storage's keystore read can hang indefinitely on
  /// certain OEM ROMs -- main.dart's bootstrap already reads the token
  /// exactly once per process for the login-state check, but every
  /// subsequent authenticated request (`_headers()`, `postMultipart()`)
  /// was calling `tokenStore.read()` again on its own, independently
  /// exposed to the same hang on every single heartbeat/location/chunk
  /// upload call for the rest of the app's life. Caching after the first
  /// read means only ONE keystore read can ever hang per process, not one
  /// per request.
  static String? _cachedToken;
  static bool _tokenCacheLoaded = false;

  /// Swappable for tests (see test/services/chunk_timeout_test.dart), which
  /// need a hang to actually time out in well under a second rather than
  /// waiting out the real 30s/60s production values. Production never
  /// overrides these.
  static Duration networkTimeout = kNetworkTimeout;
  static Duration uploadTimeout = kUploadTimeout;

  /// Set once by main.dart/home_screen.dart. Invoked exactly once per
  /// genuine 401 response (a server-confirmed "this token is no longer
  /// valid" -- never called for any other status code) so
  /// authentication-expiry handling lives in one place instead of being
  /// duplicated in every screen (see §20 of the implementation brief).
  /// Deliberately NOT invoked for the /auth/login call itself (auth: false
  /// requests never trigger it) -- a wrong password is not "your session
  /// expired", it's a login failure the login screen already displays
  /// inline.
  static void Function()? onUnauthorized;

  static Future<String?> getToken() async {
    if (_tokenCacheLoaded) return _cachedToken;
    final token = await tokenStore.read(_tokenKey);
    _cachedToken = token;
    _tokenCacheLoaded = true;
    return token;
  }

  static Future<void> setToken(String token) async {
    await tokenStore.write(_tokenKey, token);
    _cachedToken = token;
    _tokenCacheLoaded = true;
  }

  static Future<void> clearToken() async {
    await tokenStore.delete(_tokenKey);
    _cachedToken = null;
    _tokenCacheLoaded = true;
  }

  static Future<String?> getDeviceIdentifier() => tokenStore.read(_deviceIdentifierKey);
  static Future<void> setDeviceIdentifier(String id) => tokenStore.write(_deviceIdentifierKey, id);

  static Future<Map<String, String>> _headers({bool auth = true}) async {
    final headers = {'Content-Type': 'application/json'};
    if (auth) {
      final token = await getToken();
      if (token != null) headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  static Future<dynamic> post(String path, {Map<String, dynamic>? body, bool auth = true}) async {
    final response = await httpClient
        .post(
          Uri.parse('$kApiBaseUrl$path'),
          headers: await _headers(auth: auth),
          body: jsonEncode(body ?? {}),
        )
        .timeout(networkTimeout);
    return _decode(response, authRequestWasMade: auth);
  }

  static Future<dynamic> get(String path) async {
    final response = await httpClient
        .get(Uri.parse('$kApiBaseUrl$path'), headers: await _headers())
        .timeout(networkTimeout);
    return _decode(response, authRequestWasMade: true);
  }

  /// Multipart upload (used by ChunkUploader for POST /recordings/{id}/chunks).
  /// [fields] become form fields (chunk_number, duration_seconds,
  /// is_last_chunk); [file] is streamed from disk rather than read fully
  /// into memory first, so a large segment never doubles its memory
  /// footprint just to be uploaded.
  static Future<dynamic> postMultipart(
    String path, {
    required Map<String, String> fields,
    required File file,
    required String fileFieldName,
    required String mimeType,
  }) async {
    final uri = Uri.parse('$kApiBaseUrl$path');
    final request = http.MultipartRequest('POST', uri);
    final token = await getToken();
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    request.fields.addAll(fields);
    request.files.add(await http.MultipartFile.fromPath(
      fileFieldName,
      file.path,
      contentType: MediaType.parse(mimeType),
    ));

    final streamedResponse = await httpClient.send(request).timeout(uploadTimeout);
    final response = await http.Response.fromStream(streamedResponse).timeout(uploadTimeout);
    return _decode(response, authRequestWasMade: true);
  }

  static dynamic _decode(http.Response response, {required bool authRequestWasMade}) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return null;
      return jsonDecode(response.body);
    }

    if (response.statusCode == 401 && authRequestWasMade) {
      // Fire-and-forget: the callback itself is responsible for clearing
      // the token and navigating to the login screen. We still throw below
      // so the immediate caller's try/catch also sees the failure and can
      // stop whatever it was doing (e.g. abort a chunk upload attempt).
      onUnauthorized?.call();
    }

    String detail = 'Request failed (${response.statusCode})';
    try {
      final parsed = jsonDecode(response.body);
      if (parsed is Map && parsed['detail'] != null) detail = parsed['detail'].toString();
    } catch (_) {
      // Non-JSON error body -- fall back to the generic message above.
    }
    throw ApiException(response.statusCode, detail, headers: response.headers);
  }
}

class ApiException implements Exception {
  final int statusCode;
  final String detail;
  // Raw response headers (see chunk_uploader.dart's use of [conflictReason]
  // below) -- package:http lowercases header names, so lookups here must
  // always use lowercase keys.
  final Map<String, String>? headers;
  ApiException(this.statusCode, this.detail, {this.headers});

  bool get isConflict => statusCode == 409;
  bool get isPayloadTooLarge => statusCode == 413;
  bool get isValidationError => statusCode == 422;
  bool get isUnauthorized => statusCode == 401;
  bool get isForbidden => statusCode == 403;
  bool get isNotFound => statusCode == 404;

  /// Only meaningful when [isConflict] -- see
  /// backend/app/routers/recordings.py::upload_chunk's X-Conflict-Reason
  /// header and chunk_uploader.dart's handling of it. Null for a 409 from
  /// an older backend that doesn't send this header, or for any endpoint
  /// that doesn't set it -- callers must treat null as "unknown reason",
  /// never assume it means "duplicate".
  String? get conflictReason => headers?['x-conflict-reason'];

  @override
  String toString() => detail;
}
