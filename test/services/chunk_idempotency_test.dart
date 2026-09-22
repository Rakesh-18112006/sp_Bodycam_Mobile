import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:police_body_cam/services/offline_queue_service.dart';
import 'package:police_body_cam/services/chunk_uploader.dart';
import 'package:police_body_cam/services/api_client.dart';
import 'package:police_body_cam/models/recording_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'dart:convert';

class _FakeStore implements TokenStore {
  @override
  Future<void> delete(String key) async {}
  @override
  Future<String?> read(String key) async => 'test-token';
  @override
  Future<void> write(String key, String value) async {}
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    ApiClient.tokenStore = _FakeStore();
    ApiClient.setToken('test_token');
    OfflineQueueService.databaseName = 'bodycam_idempotency_test.db';
    await OfflineQueueService.resetForTesting();
    final file = File('test_chunk.mp4');
    if (!await file.exists()) {
      await file.writeAsString('test video data');
    }
  });

  tearDown(() async {
    await OfflineQueueService.resetForTesting();
    try {
      final dbPath = await getDatabasesPath();
      final path = '$dbPath/bodycam_idempotency_test.db';
      await databaseFactory.deleteDatabase(path);
    } catch (_) {}
    final file = File('test_chunk.mp4');
    if (await file.exists()) {
      await file.delete();
    }
  });

  Future<void> _seedSession(String sessionId) async {
    await OfflineQueueService.upsertSession(
      LocalRecordingSession(
        localSessionId: sessionId,
        startedAt: DateTime.now(),
        triggerType: TriggerType.manual,
        lifecycleState: 'uploading',
        backendSessionId: sessionId,
        deviceIdentifier: 'test_device',
        endedAt: null,
      ),
    );
  }

  test('normal upload -> 200', () async {
    final uploader = ChunkUploader();
    await _seedSession('session1');
    final chunk = QueuedChunk(
      localSessionId: 'session1',
      backendSessionId: 'session1',
      chunkNumber: 1,
      localFilePath: 'test_chunk.mp4',
      isLastChunk: false,
      durationSeconds: 10.0,
      uploadState: QueuedChunk.statePending,
      retryCount: 0,
      createdAt: DateTime.now(),
    );
    await OfflineQueueService.enqueueChunk(chunk);

    ApiClient.httpClient = MockClient((request) async {
      return http.Response('{"detail": "success"}', 200);
    });

    await uploader.drain();
    final pending = await OfflineQueueService.pendingChunks();
    expect(pending, isEmpty);
  });

  test('duplicate upload -> idempotent success', () async {
    final uploader = ChunkUploader();
    await _seedSession('session1');
    await OfflineQueueService.enqueueChunk(QueuedChunk(
      localSessionId: 'session1',
      backendSessionId: 'session1',
      chunkNumber: 1,
      localFilePath: 'test_chunk.mp4',
      isLastChunk: false,
      durationSeconds: 10.0,
      uploadState: QueuedChunk.statePending,
      retryCount: 0,
      createdAt: DateTime.now(),
    ));

    ApiClient.httpClient = MockClient((request) async {
      return http.Response('{"detail": "duplicate"}', 409, headers: {'x-conflict-reason': 'duplicate_chunk'});
    });

    await uploader.drain();
    final pending = await OfflineQueueService.pendingChunks();
    expect(pending, isEmpty);
  });

  test('SocketException -> reconciliation finds chunk', () async {
    final uploader = ChunkUploader();
    await _seedSession('session1');
    await OfflineQueueService.enqueueChunk(QueuedChunk(
      localSessionId: 'session1',
      backendSessionId: 'session1',
      chunkNumber: 1,
      localFilePath: 'test_chunk.mp4',
      isLastChunk: false,
      durationSeconds: 10.0,
      uploadState: QueuedChunk.statePending,
      retryCount: 0,
      createdAt: DateTime.now(),
    ));

    ApiClient.httpClient = MockClient((request) async {
      if (request.url.path.endsWith('/chunks') && request.method == 'GET') {
        return http.Response(jsonEncode({
          'recording_session_id': 'session1',
          'status': 'recording',
          'chunks': [
            {
              'id': 'uuid-1',
              'recording_session_id': 'session1',
              'chunk_number': 1,
              'upload_status': 'uploaded',
              'is_last_chunk': false,
              'created_at': DateTime.now().toIso8601String()
            }
          ],
          'highest_chunk_number': 1,
          'missing_chunk_numbers': [],
          'is_complete': false,
        }), 200);
      }
      throw SocketException('Connection reset by peer');
    });

    await uploader.drain();
    final pending = await OfflineQueueService.pendingChunks();
    expect(pending, isEmpty); // Chunk was reconciled and deleted
  });

  test('SocketException -> chunk does not exist -> retry', () async {
    final uploader = ChunkUploader();
    await _seedSession('session1');
    await OfflineQueueService.enqueueChunk(QueuedChunk(
      localSessionId: 'session1',
      backendSessionId: 'session1',
      chunkNumber: 1,
      localFilePath: 'test_chunk.mp4',
      isLastChunk: false,
      durationSeconds: 10.0,
      uploadState: QueuedChunk.statePending,
      retryCount: 0,
      createdAt: DateTime.now(),
    ));

    ApiClient.httpClient = MockClient((request) async {
      if (request.url.path.endsWith('/chunks') && request.method == 'GET') {
        return http.Response(jsonEncode({
          'recording_session_id': 'session1',
          'status': 'recording',
          'chunks': [], // Not uploaded
          'highest_chunk_number': 0,
          'missing_chunk_numbers': [],
          'is_complete': false,
        }), 200);
      }
      throw SocketException('Connection reset by peer');
    });

    await uploader.drain();
    final pending = await OfflineQueueService.pendingChunks();
    expect(pending.length, 1);
    expect(pending.first.retryCount, 1); // Incremented
    expect(pending.first.uploadState, QueuedChunk.statePending);
  });

  test('SocketException -> max retries exceeded -> stateFailed', () async {
    final uploader = ChunkUploader();
    await _seedSession('session1');
    final chunkId = await OfflineQueueService.enqueueChunk(QueuedChunk(
      localSessionId: 'session1',
      backendSessionId: 'session1',
      chunkNumber: 1,
      localFilePath: 'test_chunk.mp4',
      isLastChunk: false,
      durationSeconds: 10.0,
      uploadState: QueuedChunk.statePending,
      retryCount: 9, // One away from max
      createdAt: DateTime.now(),
    ));

    ApiClient.httpClient = MockClient((request) async {
      throw SocketException('Connection reset by peer');
    });

    await uploader.drain();
    final pending = await OfflineQueueService.pendingChunks();
    expect(pending.length, 1);
    expect(pending.first.retryCount, 10);
    expect(pending.first.uploadState, QueuedChunk.stateFailed);
  });

  test('5xx -> local file preserved', () async {
    final uploader = ChunkUploader();
    await _seedSession('session1');
    await OfflineQueueService.enqueueChunk(QueuedChunk(
      localSessionId: 'session1',
      backendSessionId: 'session1',
      chunkNumber: 1,
      localFilePath: 'test_chunk.mp4',
      isLastChunk: false,
      durationSeconds: 10.0,
      uploadState: QueuedChunk.statePending,
      retryCount: 0,
      createdAt: DateTime.now(),
    ));

    ApiClient.httpClient = MockClient((request) async {
      return http.Response('{"detail": "Internal Error"}', 500);
    });

    await uploader.drain();
    final pending = await OfflineQueueService.pendingChunks();
    expect(pending.length, 1);
    expect(pending.first.retryCount, 1);
    expect(pending.first.uploadState, QueuedChunk.statePending);
    expect(File('test_chunk.mp4').existsSync(), isTrue);
  });
}
