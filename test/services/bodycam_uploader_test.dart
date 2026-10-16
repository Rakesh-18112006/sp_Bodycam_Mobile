// Routing, acknowledgements, central-manifest deletion gate, corruption detection and queue upgrade for Network Hopping.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:police_body_cam/models/recording_models.dart';
import 'package:police_body_cam/services/api_client.dart';
import 'package:police_body_cam/services/chunk_uploader.dart';
import 'package:police_body_cam/services/network_hopping_service.dart';
import 'package:police_body_cam/services/offline_queue_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/test_keys.dart';

const _site = '11111111-1111-1111-1111-111111111111';
const _dev = '22222222-2222-2222-2222-222222222222';
const _officer = '33333333-3333-3333-3333-333333333333';
const _central = 'https://bodycam-backend-qo1e.onrender.com';
const _recv = 'https://receiver.site.test:8443';

class _Store implements TokenStore {
  final m = <String, String>{};
  @override
  Future<void> delete(String key) async => m.remove(key);
  @override
  Future<String?> read(String key) async => m[key];
  @override
  Future<void> write(String key, String value) async => m[key] = value;
}

String _grant() {
  final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  return JWT({'iss': 'sp-bodycam-control-room', 'sub': _officer, 'jti': 'g1', 'site': _site, 'dev': _dev, 'ops': ['session', 'upload'], 'iat': now, 'exp': now + 3600, 'ver': 1})
      .sign(ECPrivateKey(trustedPrivatePem), algorithm: JWTAlgorithm.ES256, noIssueAt: true);
}

class _World {
  bool centralUp = true, receiverUp = true;
  http.Response Function(http.BaseRequest req)? receiverChunk;
  List<Map<String, dynamic>> manifest = [];
  final calls = <String>[];
  String lastStart = '';
  int centralChunkStatus = 200;

  int count(String needle) => calls.where((c) => c.contains(needle)).length;

  http.Client client() => MockClient.streaming((req, body) async {
        final bytes = await body.toBytes();
        final key = '${req.method} ${req.url.origin}${req.url.path}';
        calls.add(key);
        http.StreamedResponse ok(Object json, [int status = 200, Map<String, String>? headers]) =>
            http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(json))), status, headers: {'content-type': 'application/json', ...?headers});
        if (req.url.origin == _central) {
          if (!centralUp) throw const SocketException('central down');
          if (req.url.path == '/healthz') return ok({'status': 'ok', 'service': 'sp-bodycam-central'});
          if (req.url.path == '/recordings/start') {
            lastStart = utf8.decode(bytes);
            return ok({'id': 's'});
          }
          if (req.url.path.endsWith('/chunks') && req.method == 'POST') return ok({'id': 'c', 'upload_status': 'uploaded'}, centralChunkStatus);
          if (req.url.path.endsWith('/chunks') && req.method == 'GET') {
            return ok({
              'recording_session_id': 's',
              'status': 'recording',
              'chunks': manifest,
              'highest_chunk_number': manifest.length,
              'missing_chunk_numbers': [],
              'is_complete': false
            });
          }
          if (req.url.path == '/mobile/v1/network-hopping/config') return ok(_config());
        }
        if (req.url.origin == _recv) {
          if (!receiverUp) throw const SocketException('receiver down');
          if (req.url.path == '/v1/health') return ok({'status': 'ok', 'service': 'sp-bodycam-receiver', 'api': 'v1', 'ready': true});
          if (req.url.path == '/v1/auth/session') return ok({'access_token': 't', 'expires_in': 900, 'receiver': {'site_id': _site}});
          if (req.url.path == '/v1/recordings' && req.method == 'POST') return ok({'created': true});
          if (req.method == 'PUT' && req.url.path.contains('/chunks/')) {
            if (receiverChunk != null) {
              final r = receiverChunk!(req);
              return http.StreamedResponse(Stream.value(utf8.encode(r.body)), r.statusCode, headers: {'content-type': 'application/json', ...r.headers});
            }
            final chunkId = req.url.pathSegments.last;
            final sha = RegExp(r'name="sha256"\r\n\r\n([0-9a-f]{64})').firstMatch(utf8.decode(bytes, allowMalformed: true))!.group(1);
            return ok({'status': 'locally_durable', 'ack': 'local_received', 'sha256': sha, 'chunk_id': chunkId, 'sync_state': 'pending_sync', 'duplicate': false});
          }
        }
        return http.StreamedResponse(Stream.value(utf8.encode('{}')), 404);
      });
}

