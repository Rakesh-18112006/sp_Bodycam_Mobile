// Regression test for a real physical-device bug (Redmi Note 10 Pro,
// found via on-device validation): ChunkUploader.drain() had no timeout
// on the underlying HTTP call, so a single stalled upload (observed over
// a flaky USB/adb-reverse tunnel) left `_draining` permanently true --
// wedging ALL future chunk uploads for the rest of the app's process
// lifetime, not just the stuck one. Zero chunks ever reached the backend
// in that session despite 10+ minutes of active recording.
//
// This test proves the fix: a hung connection now times out, the chunk is
// requeued as pending (never silently dropped), and -- critically --
// drain() returns and a SUBSEQUENT drain() call can make progress again.
import 'dart:async';
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

/// A client whose `send()` never completes -- simulates the stalled
/// USB/adb-reverse connection observed on the physical device.
class _HangingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return Completer<http.StreamedResponse>().future; // never resolves
  }
}

void main() {
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    OfflineQueueService.databaseName = 'bodycam_chunk_timeout_test.db';
  });

  setUp(() async {
    ApiClient.tokenStore = _FakeStore();
    // Real production values are 30s/60s -- far too slow for a unit test.
    // Overriding the swappable timeout fields (mirroring the existing
    // httpClient/tokenStore test seams) lets this test exercise the exact
    // same timeout code path in well under a second.
    ApiClient.networkTimeout = const Duration(milliseconds: 200);
    ApiClient.uploadTimeout = const Duration(milliseconds: 200);
    await OfflineQueueService.resetForTesting();
    final dbPath = p.join(await getDatabasesPath(), OfflineQueueService.databaseName);
    await databaseFactory.deleteDatabase(dbPath);
    tempDir = await Directory.systemTemp.createTemp('bodycam_timeout_test_');
  });

  tearDown(() async {
    ApiClient.networkTimeout = kNetworkTimeout;
    ApiClient.uploadTimeout = kUploadTimeout;
    await OfflineQueueService.resetForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('a hung upload times out instead of wedging drain() forever, and a later drain() still makes progress', () async {
    final f1 = File(p.join(tempDir.path, 'segment_1.mp4'));
    await f1.writeAsBytes([0, 1, 2, 3]);
    await OfflineQueueService.enqueueChunk(QueuedChunk(
      localSessionId: 'local-session-hang',
      backendSessionId: 'rec-1',
      chunkNumber: 1,
      localFilePath: f1.path,
      durationSeconds: 20.0,
      isLastChunk: false,
      uploadState: QueuedChunk.statePending,
      retryCount: 0,
      createdAt: DateTime.now(),
    ));

    ApiClient.httpClient = _HangingClient();
    final uploader = ChunkUploader();

    // Before the fix, this await would never complete (drain() awaits
    // _uploadOne, which awaited an HTTP call with no timeout).
    await uploader.drain().timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('drain() did not return -- the upload-hang bug has regressed'),
    );

    final afterHang = await OfflineQueueService.allChunksForSession('local-session-hang');
    expect(afterHang.single.uploadState, QueuedChunk.statePending, reason: 'a timed-out upload must be requeued, never silently dropped');
    expect(afterHang.single.retryCount, 1);

    // The real bug's second symptom: _draining stuck true forever, so
    // EVERY future drain() call -- for this chunk or any other -- would
    // silently no-op. Prove a fresh drain() (now against a working
    // client) actually uploads it.
    ApiClient.httpClient = http.Client(); // replaced below by a working mock
    var uploaded = false;
    ApiClient.httpClient = _RespondingClient(() => uploaded = true);
    await uploader.drain().timeout(const Duration(seconds: 5));

    expect(uploaded, isTrue, reason: 'drain() must still be able to upload after a previous hang -- _draining must not stay wedged true');
    final afterRetry = await OfflineQueueService.allChunksForSession('local-session-hang');
    expect(afterRetry.single.uploadState, QueuedChunk.stateUploaded);
  });
}

class _RespondingClient extends http.BaseClient {
  final void Function() onRequest;
  _RespondingClient(this.onRequest);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    onRequest();
    final body = '{"id":"c1","recording_session_id":"rec-1","chunk_number":1,'
        '"file_size":4,"duration_seconds":20.0,"file_hash":"h","mime_type":"video/mp4",'
        '"is_last_chunk":false,"upload_status":"uploaded","created_at":"2026-01-01T00:00:00Z"}';
    return http.StreamedResponse(Stream.value(body.codeUnits), 200);
  }
}
