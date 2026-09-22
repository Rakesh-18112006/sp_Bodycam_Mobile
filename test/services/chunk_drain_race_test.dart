// Regression test for a real Internet-only data-loss bug (root-caused from
// a physically-reproduced stuck session: chunk 1 uploaded, no final chunk
// ever stored, recording stuck in status=recording indefinitely).
//
// ChunkUploader.drain() used to guard reentrancy with a plain boolean: a
// second drain() call arriving while a pass was already running just
// returned instantly as a no-op, without waiting for that pass or telling
// it about newly-queued work. Because a single chunk upload takes only
// milliseconds on local/USB but routinely seconds-to-tens-of-seconds over a
// public HTTPS/Cloudflare-Tunnel path, RecordingEngine.stop() enqueuing the
// final chunk and immediately calling drain() (see recording_service.dart)
// could easily land while the periodic pump timer's previous drain() pass
// was still mid-upload of an earlier chunk -- silently dropping the final
// chunk from every pass until pure luck of a future timer tick rescued it,
// or never.
//
// This test proves the fix: a chunk enqueued WHILE another drain() pass is
// already running is still uploaded by that same pass, and a concurrent
// caller's own drain() call only returns once that chunk has genuinely been
// swept.
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

/// Simulates a slow, real (public-Internet-speed) chunk upload: the request
/// for chunk_number=1 is held open on [gate1] until the test explicitly
/// releases it, mirroring the many-seconds-long window a real chunk upload
/// occupies over a Cloudflare Tunnel on mobile data. Any other chunk_number
/// responds immediately.
class _GatedClient extends http.BaseClient {
  final Completer<void> gate1 = Completer<void>();
  final List<String> requestsSeen = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final multipart = request as http.MultipartRequest;
    final chunkNumber = multipart.fields['chunk_number']!;
    requestsSeen.add(chunkNumber);
    if (chunkNumber == '1') {
      await gate1.future;
    }
    final body = '{"id":"c$chunkNumber","recording_session_id":"rec-1","chunk_number":$chunkNumber,'
        '"file_size":4,"duration_seconds":20.0,"file_hash":"h","mime_type":"video/mp4",'
        '"is_last_chunk":false,"upload_status":"uploaded","created_at":"2026-01-01T00:00:00Z"}';
    return http.StreamedResponse(Stream.value(body.codeUnits), 200);
  }
}

void main() {
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    OfflineQueueService.databaseName = 'bodycam_chunk_drain_race_test.db';
  });

  setUp(() async {
    ApiClient.tokenStore = _FakeStore();
    await OfflineQueueService.resetForTesting();
    final dbPath = p.join(await getDatabasesPath(), OfflineQueueService.databaseName);
    await databaseFactory.deleteDatabase(dbPath);
    tempDir = await Directory.systemTemp.createTemp('bodycam_drain_race_test_');
  });

  tearDown(() async {
    ApiClient.httpClient = http.Client();
    await OfflineQueueService.resetForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('a chunk enqueued while a drain() pass is already running (e.g. the final chunk on stop()) is not silently dropped', () async {
    final f1 = File(p.join(tempDir.path, 'segment_1.mp4'));
    await f1.writeAsBytes([0, 1, 2, 3]);
    await OfflineQueueService.enqueueChunk(QueuedChunk(
      localSessionId: 'local-session-race',
      backendSessionId: 'rec-1',
      chunkNumber: 1,
      localFilePath: f1.path,
      durationSeconds: 20.0,
      isLastChunk: false,
      uploadState: QueuedChunk.statePending,
      retryCount: 0,
      createdAt: DateTime.now(),
    ));

    final client = _GatedClient();
    ApiClient.httpClient = client;
    final uploader = ChunkUploader();

    // Mirrors the periodic pump timer's drain() call, currently mid-upload
    // of chunk 1 when the recording is stopped below.
    final firstDrain = uploader.drain();

    // Wait until chunk 1's request has genuinely been sent, so what follows
    // deterministically reproduces "new work arrives while a pass is
    // in-flight" rather than depending on scheduling luck.
    await Future.doWhile(() async {
      if (client.requestsSeen.contains('1')) return false;
      await Future.delayed(const Duration(milliseconds: 5));
      return true;
    }).timeout(const Duration(seconds: 5));

    // Mirrors RecordingEngine.stop() finalizing and enqueueing the final
    // segment, then RecordingService immediately calling _pump() -> drain().
    final f2 = File(p.join(tempDir.path, 'segment_2.mp4'));
    await f2.writeAsBytes([4, 5, 6, 7]);
    await OfflineQueueService.enqueueChunk(QueuedChunk(
      localSessionId: 'local-session-race',
      backendSessionId: 'rec-1',
      chunkNumber: 2,
      localFilePath: f2.path,
      durationSeconds: 18.0,
      isLastChunk: true,
      uploadState: QueuedChunk.statePending,
      retryCount: 0,
      createdAt: DateTime.now(),
    ));
    final secondDrain = uploader.drain();

    // Give the second call a moment to register as "joining" the in-flight
    // pass, then let chunk 1's upload finish.
    await Future.delayed(const Duration(milliseconds: 20));
    client.gate1.complete();

    await Future.wait([firstDrain, secondDrain]).timeout(const Duration(seconds: 5));

    final chunks = await OfflineQueueService.allChunksForSession('local-session-race');
    expect(chunks.length, 2);
    expect(
      chunks.every((c) => c.uploadState == QueuedChunk.stateUploaded),
      isTrue,
      reason: 'the chunk enqueued mid-pass (the final chunk on stop()) must still be uploaded by that same pass, never silently skipped',
    );
    expect(client.requestsSeen, containsAll(['1', '2']));
  });
}