Map<String, dynamic> _config() => {
      'server_time': DateTime.now().toUtc().toIso8601String(),
      'device_id': _dev,
      'constable_id': _officer,
      'grant_issuer': 'sp-bodycam-control-room',
      'grant_lifetime_hours': 8,
      'grant_public_keys': [
        {'kid': null, 'pem': trustedPublicPem}
      ],
      'sites': [
        {
          'site_id': _site,
          'site_code': 'S1',
          'site_name': 'Site',
          'assignment_id': 'a',
          'eligible': true,
          'receivers': [
            {'id': 'r1', 'code': 'R1', 'name': 'Gate', 'endpoint_url': _recv, 'local_live_enabled': false, 'configured': true}
          ],
          'grant': _grant(),
          'grant_id': 'g1',
          'grant_expires_at': DateTime.now().toUtc().add(const Duration(hours: 8)).toIso8601String(),
        }
      ],
    };

void main() {
  late _World w;
  late Directory dir;
  final nh = NetworkHoppingService.instance;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('bodycam_uploader_');
    w = _World();
    ApiClient.tokenStore = _Store();
    await ApiClient.setToken('t');
    await ApiClient.setDeviceIdentifier('device-ident');
    ApiClient.httpClient = w.client();
    OfflineQueueService.databaseName = 'bodycam_routing_${DateTime.now().microsecondsSinceEpoch}.db';
    await OfflineQueueService.resetForTesting();
    await nh.load();
    await nh.refreshConfig();
    await nh.setMode(TransportMode.networkHopping);
    await nh.setCentralFallback(true);
    nh.clearReceiverAuthBlock();
    nh.invalidateSession();
    await nh.centralReachable(force: true);
    w.calls.clear();
  });

  tearDown(() async {
    await OfflineQueueService.resetForTesting();
    try {
      await databaseFactory.deleteDatabase('${await getDatabasesPath()}/${OfflineQueueService.databaseName}');
    } catch (_) {}
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<QueuedChunk> seed({String session = 'sess', String? siteId = _site, int n = 1, List<int>? bytes, bool nhSession = true, String? declaredSha, bool withHash = true}) async {
    final data = bytes ?? List<int>.generate(2048, (i) => (i * 7 + n) % 251);
    final file = File('${dir.path}/segment_${n.toString().padLeft(6, '0')}.mp4')..writeAsBytesSync(data);
    if (await OfflineQueueService.getSession(session) == null) {
      await OfflineQueueService.upsertSession(LocalRecordingSession(
          localSessionId: session,
          backendSessionId: nhSession ? null : session,
          deviceIdentifier: 'device-ident',
          triggerType: TriggerType.manual,
          lifecycleState: 'uploading',
          startedAt: DateTime.now(),
          endedAt: null,
          siteId: siteId,
          networkHopping: nhSession));
    }
    final id = await OfflineQueueService.enqueueChunk(QueuedChunk(
      localSessionId: session,
      backendSessionId: nhSession ? null : session,
      chunkNumber: n,
      localFilePath: file.path,
      durationSeconds: 20,
      isLastChunk: false,
      uploadState: QueuedChunk.statePending,
      retryCount: 0,
      createdAt: DateTime.now(),
      siteId: siteId,
      chunkId: withHash ? '00000000-0000-4000-8000-00000000000$n' : null,
      sha256: withHash ? (declaredSha ?? crypto.sha256.convert(data).toString()) : null,
      sizeBytes: withHash ? data.length : null,
    ));
    return (await OfflineQueueService.allChunksForSession(session)).firstWhere((c) => c.id == id);
  }

  Future<QueuedChunk> reload(QueuedChunk c) async => (await OfflineQueueService.allChunksForSession(c.localSessionId)).firstWhere((x) => x.id == c.id);

  group('routing', () {
    test('a Network Hopping chunk goes to the receiver and is only local_acked; the file is kept', () async {
      final c = await seed();
      await ChunkUploader().drain();
      final r = await reload(c);
      expect(r.uploadState, QueuedChunk.stateLocalAcked);
      expect(r.target, 'receiver');
      expect(File(c.localFilePath).existsSync(), isTrue, reason: 'receipt by the site receiver never releases the phone copy');
      expect(w.count('POST $_central/recordings/'), 0, reason: 'nothing was uploaded to the control room');
    });

    test('the receiver registration carries the phone-generated recording id', () async {
      await seed(session: 'recording-uuid-1');
      await ChunkUploader().drain();
      expect(w.count('PUT $_recv/v1/recordings/recording-uuid-1/chunks/'), 1);
    });

    test('an Online-mode chunk still goes straight to the control room, even with fallback off and the receiver down', () async {
      await nh.setCentralFallback(false);
      w.receiverUp = false;
      final c = await seed(session: 'online-s', siteId: null, nhSession: false);
      await ChunkUploader().drain();
      expect((await reload(c)).uploadState, QueuedChunk.stateUploaded);
      expect(File(c.localFilePath).existsSync(), isFalse, reason: 'central 2xx is confirmation: the file may go');
      expect(w.count('POST $_central/recordings/online-s/chunks'), 1);
      expect(w.count(_recv), 0, reason: 'Online-mode chunks never touch a receiver');
    });

    test('a site chunk with fallback off and no receiver waits and is not sent anywhere', () async {
      await nh.setCentralFallback(false);
      w.receiverUp = false;
      final c = await seed();
      await ChunkUploader().drain();
      final r = await reload(c);
      expect(r.uploadState, QueuedChunk.statePending);
      expect(w.count('POST $_central/recordings/'), 0);
    });

    test('site and online chunks coexist: the online one is not blocked by the missing route', () async {
      await nh.setCentralFallback(false);
      w.receiverUp = false;
      final site = await seed(session: 'site-s', n: 1);
      final online = await seed(session: 'online-s', siteId: null, nhSession: false, n: 2);
      await ChunkUploader().drain();
      expect((await reload(site)).uploadState, QueuedChunk.statePending);
      expect((await reload(online)).uploadState, QueuedChunk.stateUploaded);
    });

    test('with the receiver down and fallback on, a site chunk goes to the control room under its own recording id', () async {
      w.receiverUp = false;
      final c = await seed(session: 'site-s');
      await ChunkUploader().drain();
      expect((await reload(c)).uploadState, QueuedChunk.stateUploaded);
      expect(w.count('POST $_central/recordings/start'), 1, reason: 'idempotent registration under the client id');
      expect(w.lastStart, contains('"recording_id":"site-s"'));
    });

    test('a chunk of another site is never handed to this site\'s receiver', () async {
      final c = await seed(siteId: '99999999-9999-9999-9999-999999999999');
      await ChunkUploader().drain();
      expect((await reload(c)).uploadState, QueuedChunk.statePending);
      expect(w.count('PUT $_recv/v1/recordings/'), 0);
    });
  });

  group('acknowledgements and the central deletion gate', () {
    Map<String, dynamic> entry(QueuedChunk c, String? hash) => {
          'id': 'x',
          'recording_session_id': c.localSessionId,
          'chunk_number': c.chunkNumber,
          'file_size': 1,
          'duration_seconds': 20,
          'file_hash': 'derived-hash',
          'mime_type': 'video/mp4',
          'is_last_chunk': false,
          'upload_status': 'uploaded',
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'original_hash': hash,
        };

    test('only a central manifest with the same original_hash releases the phone copy', () async {
      final c = await seed();
      await ChunkUploader().drain();
      expect((await reload(c)).uploadState, QueuedChunk.stateLocalAcked);

      w.manifest = [];
      await ChunkUploader().drain();
      expect((await reload(c)).uploadState, QueuedChunk.stateLocalAcked, reason: 'not listed centrally yet');

      w.manifest = [entry(c, null)];
      await ChunkUploader().drain();
      expect((await reload(c)).uploadState, QueuedChunk.stateLocalAcked, reason: 'a manifest entry that cannot prove identity is not confirmation');
      expect(File(c.localFilePath).existsSync(), isTrue);

      w.manifest = [entry(c, c.sha256)];
      await ChunkUploader().drain();
      final done = await reload(c);
      expect(done.uploadState, QueuedChunk.stateUploaded);
      expect(File(c.localFilePath).existsSync(), isFalse);
    });

    test('a central hash mismatch keeps the file and flags the chunk', () async {
      final c = await seed();
      await ChunkUploader().drain();
      w.manifest = [entry(c, 'f' * 64)];
      await ChunkUploader().drain();
      final r = await reload(c);
      expect(r.uploadState, QueuedChunk.stateFailed);
      expect(r.lastError, 'central_hash_mismatch');
      expect(File(c.localFilePath).existsSync(), isTrue);
    });

    test('a receiver that reports the chunk as quarantined is not a receipt', () async {
      w.receiverChunk = (req) => http.Response(
          jsonEncode({'status': 'locally_durable', 'ack': 'local_received', 'sha256': 'x', 'chunk_id': 'x', 'sync_state': 'quarantined'}), 200);
      final c = await seed();
      await ChunkUploader().drain();
      final r = await reload(c);
      expect(r.uploadState, QueuedChunk.stateFailed);
      expect(r.lastError, 'receiver_quarantined');
      expect(File(c.localFilePath).existsSync(), isTrue);
    });

    test('an acknowledgement for different content is not accepted', () async {
      w.receiverChunk = (req) => http.Response(
          jsonEncode({'status': 'locally_durable', 'sha256': 'e' * 64, 'chunk_id': req.url.pathSegments.last, 'sync_state': 'pending_sync'}), 200);
      final c = await seed();
      await ChunkUploader().drain();
      expect((await reload(c)).uploadState, QueuedChunk.statePending);
    });

    test('409 chunk_quarantined from the receiver parks the chunk and keeps the file', () async {
      w.receiverChunk = (req) => http.Response(jsonEncode({'error': {'code': 'chunk_quarantined', 'message': 'q'}}), 409);
      final c = await seed();
      await ChunkUploader().drain();
      final r = await reload(c);
      expect(r.uploadState, QueuedChunk.stateFailed);
      expect(r.lastError, 'chunk_quarantined');
      expect(File(c.localFilePath).existsSync(), isTrue);
    });
  });

  group('failure handling', () {
    test('a revoked grant pauses the receiver, keeps the chunk pending and does not retry like a network error', () async {
      await nh.setCentralFallback(false);
      w.receiverChunk = (req) => http.Response(jsonEncode({'error': {'code': 'grant_revoked', 'message': 'r'}}), 403);
      final c = await seed();
      await ChunkUploader().drain();
      final r = await reload(c);
      expect(r.uploadState, QueuedChunk.statePending);
      expect(r.lastError, 'grant_revoked');
      expect(nh.receiverStatus, 'grant_revoked');
      w.calls.clear();
      await OfflineQueueService.clearBackoff();
      await ChunkUploader().drain();
      expect(w.count(_recv), 0, reason: 'receiver contact is paused for ten minutes');
    });

    test('receiver storage full is retryable: pending with a future attempt time', () async {
      w.receiverChunk = (req) => http.Response(jsonEncode({'error': {'code': 'storage_full', 'message': 's'}}), 507, headers: {'retry-after': '120'});
      final c = await seed();
      await ChunkUploader().drain();
      final r = await reload(c);
      expect(r.uploadState, QueuedChunk.statePending);
      expect(r.nextAttemptAt, greaterThan(DateTime.now().millisecondsSinceEpoch + 100000));
    });

    test('a file changed after capture is detected before upload, kept, and its expected hash is never rewritten', () async {
      final c = await seed();
      final damaged = File(c.localFilePath).readAsBytesSync()..[100] ^= 0xFF;
      File(c.localFilePath).writeAsBytesSync(damaged);
      await ChunkUploader().drain();
      final r = await reload(c);
      expect(r.uploadState, QueuedChunk.stateFailed);
      expect(r.lastError, 'local_file_corrupt');
      expect(r.sha256, c.sha256, reason: 'the expected hash must stay the one computed at capture');
      expect(File(c.localFilePath).existsSync(), isTrue);
      expect(w.count('PUT $_recv/v1/recordings/'), 0);
      expect(w.count('POST $_central/recordings/'), 0);
      expect(await OfflineQueueService.requeueFailed(), 0, reason: 'a corrupt file is not blindly re-queued');
    });

    test('a changed size alone is also detected', () async {
      final c = await seed();
      File(c.localFilePath).writeAsBytesSync(File(c.localFilePath).readAsBytesSync() + [1]);
      await ChunkUploader().drain();
      expect((await reload(c)).lastError, 'local_file_corrupt');
    });

    test('a chunk without a recorded hash gets one computed once and keeps the same identity on retry', () async {
      w.receiverUp = false;
      w.centralChunkStatus = 503; // the control room is busy: the attempt is deferred after identity was assigned
      final c = await seed(withHash: false);
      await ChunkUploader().drain();
      final first = await reload(c);
      expect(first.chunkId, isNotNull);
      expect(first.sha256, crypto.sha256.convert(File(c.localFilePath).readAsBytesSync()).toString());
      await OfflineQueueService.clearBackoff();
      await ChunkUploader().drain();
      final second = await reload(c);
      expect(second.chunkId, first.chunkId);
      expect(second.sha256, first.sha256);
    });

    test('a missing file is a permanent local failure and is not re-queued automatically', () async {
      final c = await seed();
      File(c.localFilePath).deleteSync();
      await ChunkUploader().drain();
      final r = await reload(c);
      expect(r.uploadState, QueuedChunk.stateFailed);
      expect(r.lastError, 'local_file_missing');
    });

    test('network failures never exhaust a chunk, however many attempts have been made', () async {
      await nh.setCentralFallback(false);
      w.receiverUp = false;
      final c = await seed();
      for (var i = 0; i < 12; i++) {
        await OfflineQueueService.clearBackoff();
        await ChunkUploader().drain();
      }
      expect((await reload(c)).uploadState, QueuedChunk.statePending);
    });
  });

  group('queue upgrade v2 -> v3', () {
    test('existing rows are preserved; only retry-cap failures return to pending', () async {
      await OfflineQueueService.resetForTesting();
      final name = 'bodycam_v2_${DateTime.now().microsecondsSinceEpoch}.db';
      final path = '${await getDatabasesPath()}/$name';
      final old = await databaseFactory.openDatabase(path,
          options: OpenDatabaseOptions(version: 2, onCreate: (db, v) async {
            await db.execute('CREATE TABLE recording_sessions (local_session_id TEXT PRIMARY KEY, backend_session_id TEXT, device_identifier TEXT NOT NULL, trigger_type TEXT NOT NULL, lifecycle_state TEXT NOT NULL, started_at TEXT NOT NULL, ended_at TEXT)');
            await db.execute(
                'CREATE TABLE chunk_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, local_session_id TEXT NOT NULL, backend_session_id TEXT, chunk_number INTEGER NOT NULL, local_file_path TEXT NOT NULL, duration_seconds REAL, is_last_chunk INTEGER NOT NULL DEFAULT 0, upload_state TEXT NOT NULL DEFAULT \'pending\', retry_count INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, latitude REAL, longitude REAL, recorded_at TEXT, UNIQUE(local_session_id, chunk_number))');
          }));
      await old.insert('recording_sessions', {'local_session_id': 's1', 'backend_session_id': 'b1', 'device_identifier': 'd', 'trigger_type': 'manual', 'lifecycle_state': 'uploading', 'started_at': DateTime.now().toIso8601String()});
      Future<void> row(int n, String state, int retries) => old.insert('chunk_queue', {
            'local_session_id': 's1', 'backend_session_id': 'b1', 'chunk_number': n, 'local_file_path': '/x/$n.mp4', 'duration_seconds': 20.0,
            'is_last_chunk': 0, 'upload_state': state, 'retry_count': retries, 'created_at': DateTime.now().toIso8601String(), 'latitude': 1.5, 'longitude': 2.5,
          });
      await row(1, 'uploaded', 0);
      await row(2, 'pending', 3);
      await row(3, 'failed', 8); // parked by the old retry cap
      await row(4, 'failed', 1); // a definitive rejection
      await row(5, 'failed', 9);
      await old.close();

      OfflineQueueService.databaseName = name;
      await OfflineQueueService.resetForTesting();
      final chunks = await OfflineQueueService.allChunksForSession('s1');
      final by = {for (final c in chunks) c.chunkNumber: c};
      expect(chunks.length, 5, reason: 'nothing is dropped');
      expect(by[1]!.uploadState, QueuedChunk.stateUploaded);
      expect(by[2]!.uploadState, QueuedChunk.statePending);
      expect(by[3]!.uploadState, QueuedChunk.statePending);
      expect(by[5]!.uploadState, QueuedChunk.statePending);
      expect(by[3]!.lastError, 'legacy_retry_exhausted_requeued');
      expect(by[4]!.uploadState, QueuedChunk.stateFailed, reason: 'a definitive failure is not retried blindly');
      expect(by[3]!.latitude, 1.5, reason: 'existing metadata survives');
      expect(by[3]!.localFilePath, '/x/3.mp4');
      final session = await OfflineQueueService.getSession('s1');
      expect(session!.networkHopping, isFalse);
      expect(session.cameraLens, 'back');
      await OfflineQueueService.resetForTesting();
      await databaseFactory.deleteDatabase(path);
    });
  });
}
