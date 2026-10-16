import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'api_client.dart';
import 'network_hopping_service.dart';

/// Error from a site receiver. Receivers answer `{"error": {"code", "message"}}`
/// (not the control room's `{"detail": ...}`), so they get their own type.
class ReceiverException implements Exception {
  final int statusCode;
  final String code;
  final String message;
  final int? retryAfterSeconds;
  ReceiverException(this.statusCode, this.code, this.message, {this.retryAfterSeconds});

  bool get isUnauthorized => statusCode == 401;
  bool get isGrantProblem => statusCode == 401 || statusCode == 403;
  bool get isStorageFull => statusCode == 507;
  bool get isBusy => statusCode == 503 || statusCode == 429;
  bool get isConflict => statusCode == 409;
  // A corrupted-in-transit upload: the same bytes should simply be sent again.
  bool get isHashMismatch => statusCode == 422 && code == 'hash_mismatch';

  @override
  String toString() => '$code: $message';
}

/// Thin client for the receiver's /v1 API (see backend/site_receiver/main.py).
class ReceiverClient {
  static Map<String, String> _auth(ReceiverSession s) => {'Authorization': 'Bearer ${s.token}'};

  static dynamic _decode(http.Response r) {
    if (r.statusCode >= 200 && r.statusCode < 300) return r.body.isEmpty ? null : jsonDecode(r.body);
    var code = 'http_${r.statusCode}';
    var message = 'Receiver returned ${r.statusCode}';
    try {
      final err = (jsonDecode(r.body) as Map<String, dynamic>)['error'] as Map<String, dynamic>;
      code = (err['code'] as String?) ?? code;
      message = (err['message'] as String?) ?? message;
    } catch (_) {}
    throw ReceiverException(r.statusCode, code, message, retryAfterSeconds: int.tryParse(r.headers['retry-after'] ?? ''));
  }

  static Future<dynamic> registerRecording(
    ReceiverSession s, {
    required String recordingId,
    required DateTime startedAt,
    required String triggerType,
    required String cameraLensDirection,
  }) async {
    final r = await ApiClient.httpClient
        .post(
          Uri.parse('${s.baseUrl}/v1/recordings'),
          headers: {..._auth(s), 'Content-Type': 'application/json'},
          body: jsonEncode({
            'recording_id': recordingId,
            'started_at': startedAt.toUtc().toIso8601String(),
            'trigger_type': triggerType,
            'camera_lens_direction': cameraLensDirection,
          }),
        )
        .timeout(ApiClient.networkTimeout);
    return _decode(r);
  }

  /// Returns the receiver's acknowledgement (`status: locally_durable`).
  /// Throws [ReceiverException] on a definitive answer and lets network
  /// errors (SocketException, TimeoutException, ...) propagate.
  static Future<Map<String, dynamic>> putChunk(
    ReceiverSession s, {
    required String recordingId,
    required String chunkId,
    required int chunkNumber,
    required String sha256,
    required int sizeBytes,
    required File file,
    double? durationSeconds,
    bool isLastChunk = false,
    double? latitude,
    double? longitude,
    DateTime? capturedStart,
    DateTime? capturedEnd,
  }) async {
    final request = http.MultipartRequest('PUT', Uri.parse('${s.baseUrl}/v1/recordings/$recordingId/chunks/$chunkId'));
    request.headers.addAll(_auth(s));
    request.fields.addAll({
      'chunk_number': chunkNumber.toString(),
      'sha256': sha256,
      'size_bytes': sizeBytes.toString(),
      'is_last_chunk': isLastChunk.toString(),
      if (durationSeconds != null) 'duration_seconds': durationSeconds.toString(),
      if (latitude != null) 'latitude': latitude.toString(),
      if (longitude != null) 'longitude': longitude.toString(),
      if (capturedStart != null) 'captured_start': capturedStart.toUtc().toIso8601String(),
      if (capturedEnd != null) 'captured_end': capturedEnd.toUtc().toIso8601String(),
    });
    request.files.add(await http.MultipartFile.fromPath('file', file.path, contentType: MediaType.parse('video/mp4')));
    final streamed = await ApiClient.httpClient.send(request).timeout(ApiClient.uploadTimeout);
    final response = await http.Response.fromStream(streamed).timeout(ApiClient.uploadTimeout);
    return _decode(response) as Map<String, dynamic>;
  }

  static Future<dynamic> complete(ReceiverSession s, {required String recordingId, required int chunkCount, DateTime? endedAt}) async {
    final r = await ApiClient.httpClient
        .post(
          Uri.parse('${s.baseUrl}/v1/recordings/$recordingId/complete'),
          headers: {..._auth(s), 'Content-Type': 'application/json'},
          body: jsonEncode({'chunk_count': chunkCount, if (endedAt != null) 'ended_at': endedAt.toUtc().toIso8601String()}),
        )
        .timeout(ApiClient.networkTimeout);
    return _decode(r);
  }

  /// Token for the site-local live service, or throws [ReceiverException]
  /// (404 `local_live_not_configured` when the site has none).
  static Future<Map<String, dynamic>> liveStart(ReceiverSession s) async {
    final r = await ApiClient.httpClient.post(Uri.parse('${s.baseUrl}/v1/live/start'), headers: _auth(s)).timeout(ApiClient.networkTimeout);
    return _decode(r) as Map<String, dynamic>;
  }
}
