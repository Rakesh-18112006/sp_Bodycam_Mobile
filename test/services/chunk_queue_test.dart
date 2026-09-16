// The chunk-queue scenario required by implementation brief §25:
//   chunk 1 success, chunk 2 failure, chunk 3 success,
//   retry chunk 2, resume after restart, duplicate prevention
//
// Uses sqflite_common_ffi so this runs as a plain unit test with no
// Android device/emulator, and a MockClient so it never touches a real
// backend. The local segment "files" are real (tiny) files on disk --
// ChunkUploader checks file existence, so a real path is required, but
// their contents are irrelevant to this test (upload success/failure is
// scripted by the mock backend, not by real video validity, which is
// RecordingEngine's concern, exercised separately).
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

void main() {
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    OfflineQueueService.databaseName = 'bodycam_chunk_queue_test.db';
  });

  setUp(() async {
    ApiClient.tokenStore = _FakeStore();
    await OfflineQueueService.resetForTesting();
    final dbPath = p.join(await getDatabasesPath(), OfflineQueueService.databaseName);
    await databaseFactory.deleteDatabase(dbPath);
    tempDir = await Directory.systemTemp.createTemp('bodycam_chunk_test_');
  });

  tearDown(() async {
    await OfflineQueueService.resetForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<File> segmentFile(int n) async {
    final f = File(p.join(tempDir.path, 'segment_$n.mp4'));
    await f.writeAsBytes([0, 1, 2, 3]); // content is irrelevant to this test
    return f;
  }

  test('chunk 1 success, chunk 2 failure, chunk 3 success in one drain pass', () async {
    const sessionId = 'local-session-1';
    for (final n in [1, 2, 3]) {
      await OfflineQueueService.enqueueChunk(QueuedChunk(
        localSessionId: sessionId,
        backendSessionId: 'rec-1',
        chunkNumber: n,
        localFilePath: (await segmentFile(n)).path,
        durationSeconds: 20.0,
        isLastChunk: n == 3,
        uploadState: QueuedChunk.statePending,
        retryCount: 0,
        createdAt: DateTime.now(),
      ));
    }

    final script = [200, 500, 200]; // chunk 1, 2, 3 in that (chunk_number ASC) order
    var callCount = 0;
    ApiClient.httpClient = MockClient((request) async {
      final code = script[callCount];
      callCount++;
      if (code == 200) {
        return http.Response(
          jsonEncode({
            'id': 'chunk-x',
            'recording_session_id': 'rec-1',
            'chunk_number': callCount,
            'file_size': 4,
            'duration_seconds': 20.0,
            'file_hash': 'hash',
            'mime_type': 'video/mp4',
            'is_last_chunk': false,
            'upload_status': 'uploaded',
            'created_at': '2026-01-01T00:00:00Z',
          }),
          200,
        );
      }
      return http.Response(jsonEncode({'detail': 'server error'}), 500);
    });

    await ChunkUploader().drain();

    final all = await OfflineQueueService.allChunksForSession(sessionId);
    expect(all.firstWhere((c) => c.chunkNumber == 1).uploadState, QueuedChunk.stateUploaded);
    expect(all.firstWhere((c) => c.chunkNumber == 2).uploadState, QueuedChunk.statePending);
    expect(all.firstWhere((c) => c.chunkNumber == 2).retryCount, 1);
    expect(all.firstWhere((c) => c.chunkNumber == 3).uploadState, QueuedChunk.stateUploaded);
    expect(callCount, 3, reason: 'all three chunks were attempted, including the one that failed');
  });

  test('retrying chunk 2 succeeds, and already-uploaded chunks are never re-sent (no duplicate uploads)', () async {
    const sessionId = 'local-session-2';
    final f1 = await segmentFile(1);
    final f2 = await segmentFile(2);

    await OfflineQueueService.enqueueChunk(QueuedChunk(
      localSessionId: sessionId,
      backendSessionId: 'rec-1',
      chunkNumber: 1,
      localFilePath: f1.path,
      durationSeconds: 20.0,
      isLastChunk: false,
      uploadState: QueuedChunk.stateUploaded, // already confirmed uploaded in a prior pass
      retryCount: 0,
      createdAt: DateTime.now(),
    ));
    await OfflineQueueService.enqueueChunk(QueuedChunk(
      localSessionId: sessionId,
      backendSessionId: 'rec-1',
      chunkNumber: 2,
      localFilePath: f2.path,
      durationSeconds: 20.0,
      isLastChunk: true,
      uploadState: QueuedChunk.statePending, // failed previously, awaiting retry
      retryCount: 1,
      createdAt: DateTime.now(),
    ));

    var callCount = 0;
    ApiClient.httpClient = MockClient((request) async {
      callCount++;
      return http.Response(
        jsonEncode({
          'id': 'chunk-2',
          'recording_session_id': 'rec-1',
          'chunk_number': 2,
          'file_size': 4,
          'duration_seconds': 20.0,
          'file_hash': 'hash',
          'mime_type': 'video/mp4',
          'is_last_chunk': true,
          'upload_status': 'uploaded',
          'created_at': '2026-01-01T00:00:00Z',
        }),
        200,
      );
    });

    await ChunkUploader().drain();

    expect(callCount, 1, reason: 'only the still-pending chunk 2 should be uploaded -- chunk 1 must not be re-sent');
    final chunk2 = (await OfflineQueueService.allChunksForSession(sessionId)).firstWhere((c) => c.chunkNumber == 2);
    expect(chunk2.uploadState, QueuedChunk.stateUploaded);
  });

  test('pending chunks survive a simulated app restart (db handle closed and reopened)', () async {
    const sessionId = 'local-session-3';
    final f1 = await segmentFile(1);
    await OfflineQueueService.enqueueChunk(QueuedChunk(
      localSessionId: sessionId,
      backendSessionId: 'rec-1',
      chunkNumber: 1,
      localFilePath: f1.path,
      durationSeconds: 20.0,
      isLastChunk: true,
      uploadState: QueuedChunk.statePending,
      retryCount: 0,
      createdAt: DateTime.now(),
    ));

    // Simulate the app process dying and restarting: close the cached
    // Database handle (resetForTesting) WITHOUT deleting the underlying
    // file, then let the next call reopen it fresh -- exactly what
    // RecordingService.recoverOnStartup relies on at real app startup.
    await OfflineQueueService.resetForTesting();

    final resumed = await OfflineQueueService.pendingChunks(localSessionId: sessionId);
    expect(resumed, hasLength(1));
    expect(resumed.first.chunkNumber, 1);
  });

  test('duplicate chunk_number for the same session is rejected at the database level', () async {
    const sessionId = 'local-session-4';
    final f1 = await segmentFile(1);
    final chunk = QueuedChunk(
      localSessionId: sessionId,
      backendSessionId: 'rec-1',
      chunkNumber: 1,
      localFilePath: f1.path,
      durationSeconds: 20.0,
      isLastChunk: false,
      uploadState: QueuedChunk.statePending,
      retryCount: 0,
      createdAt: DateTime.now(),
    );
    await OfflineQueueService.enqueueChunk(chunk);

    await expectLater(
      () => OfflineQueueService.enqueueChunk(chunk),
      throwsA(isA<DatabaseException>()),
      reason: 'the UNIQUE(local_session_id, chunk_number) constraint must reject a second chunk 1 for the same recording',
    );
  });

  test('a missing local segment file is marked permanently failed, not retried forever', () async {
    const sessionId = 'local-session-5';
    await OfflineQueueService.enqueueChunk(QueuedChunk(
      localSessionId: sessionId,
      backendSessionId: 'rec-1',
      chunkNumber: 1,
      localFilePath: p.join(tempDir.path, 'never_written.mp4'),
      durationSeconds: 20.0,
      isLastChunk: true,
      uploadState: QueuedChunk.statePending,
      retryCount: 0,
      createdAt: DateTime.now(),
    ));

    var callCount = 0;
    ApiClient.httpClient = MockClient((request) async {
      callCount++;
      return http.Response('', 200);
    });

    await ChunkUploader().drain();

    expect(callCount, 0, reason: 'a chunk whose local file is gone must never be uploaded');
    final chunk = (await OfflineQueueService.allChunksForSession(sessionId)).first;
    expect(chunk.uploadState, QueuedChunk.stateFailed);
  });
}
