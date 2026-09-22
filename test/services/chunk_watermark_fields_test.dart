// Verifies ChunkUploader actually sends the GPS/timestamp fields the
// backend needs to burn a watermark into each chunk's video (see
// backend/app/routers/recordings.py::upload_chunk's new
// latitude/longitude/recorded_at form fields). A BaseClient subclass is
// used (not MockClient) so the real MultipartRequest.fields can be
// inspected directly -- MockClient's simple Request-based handler cannot
// see individual multipart form fields.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:police_body_cam/models/recording_models.dart';
import 'package:police_body_cam/services/api_client.dart';
import 'package:police_body_cam/services/chunk_uploader.dart';
import 'package:police_body_cam/services/offline_queue_service.dart';

class _FakeStore implements TokenStore {
  @override
  Future<void> delete(String key) async {}
  @override
  Future<String?> read(String key) async => 'test-token';
  @override
  Future<void> write(String key, String value) async {}
}

class _CapturingClient extends http.BaseClient {
  Map<String, String>? capturedFields;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.MultipartRequest) {
      capturedFields = Map.of(request.fields);
    }
    final body = jsonEncode({
      'id': 'chunk-x',
      'recording_session_id': 'rec-1',
      'chunk_number': 1,
      'file_size': 4,
      'duration_seconds': 20.0,
      'file_hash': 'hash',
      'mime_type': 'video/mp4',
      'is_last_chunk': false,
      'upload_status': 'uploaded',
      'created_at': '2026-01-01T00:00:00Z',
    });
    return http.StreamedResponse(Stream.value(utf8.encode(body)), 200, headers: {'content-type': 'application/json'});
  }
}

void main() {
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    OfflineQueueService.databaseName = 'bodycam_chunk_watermark_fields_test.db';
  });

  setUp(() async {
    ApiClient.tokenStore = _FakeStore();
    await OfflineQueueService.resetForTesting();
    final dbPath = p.join(await getDatabasesPath(), OfflineQueueService.databaseName);
    await databaseFactory.deleteDatabase(dbPath);
    tempDir = await Directory.systemTemp.createTemp('bodycam_watermark_fields_test_');
  });

  tearDown(() async {
    await OfflineQueueService.resetForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<File> segmentFile() async {
    final f = File(p.join(tempDir.path, 'segment.mp4'));
    await f.writeAsBytes([0, 1, 2, 3]);
    return f;
  }

  test('a chunk with a real GPS fix sends latitude/longitude/recorded_at as upload fields', () async {
    final client = _CapturingClient();
    ApiClient.httpClient = client;

    final recordedAt = DateTime.utc(2026, 9, 16, 16, 24, 31);
    await OfflineQueueService.enqueueChunk(QueuedChunk(
      localSessionId: 'local-1',
      backendSessionId: 'rec-1',
      chunkNumber: 1,
      localFilePath: (await segmentFile()).path,
      durationSeconds: 20.0,
      isLastChunk: false,
      uploadState: QueuedChunk.statePending,
      retryCount: 0,
      createdAt: DateTime.now(),
      latitude: 16.5062,
      longitude: 80.648,
      recordedAt: recordedAt,
    ));

    await ChunkUploader().drain();

    expect(client.capturedFields, isNotNull);
    expect(client.capturedFields!['latitude'], '16.5062');
    expect(client.capturedFields!['longitude'], '80.648');
    expect(client.capturedFields!['recorded_at'], recordedAt.toIso8601String());
  });

  test('a chunk with no GPS fix (unavailable at capture time) omits latitude/longitude entirely -- never a fabricated 0,0', () async {
    final client = _CapturingClient();
    ApiClient.httpClient = client;

    await OfflineQueueService.enqueueChunk(QueuedChunk(
      localSessionId: 'local-2',
      backendSessionId: 'rec-1',
      chunkNumber: 1,
      localFilePath: (await segmentFile()).path,
      durationSeconds: 20.0,
      isLastChunk: false,
      uploadState: QueuedChunk.statePending,
      retryCount: 0,
      createdAt: DateTime.now(),
    ));

    await ChunkUploader().drain();

    expect(client.capturedFields, isNotNull);
    expect(client.capturedFields!.containsKey('latitude'), isFalse);
    expect(client.capturedFields!.containsKey('longitude'), isFalse);
  });
}
