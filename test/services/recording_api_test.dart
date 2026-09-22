// Regression tests for the "My Recordings" screen's read-only API layer.
// Verifies RecordingApi calls the EXISTING GET /recordings/,
// GET /recordings/{id}, GET /recordings/{id}/chunks endpoints (never a new
// one) and parses the real backend response shapes
// (schemas.RecordingSessionResponse / RecordingManifestResponse) correctly
// -- the same models api_client.dart's siblings already use elsewhere, not
// a new parallel schema.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:police_body_cam/services/api_client.dart';
import 'package:police_body_cam/services/recording_api.dart';

class _FakeStore implements TokenStore {
  @override
  Future<void> delete(String key) async {}
  @override
  Future<String?> read(String key) async => 'test-token';
  @override
  Future<void> write(String key, String value) async {}
}

Map<String, dynamic> _recordingJson({String id = 'rec-1'}) => {
      'id': id,
      'constable_id': 'constable-1',
      'device_id': 'device-1',
      'trigger_type': 'manual',
      'status': 'completed',
      'started_at': '2026-01-01T00:00:00Z',
      'ended_at': '2026-01-01T00:02:00Z',
      'incident_id': null,
      'created_at': '2026-01-01T00:00:00Z',
      'chunk_count': 2,
      'highest_chunk_number': 2,
      'missing_chunk_numbers': [],
      'playable_status': 'ready',
    };

void main() {
  setUp(() {
    ApiClient.tokenStore = _FakeStore();
  });

  test('myRecordings() calls GET /recordings/ and parses the real response shape', () async {
    String? requestedPath;
    ApiClient.httpClient = MockClient((request) async {
      requestedPath = request.url.path;
      expect(request.method, 'GET');
      return http.Response(jsonEncode([_recordingJson(id: 'rec-1'), _recordingJson(id: 'rec-2')]), 200);
    });

    final rows = await RecordingApi.myRecordings();

    expect(requestedPath, '/recordings/');
    expect(rows, hasLength(2));
    expect(rows[0].id, 'rec-1');
    expect(rows[1].id, 'rec-2');
  });

  test('myRecordings() never sends a constable_id/device_id -- the backend derives "own" from the JWT alone', () async {
    ApiClient.httpClient = MockClient((request) async {
      expect(request.url.queryParameters.containsKey('constable_id'), isFalse);
      expect(request.url.queryParameters.containsKey('device_id'), isFalse);
      return http.Response(jsonEncode(<dynamic>[]), 200);
    });

    await RecordingApi.myRecordings();
  });

  test('getRecording() calls GET /recordings/{id} and parses fields actually used by the details screen', () async {
    ApiClient.httpClient = MockClient((request) async {
      expect(request.url.path, '/recordings/rec-1');
      return http.Response(jsonEncode(_recordingJson()), 200);
    });

    final r = await RecordingApi.getRecording('rec-1');

    expect(r.id, 'rec-1');
    expect(r.chunkCount, 2);
    expect(r.missingChunkNumbers, isEmpty);
    expect(r.playableStatus, 'ready');
  });

  test('getRecording() defaults playableStatus to not_ready when the backend omits the field', () async {
    final json = _recordingJson()..remove('playable_status');
    ApiClient.httpClient = MockClient((request) async {
      return http.Response(jsonEncode(json), 200);
    });

    final r = await RecordingApi.getRecording('rec-1');

    expect(r.playableStatus, 'not_ready');
  });

  test('playInfo() targets GET /recordings/{id}/play with a Bearer header, never a query token', () async {
    final (uri, headers) = await RecordingApi.playInfo('rec-1');

    expect(uri.path, '/recordings/rec-1/play');
    expect(headers['Authorization'], 'Bearer test-token');
    expect(uri.queryParameters.containsKey('token'), isFalse);
  });

  test('getManifest() calls GET /recordings/{id}/chunks and parses the chunk list', () async {
    ApiClient.httpClient = MockClient((request) async {
      expect(request.url.path, '/recordings/rec-1/chunks');
      return http.Response(
        jsonEncode({
          'recording_session_id': 'rec-1',
          'status': 'completed',
          'highest_chunk_number': 1,
          'missing_chunk_numbers': <int>[],
          'is_complete': true,
          'chunks': [
            {
              'id': 'chunk-1',
              'recording_session_id': 'rec-1',
              'chunk_number': 1,
              'file_size': 1024,
              'duration_seconds': 20.0,
              'file_hash': 'abc',
              'mime_type': 'video/mp4',
              'is_last_chunk': true,
              'upload_status': 'uploaded',
              'created_at': '2026-01-01T00:00:20Z',
            },
          ],
        }),
        200,
      );
    });

    final m = await RecordingApi.getManifest('rec-1');

    expect(m.chunks, hasLength(1));
    expect(m.chunks.first.chunkNumber, 1);
    expect(m.isComplete, isTrue);
  });

  test('a 403 from the backend (a real-but-unowned recording) surfaces as an ApiException, never swallowed', () async {
    ApiClient.httpClient = MockClient((request) async {
      return http.Response(jsonEncode({'detail': 'Not authorized to view this recording'}), 403);
    });

    await expectLater(
      () => RecordingApi.getRecording('someone-elses-recording'),
      throwsA(isA<ApiException>()),
    );
  });
}
