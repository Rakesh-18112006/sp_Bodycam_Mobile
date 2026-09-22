import '../models/recording_models.dart';
import 'api_client.dart';

/// Read-only wrappers around the EXISTING recording-listing endpoints
/// (GET /recordings/, GET /recordings/{id}, GET /recordings/{id}/chunks --
/// see backend/app/routers/recordings.py) for the "My Recordings" screen.
/// No new backend endpoint, no changed behavior: GET /recordings/ already
/// scopes a constable-role caller to their own recordings only (see
/// _authorize_recording_access in that router, already covered by
/// test_unrelated_constable_cannot_view_another_constables_recording), so
/// nothing here passes a constable_id/device_id -- the backend derives
/// "own" entirely from the authenticated JWT, exactly like the existing
/// POST /recordings/start call already does.
class RecordingApi {
  static Future<List<RecordingSessionResponse>> myRecordings({int limit = 50, int offset = 0}) async {
    final result = await ApiClient.get('/recordings/?limit=$limit&offset=$offset');
    return (result as List<dynamic>).map((e) => RecordingSessionResponse.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<RecordingSessionResponse> getRecording(String recordingId) async {
    final result = await ApiClient.get('/recordings/$recordingId');
    return RecordingSessionResponse.fromJson(result as Map<String, dynamic>);
  }

  static Future<RecordingManifestResponse> getManifest(String recordingId) async {
    final result = await ApiClient.get('/recordings/$recordingId/chunks');
    return RecordingManifestResponse.fromJson(result as Map<String, dynamic>);
  }

  /// URI + auth header for GET /recordings/{id}/play (the server-side
  /// concatenated, Range-seekable file -- see
  /// backend/app/routers/recordings.py::play_recording). Same
  /// _authorize_recording_access check as every other endpoint here: a 403
  /// on this URL for an unowned recording surfaces to the caller as an
  /// ApiException via VideoPlayerController's own error handling, never a
  /// silent bypass. Returns a Bearer header (not a query token) since
  /// VideoPlayerController.networkUrl supports httpHeaders directly and
  /// this avoids ever putting the access token in a URL that could end up
  /// in logs.
  static Future<(Uri, Map<String, String>)> playInfo(String recordingId) async {
    final token = await ApiClient.getToken();
    final headers = <String, String>{if (token != null) 'Authorization': 'Bearer $token'};
    final uri = Uri.parse('$kApiBaseUrl/recordings/$recordingId/play');
    return (uri, headers);
  }
}
