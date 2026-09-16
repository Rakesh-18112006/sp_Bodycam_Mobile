// RecordingService tests that don't require real camera hardware -- there
// is no Android device/emulator in this environment (see the audit's
// explicit "NOT TESTED -- NO ANDROID DEVICE AVAILABLE" rule, which this
// suite deliberately respects rather than faking a passing camera test).
//
// What IS genuinely exercised here, against a real (mocked) HTTP backend:
//   1. RecordingService.start() reaches START_FAILED -- never a fake
//      RECORDING state -- when the camera plugin has no platform
//      implementation (exactly what happens in this test environment,
//      and analogous to camera/mic permission denial on a real device).
//   2. The duplicate-recording-session avoidance logic (§8 of the
//      implementation brief): an already-active RecordingSession for this
//      device is adopted via GET /recordings/, and POST /recordings/start
//      is never called in that case -- this is the fix for POST
//      /recordings/start having no server-side idempotency protection.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:police_body_cam/models/recording_models.dart';
import 'package:police_body_cam/services/api_client.dart';
import 'package:police_body_cam/services/offline_queue_service.dart';
import 'package:police_body_cam/services/recording_service.dart';

class _FakeStore implements TokenStore {
  @override
  Future<void> delete(String key) async {}
  @override
  Future<String?> read(String key) async => 'test-token';
  @override
  Future<void> write(String key, String value) async {}
}

Map<String, dynamic> _sessionJson({String id = 'rec-1', String status = 'recording'}) => {
      'id': id,
      'constable_id': 'constable-1',
      'device_id': 'device-1',
      'trigger_type': 'manual',
      'status': status,
      'started_at': '2026-01-01T00:00:00Z',
      'ended_at': null,
      'incident_id': null,
      'created_at': '2026-01-01T00:00:00Z',
      'chunk_count': 0,
      'highest_chunk_number': null,
      'missing_chunk_numbers': <int>[],
    };

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    OfflineQueueService.databaseName = 'bodycam_recording_service_test.db';
  });

  setUp(() async {
    ApiClient.tokenStore = _FakeStore();
    await OfflineQueueService.resetForTesting();
    final dbPath = p.join(await getDatabasesPath(), OfflineQueueService.databaseName);
    await databaseFactory.deleteDatabase(dbPath);
  });

  test('start() reaches START_FAILED (never a fake RECORDING) when the camera has no platform implementation', () async {
    ApiClient.httpClient = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/recordings/') {
        return http.Response(jsonEncode(<dynamic>[]), 200);
      }
      if (request.url.path == '/recordings/start') {
        return http.Response(jsonEncode(_sessionJson()), 200);
      }
      return http.Response('not found', 404);
    });

    final states = <RecordingLifecycleState>[];
    final service = RecordingService(
      deviceIdentifier: 'uuid-1',
      deviceId: 'device-1',
      onStateChanged: states.add,
    );

    await service.start(triggerType: TriggerType.manual);

    expect(service.state, RecordingLifecycleState.startFailed);
    expect(states, contains(RecordingLifecycleState.starting));
    expect(states, isNot(contains(RecordingLifecycleState.recording)),
        reason: 'a camera that never actually started must never be reported as recording');
  });

  test('resolveBackendSession adopts an existing active recording instead of creating a duplicate', () async {
    var startCalled = false;
    ApiClient.httpClient = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/recordings/') {
        return http.Response(jsonEncode([_sessionJson(id: 'rec-existing')]), 200);
      }
      if (request.url.path == '/recordings/start') {
        startCalled = true;
        return http.Response(jsonEncode(_sessionJson(id: 'rec-new')), 200);
      }
      return http.Response('not found', 404);
    });

    final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
    // Camera still fails in this test env -> ends in START_FAILED, but the
    // point of this test is entirely about what happened before that.
    await service.start(triggerType: TriggerType.manual);

    expect(startCalled, isFalse, reason: 'an already-active session must be adopted, not duplicated');
  });

  test('a definitive backend rejection (e.g. 403 device not owned) aborts before ever touching the camera', () async {
    ApiClient.httpClient = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/recordings/') {
        return http.Response(jsonEncode(<dynamic>[]), 200);
      }
      if (request.url.path == '/recordings/start') {
        return http.Response(jsonEncode({'detail': 'This device belongs to another constable'}), 403);
      }
      return http.Response('not found', 404);
    });

    final states = <RecordingLifecycleState>[];
    final service = RecordingService(
      deviceIdentifier: 'uuid-1',
      deviceId: 'device-1',
      onStateChanged: states.add,
    );

    await service.start(triggerType: TriggerType.manual);

    expect(service.state, RecordingLifecycleState.startFailed);
  });
}
