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
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:camera/camera.dart' show CameraLensDirection;
import 'package:police_body_cam/models/recording_models.dart';
import 'package:police_body_cam/services/api_client.dart';
import 'package:police_body_cam/services/offline_queue_service.dart';
import 'package:police_body_cam/services/recording_service.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  final String rootPath;
  _FakePathProviderPlatform(this.rootPath);
  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;
}

class _FakeStore implements TokenStore {
  @override
  Future<void> delete(String key) async {}
  @override
  Future<String?> read(String key) async => 'test-token';
  @override
  Future<void> write(String key, String value) async {}
}

Map<String, dynamic> _sessionJson({
  String id = 'rec-1',
  String status = 'recording',
  String triggerType = 'manual',
  String cameraLensDirection = 'back',
  DateTime? createdAt,
}) {
  final created = (createdAt ?? DateTime.now()).toUtc().toIso8601String();
  return {
    'id': id,
    'constable_id': 'constable-1',
    'device_id': 'device-1',
    'trigger_type': triggerType,
    'status': status,
    'started_at': created,
    'ended_at': null,
    'incident_id': null,
    'created_at': created,
    'chunk_count': 0,
    'highest_chunk_number': null,
    'missing_chunk_numbers': <int>[],
    'camera_lens_direction': cameraLensDirection,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  // REGRESSION: real stuck-session bug found via physical Internet testing
  // -- 11 orphaned RecordingSession rows discovered server-side, several
  // created seconds-to-milliseconds apart on the same device, every one
  // stuck at status="recording" with zero chunks forever. Root cause: when
  // _resolveBackendSession() successfully creates a backend session but the
  // camera then fails to actually start (this test's environment always
  // hits that path -- no platform implementation for the camera
  // MethodChannel), the backend was never told to release that session.
  test('a backend session created just before the camera fails to start is cancelled, not orphaned', () async {
    final requestedPaths = <String>[];
    ApiClient.httpClient = MockClient((request) async {
      requestedPaths.add('${request.method} ${request.url.path}');
      if (request.method == 'GET' && request.url.path == '/recordings/') {
        return http.Response(jsonEncode(<dynamic>[]), 200);
      }
      if (request.url.path == '/recordings/start') {
        return http.Response(jsonEncode(_sessionJson(id: 'rec-orphan-candidate')), 200);
      }
      if (request.url.path == '/recordings/rec-orphan-candidate/cancel') {
        return http.Response(jsonEncode(_sessionJson(id: 'rec-orphan-candidate', status: 'cancelled')), 200);
      }
      return http.Response('not found', 404);
    });

    final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
    await service.start(triggerType: TriggerType.manual);

    expect(service.state, RecordingLifecycleState.startFailed);
    expect(
      requestedPaths,
      contains('POST /recordings/rec-orphan-candidate/cancel'),
      reason: 'the backend session created by _resolveBackendSession must be cancelled, never left stuck at status=recording, when the camera then fails to start',
    );
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

  // Regression tests for a real bug found via physical device testing: an
  // unrelated session left "recording" server-side by a previous
  // crash/kill (not yet reconciled by recoverOnStartup) was silently
  // adopted and later completed by a totally separate, fresh recording
  // attempt -- violating "a fresh trigger must never reuse an unrelated
  // old RecordingSession". The fix only adopts an existing active session
  // when it plausibly IS this exact start() call's own lost-response
  // retry: matching trigger_type + camera, created within a realistic
  // retry window of this call's own start time.

  test('a stale active session (same trigger/camera, but created long ago) is NEVER adopted -- a fresh session is created instead', () async {
    var startCalled = false;
    ApiClient.httpClient = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/recordings/') {
        // Looks identical to a genuine own-retry (same trigger_type,
        // same camera) except for being from 20 minutes ago -- exactly
        // the shape of the real orphaned session this bug was found with.
        return http.Response(
            jsonEncode([_sessionJson(id: 'rec-stale-orphan', createdAt: DateTime.now().subtract(const Duration(minutes: 20)))]),
            200);
      }
      if (request.url.path == '/recordings/start') {
        startCalled = true;
        return http.Response(jsonEncode(_sessionJson(id: 'rec-fresh')), 200);
      }
      return http.Response('not found', 404);
    });

    final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
    await service.start(triggerType: TriggerType.manual);

    expect(startCalled, isTrue, reason: 'a session from 20 minutes ago must never be mistaken for a lost-response retry of a brand new attempt');
  });

  test('an active session with a DIFFERENT trigger_type is never adopted even if freshly created', () async {
    var startCalled = false;
    ApiClient.httpClient = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/recordings/') {
        // Recent, but this device's "active" session was started by a
        // remote command, not the emergency button we're starting now --
        // must never be conflated.
        return http.Response(jsonEncode([_sessionJson(id: 'rec-other-trigger', triggerType: 'remote')]), 200);
      }
      if (request.url.path == '/recordings/start') {
        startCalled = true;
        return http.Response(jsonEncode(_sessionJson(id: 'rec-fresh', triggerType: 'emergency_button')), 200);
      }
      return http.Response('not found', 404);
    });

    final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
    await service.start(triggerType: TriggerType.emergencyButton, cameraLensDirection: CameraLensDirection.front);

    expect(startCalled, isTrue, reason: 'trigger_type mismatch means this is a different recording attempt, never our own retry');
  });

  test('an active session with a DIFFERENT camera is never adopted even if freshly created and trigger_type matches', () async {
    var startCalled = false;
    ApiClient.httpClient = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/recordings/') {
        return http.Response(jsonEncode([_sessionJson(id: 'rec-other-camera', triggerType: 'emergency_button', cameraLensDirection: 'back')]), 200);
      }
      if (request.url.path == '/recordings/start') {
        startCalled = true;
        return http.Response(jsonEncode(_sessionJson(id: 'rec-fresh', triggerType: 'emergency_button', cameraLensDirection: 'front')), 200);
      }
      return http.Response('not found', 404);
    });

    final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
    await service.start(triggerType: TriggerType.emergencyButton, cameraLensDirection: CameraLensDirection.front);

    expect(startCalled, isTrue, reason: 'camera mismatch means this is a different recording attempt, never our own retry');
  });

  test('a genuinely recent own-retry with matching trigger_type AND camera is still correctly adopted', () async {
    var startCalled = false;
    ApiClient.httpClient = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/recordings/') {
        return http.Response(
            jsonEncode([_sessionJson(id: 'rec-own-retry', triggerType: 'emergency_button', cameraLensDirection: 'front', createdAt: DateTime.now().subtract(const Duration(seconds: 5)))]),
            200);
      }
      if (request.url.path == '/recordings/start') {
        startCalled = true;
        return http.Response(jsonEncode(_sessionJson(id: 'rec-fresh')), 200);
      }
      return http.Response('not found', 404);
    });

    final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
    await service.start(triggerType: TriggerType.emergencyButton, cameraLensDirection: CameraLensDirection.front);

    expect(startCalled, isFalse, reason: 'a matching, seconds-old session is exactly the lost-response-retry case this lookup exists for');
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

  test('start() accepts an explicit front-camera selection and still fails cleanly (no camera platform impl here), never a fake RECORDING', () async {
    // No camera hardware/platform implementation exists in this test
    // environment (see the file header) so this cannot verify the front
    // lens physically opens -- that is exactly why the user's own
    // requirement is verified on a real device (see the physical test
    // matrix), not here. What this test DOES guarantee: passing a non-default
    // CameraLensDirection through RecordingService.start() is plumbed without
    // throwing, and still surfaces as a real START_FAILED rather than ever
    // reporting a fake success.
    ApiClient.httpClient = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/recordings/') {
        return http.Response(jsonEncode(<dynamic>[]), 200);
      }
      if (request.url.path == '/recordings/start') {
        return http.Response(jsonEncode(_sessionJson()), 200);
      }
      return http.Response('not found', 404);
    });

    final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');

    await service.start(triggerType: TriggerType.manual, cameraLensDirection: CameraLensDirection.front);

    expect(service.state, RecordingLifecycleState.startFailed);
  });

  test('start() sends camera_lens_direction="front" to POST /recordings/start when front is selected', () async {
    Map<String, dynamic>? capturedBody;
    ApiClient.httpClient = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/recordings/') {
        return http.Response(jsonEncode(<dynamic>[]), 200);
      }
      if (request.url.path == '/recordings/start') {
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode(_sessionJson()), 200);
      }
      return http.Response('not found', 404);
    });

    final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
    await service.start(triggerType: TriggerType.manual, cameraLensDirection: CameraLensDirection.front);

    expect(capturedBody, isNotNull);
    expect(capturedBody!['camera_lens_direction'], 'front');
  });

  test('start() sends camera_lens_direction="back" by default (unchanged existing behavior)', () async {
    Map<String, dynamic>? capturedBody;
    ApiClient.httpClient = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/recordings/') {
        return http.Response(jsonEncode(<dynamic>[]), 200);
      }
      if (request.url.path == '/recordings/start') {
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode(_sessionJson()), 200);
      }
      return http.Response('not found', 404);
    });

    final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
    await service.start(triggerType: TriggerType.manual); // no cameraLensDirection passed

    expect(capturedBody, isNotNull);
    expect(capturedBody!['camera_lens_direction'], 'back');
  });

  test('activeTriggerType reflects the trigger this recording attempt actually started with', () async {
    ApiClient.httpClient = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/recordings/') {
        return http.Response(jsonEncode(<dynamic>[]), 200);
      }
      if (request.url.path == '/recordings/start') {
        return http.Response(jsonEncode(_sessionJson()), 200);
      }
      return http.Response('not found', 404);
    });

    final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
    await service.start(triggerType: TriggerType.emergencyButton);

    expect(service.activeTriggerType, TriggerType.emergencyButton);
  });

  // Background-pause/resume state-machine tests (Task 6; updated for the
  // native-CameraX background/locked-recording migration -- see
  // recording_service.dart's pauseForBackground()/resumeFromBackground()
  // doc comments). A real CameraController cannot be exercised in this
  // environment (no Android device/emulator here -- see this file's own
  // top-of-file note), so RecordingService's internal _engine stays null
  // throughout these tests and pauseForBackground()/resumeFromBackground()'s
  // calls into it are safe, inert no-ops.
  //
  // UNDER THE CURRENT ARCHITECTURE, pausing/resuming no longer mutate
  // [state] AT ALL, from any state: the native camera pipeline is bound to
  // its own Activity-independent LifecycleOwner and keeps capturing
  // straight through backgrounding/screen-lock, so there is nothing to
  // pause -- entering RecordingLifecycleState.backgroundPaused would be
  // actively misleading (see home_screen.dart's now-unreachable "Recording
  // paused (app in background)" label). What IS still genuinely,
  // meaningfully tested here is that calling these methods is always safe
  // (never throws, never corrupts state) regardless of the state they're
  // called from. The camera-hardware-dependent half (chunks continuing to
  // be produced/uploaded while genuinely backgrounded/locked) can only be
  // verified by physical device testing -- see the physical verification
  // report, not faked here.
  group('pauseForBackground / resumeFromBackground state machine', () {
    test('1. pausing from RECORDING is a no-op -- native camera capture continues, so state stays RECORDING', () async {
      final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
      service.state = RecordingLifecycleState.recording;
      await service.pauseForBackground();
      expect(service.state, RecordingLifecycleState.recording);
    });

    test('2. pausing from OFFLINE (camera still running, only network down) is also a no-op -- state stays OFFLINE', () async {
      final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
      service.state = RecordingLifecycleState.offline;
      await service.pauseForBackground();
      expect(service.state, RecordingLifecycleState.offline);
    });

    test('6a. pausing is idempotent -- calling it twice in a row never mutates state', () async {
      final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
      service.state = RecordingLifecycleState.recording;
      await service.pauseForBackground();
      await service.pauseForBackground();
      expect(service.state, RecordingLifecycleState.recording);
    });

    test('9. resuming does not mutate state -- there is nothing to resume under the native camera architecture', () async {
      final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
      service.state = RecordingLifecycleState.recording;
      await service.resumeFromBackground();
      expect(service.state, RecordingLifecycleState.recording);
    });

    test('6b. resuming is idempotent -- calling it twice never mutates state', () async {
      final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
      service.state = RecordingLifecycleState.recording;
      await service.resumeFromBackground();
      await service.resumeFromBackground();
      expect(service.state, RecordingLifecycleState.recording);
    });

    test('3+4. pausing/resuming from every state where there is no active camera segment is rejected outright (an old/irrelevant signal can never mutate state it does not own)', () async {
      for (final s in [
        RecordingLifecycleState.idle,
        RecordingLifecycleState.starting,
        RecordingLifecycleState.startFailed,
        RecordingLifecycleState.uploading,
        RecordingLifecycleState.completing,
        RecordingLifecycleState.completeFailed,
        RecordingLifecycleState.completed,
        RecordingLifecycleState.cancelled,
      ]) {
        final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
        service.state = s;
        await service.pauseForBackground();
        expect(service.state, s, reason: 'pauseForBackground must never mutate state $s');

        final service2 = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
        service2.state = s;
        await service2.resumeFromBackground();
        expect(service2.state, s, reason: 'resumeFromBackground must never mutate state $s');
      }
    });

    test('BACKGROUND_PAUSED counts as isActive -- a paused recording is still a genuinely ongoing one, not idle', () async {
      final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
      service.state = RecordingLifecycleState.backgroundPaused;
      expect(service.isActive, isTrue);
    });

    test('10. resumeFromBackground() called while a stop is already underway (state still reads backgroundPaused mid-flight) never restarts the camera -- the real crash this fixes', () async {
      // Reproduces, at the RecordingService level, the exact race a real
      // physical crash was traced to: state only transitions AWAY from
      // backgroundPaused partway through stop()'s own async _pump()/
      // _complete() chain, so a resumeFromBackground() arriving in that
      // window could previously still see state == backgroundPaused and
      // wrongly reinitialize the camera -- reproducing
      // Recorder.onConfigured()'s AssertionError via a second path
      // distinct from the original Home-backgrounding one. _stopRequested
      // is set synchronously, before stop()'s first await, so calling
      // resumeFromBackground() immediately after starting (not awaiting)
      // stop() genuinely exercises this exact window.
      ApiClient.httpClient = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/recordings/') {
          return http.Response(jsonEncode(<dynamic>[]), 200);
        }
        if (request.url.path.endsWith('/complete')) {
          return http.Response(jsonEncode(_sessionJson(status: 'completed')), 200);
        }
        return http.Response(jsonEncode(<dynamic>[]), 200);
      });

      final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
      service.state = RecordingLifecycleState.backgroundPaused;

      final stopFuture = service.stop(); // deliberately not awaited yet
      await service.resumeFromBackground();

      expect(service.state, isNot(RecordingLifecycleState.recording),
          reason: 'must never flip back to a live-recording state once a stop is underway');

      await stopFuture;
    });

    test(
        'REGRESSION (test #10): RecordingService.stop() cannot call backend /complete before the final chunk has actually uploaded, even if the native "stop" call resolves early',
        () async {
      final tempRoot = Directory.systemTemp.createTempSync('bodycam_rs_final_chunk_test_');
      addTearDown(() => tempRoot.deleteSync(recursive: true));
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempRoot.path);

      const recordingChannel = MethodChannel('com.policebodycam.recording');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(recordingChannel, null));

      Future<void> simulateNativeCall(MethodCall call) async {
        final data = recordingChannel.codec.encodeMethodCall(call);
        final completer = Completer<void>();
        await messenger.handlePlatformMessage(recordingChannel.name, data, (_) => completer.complete());
        await completer.future;
      }

      final finalSegmentPath = p.join(tempRoot.path, 'final_segment.mp4');
      messenger.setMockMethodCallHandler(recordingChannel, (call) async {
        if (call.method == 'start') return {'started': true};
        if (call.method == 'stop') {
          // Simulates the pre-fix native behavior on purpose: resolve
          // "stop" immediately, deliver the final segment slightly later.
          unawaited(Future<void>.delayed(const Duration(milliseconds: 15), () {
            simulateNativeCall(MethodCall('segmentReady', {
              'chunkNumber': 1,
              'path': finalSegmentPath,
              'durationSeconds': 1.5,
              'isLastChunk': true,
              'startedAtMillis': 0,
            }));
          }));
          return null;
        }
        return null;
      });
      // A real file is needed -- ChunkUploader checks existence before upload.
      File(finalSegmentPath).writeAsBytesSync([0, 1, 2, 3]);

      final callLog = <String>[];
      ApiClient.httpClient = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/recordings/') {
          return http.Response(jsonEncode(<dynamic>[]), 200);
        }
        if (request.url.path == '/recordings/start') {
          return http.Response(jsonEncode(_sessionJson()), 200);
        }
        if (request.url.path.endsWith('/chunks') && request.method == 'POST') {
          callLog.add('chunk-upload');
          return http.Response(
            jsonEncode({
              'id': 'chunk-1',
              'recording_session_id': 'rec-1',
              'chunk_number': 1,
              'file_size': 4,
              'duration_seconds': 1.5,
              'file_hash': 'hash',
              'mime_type': 'video/mp4',
              'is_last_chunk': true,
              'upload_status': 'uploaded',
              'created_at': '2026-01-01T00:00:00Z',
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/complete')) {
          callLog.add('complete');
          return http.Response(jsonEncode(_sessionJson(status: 'completed')), 200);
        }
        return http.Response(jsonEncode(<dynamic>[]), 200);
      });

      final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
      await service.start(triggerType: TriggerType.manual);
      expect(service.state, RecordingLifecycleState.recording, reason: 'start() must have genuinely succeeded for this test to be meaningful');

      final stopStopwatch = Stopwatch()..start();
      await service.stop();
      stopStopwatch.stop();

      // REGRESSION (background/locked-upload audit): stop() must return as
      // soon as the camera has stopped and the final chunk is persisted
      // locally -- it must NEVER block on the upload actually completing
      // (that upload can legitimately take tens of seconds on real mobile
      // Internet; see chunk_uploader.dart/recording_service.dart's own doc
      // comments). No upload call has happened yet at this point -- the
      // mock backend's chunk-upload response is instant, but stop() must
      // not even have started waiting on it synchronously.
      expect(
        stopStopwatch.elapsed,
        lessThan(const Duration(milliseconds: 200)),
        reason: 'stop() must return immediately (camera stopped + final chunk enqueued), never block on the upload queue draining',
      );

      // The upload/completion now happen asynchronously, fired off by
      // stop() without being awaited -- give that a moment to actually run
      // before asserting on it.
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (service.state != RecordingLifecycleState.completed && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(callLog.indexOf('chunk-upload'), greaterThanOrEqualTo(0), reason: 'the final chunk must have been uploaded');
      expect(
        callLog.indexOf('chunk-upload'),
        lessThan(callLog.indexOf('complete')),
        reason: 'the backend must never see /complete before the final chunk\'s own upload -- this is the exact bug that lost real evidence footage during a remote STOP',
      );
      expect(service.state, RecordingLifecycleState.completed);
    });

    test(
        'REGRESSION (background/locked-upload audit): stop() returns immediately even with a large backlog of slow-uploading historical chunks -- it must never wait for the whole upload queue',
        () async {
      // Directly reproduces the reported symptom ("the app continues
      // appearing to record/running while files are being uploaded"):
      // several chunks from EARLIER in the recording are still slowly
      // uploading (mirroring real ~20-40s/chunk mobile Internet speeds)
      // at the moment STOP is pressed. stop() must return as soon as the
      // camera stops and the final chunk is enqueued -- not after those
      // historical chunks (which it has no reason to wait for) finish.
      final tempRoot = Directory.systemTemp.createTempSync('bodycam_rs_stop_immediate_test_');
      addTearDown(() => tempRoot.deleteSync(recursive: true));
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempRoot.path);

      const recordingChannel = MethodChannel('com.policebodycam.recording');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(recordingChannel, null));

      Future<void> simulateNativeCall(MethodCall call) async {
        final data = recordingChannel.codec.encodeMethodCall(call);
        final completer = Completer<void>();
        await messenger.handlePlatformMessage(recordingChannel.name, data, (_) => completer.complete());
        await completer.future;
      }

      final finalSegmentPath = p.join(tempRoot.path, 'final_segment.mp4');
      messenger.setMockMethodCallHandler(recordingChannel, (call) async {
        if (call.method == 'start') return {'started': true};
        if (call.method == 'stop') {
          unawaited(Future<void>.delayed(const Duration(milliseconds: 15), () {
            simulateNativeCall(MethodCall('segmentReady', {
              'chunkNumber': 3,
              'path': finalSegmentPath,
              'durationSeconds': 1.5,
              'isLastChunk': true,
              'startedAtMillis': 0,
            }));
          }));
          return null;
        }
        return null;
      });
      File(finalSegmentPath).writeAsBytesSync([0, 1, 2, 3]);

      // Every chunk upload takes 500ms to respond -- if stop() incorrectly
      // waited for the queue to drain, it would take at least
      // 2 (pre-existing) + 1 (final) = 1.5s+. The assertion below requires
      // it to return in under 200ms instead.
      ApiClient.httpClient = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/recordings/') {
          return http.Response(jsonEncode(<dynamic>[]), 200);
        }
        if (request.url.path == '/recordings/start') {
          return http.Response(jsonEncode(_sessionJson()), 200);
        }
        if (request.url.path.endsWith('/chunks') && request.method == 'POST') {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          return http.Response(
            jsonEncode({
              'id': 'chunk-x', 'recording_session_id': 'rec-1', 'chunk_number': 1,
              'file_size': 4, 'duration_seconds': 1.5, 'file_hash': 'hash', 'mime_type': 'video/mp4',
              'is_last_chunk': false, 'upload_status': 'uploaded', 'created_at': '2026-01-01T00:00:00Z',
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/complete')) {
          return http.Response(jsonEncode(_sessionJson(status: 'completed')), 200);
        }
        return http.Response(jsonEncode(<dynamic>[]), 200);
      });

      final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
      await service.start(triggerType: TriggerType.manual);
      expect(service.state, RecordingLifecycleState.recording);

      // Two historical segments, still pending, exactly as if the periodic
      // pump's own drain() had not yet caught up with them (the same
      // scenario the prior drain-race fix targets).
      await OfflineQueueService.enqueueChunk(QueuedChunk(
        localSessionId: 'irrelevant', backendSessionId: 'rec-1', chunkNumber: 1,
        localFilePath: finalSegmentPath, durationSeconds: 20, isLastChunk: false,
        uploadState: QueuedChunk.statePending, retryCount: 0, createdAt: DateTime.now(),
      ));
      await OfflineQueueService.enqueueChunk(QueuedChunk(
        localSessionId: 'irrelevant', backendSessionId: 'rec-1', chunkNumber: 2,
        localFilePath: finalSegmentPath, durationSeconds: 20, isLastChunk: false,
        uploadState: QueuedChunk.statePending, retryCount: 0, createdAt: DateTime.now(),
      ));

      final stopStopwatch = Stopwatch()..start();
      await service.stop();
      stopStopwatch.stop();

      expect(
        stopStopwatch.elapsed,
        lessThan(const Duration(milliseconds: 200)),
        reason: 'stop() must never block on historical pending chunks uploading -- the camera stopping and the final chunk being enqueued is all it needs to wait for',
      );

      // stop() intentionally leaves the upload continuing in the
      // background (that's the whole point of this fix) -- but THIS TEST
      // must not leave it dangling into the next test: OfflineQueueService
      // and ApiClient.httpClient are both static/shared, so a still-running
      // background drain() here would race the next test's setUp()
      // (resetForTesting() closes the database) and fail with a spurious
      // "database already closed" error that has nothing to do with
      // whatever that next test is actually checking. Waiting for every
      // chunk to finish draining (bounded, not the unbounded never-happens
      // case a real hang would need) keeps this test's own async work
      // fully contained before the next test starts.
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (DateTime.now().isBefore(deadline)) {
        final pending = await OfflineQueueService.pendingChunks();
        if (pending.isEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    test('5. start() while BACKGROUND_PAUSED is a no-op -- returning to the foreground can never create a second, duplicate recording', () async {
      var startCalled = false;
      ApiClient.httpClient = MockClient((request) async {
        if (request.url.path == '/recordings/start') {
          startCalled = true;
        }
        return http.Response('not found', 404);
      });
      final service = RecordingService(deviceIdentifier: 'uuid-1', deviceId: 'device-1');
      service.state = RecordingLifecycleState.backgroundPaused;
      await service.start(triggerType: TriggerType.manual);
      expect(startCalled, isFalse, reason: 'isActive already covers backgroundPaused, so start() must bail out immediately');
      expect(service.state, RecordingLifecycleState.backgroundPaused, reason: 'start() must never overwrite an already-active (paused) recording\'s state');
    });
  });

  group('recoverOnStartup orphaned segment file recovery', () {
    test(
        'REGRESSION (background/locked-upload audit): a segment file written to disk but never enqueued (Dart engine torn down mid-recording) is recovered and uploaded on next launch',
        () async {
      final tempRoot = Directory.systemTemp.createTempSync('bodycam_orphan_recovery_test_');
      addTearDown(() => tempRoot.deleteSync(recursive: true));
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempRoot.path);

      const localSessionId = 'orphan-local-session';
      final sessionDir = Directory(p.join(tempRoot.path, 'recordings', localSessionId));
      sessionDir.createSync(recursive: true);

      // chunk 1: already known to the queue (uploaded) -- must NOT be
      // re-enqueued or re-uploaded by the scan.
      File(p.join(sessionDir.path, 'segment_000001.mp4')).writeAsBytesSync([1]);
      // chunk 2: exists on disk but has NO chunk_queue row at all -- the
      // exact scenario this recovery targets (native wrote it; Dart never
      // got to enqueue it before the engine was torn down).
      File(p.join(sessionDir.path, 'segment_000002.mp4')).writeAsBytesSync([2]);
      // A stray non-matching file must be ignored, not misparsed.
      File(p.join(sessionDir.path, 'not_a_segment.txt')).writeAsBytesSync([0]);

      await OfflineQueueService.upsertSession(LocalRecordingSession(
        localSessionId: localSessionId,
        backendSessionId: 'rec-orphan',
        deviceIdentifier: 'uuid-1',
        triggerType: TriggerType.manual,
        lifecycleState: RecordingLifecycleState.uploading.name,
        startedAt: DateTime.now().subtract(const Duration(minutes: 5)),
        endedAt: null,
      ));
      await OfflineQueueService.enqueueChunk(QueuedChunk(
        localSessionId: localSessionId,
        backendSessionId: 'rec-orphan',
        chunkNumber: 1,
        localFilePath: p.join(sessionDir.path, 'segment_000001.mp4'),
        durationSeconds: 20,
        isLastChunk: false,
        uploadState: QueuedChunk.stateUploaded,
        retryCount: 0,
        createdAt: DateTime.now(),
      ));

      var chunkUploadCallCount = 0;
      var completeCalled = false;
      ApiClient.httpClient = MockClient((request) async {
        if (request.url.path.endsWith('/chunks') && request.method == 'POST') {
          chunkUploadCallCount++;
          return http.Response(
            jsonEncode({
              'id': 'chunk-recovered', 'recording_session_id': 'rec-orphan',
              'chunk_number': 2, 'file_size': 1,
              'duration_seconds': null, 'file_hash': 'hash', 'mime_type': 'video/mp4',
              'is_last_chunk': false, 'upload_status': 'uploaded', 'created_at': '2026-01-01T00:00:00Z',
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/complete')) {
          completeCalled = true;
          return http.Response(jsonEncode(_sessionJson(id: 'rec-orphan', status: 'completed')), 200);
        }
        return http.Response(jsonEncode(<dynamic>[]), 200);
      });

      final messages = <String>[];
      await RecordingService.recoverOnStartup(onRecovered: messages.add);

      expect(
        chunkUploadCallCount,
        1,
        reason: 'exactly one upload -- the orphaned file (segment_000002.mp4, no prior chunk_queue row) must be discovered and uploaded, and chunk 1 (already uploaded) must never be re-enqueued or re-uploaded',
      );
      final finalChunks = await OfflineQueueService.allChunksForSession(localSessionId);
      final chunk2 = finalChunks.firstWhere((c) => c.chunkNumber == 2);
      expect(chunk2.uploadState, QueuedChunk.stateUploaded, reason: 'the recovered orphan chunk must reach the uploaded state');
      expect(completeCalled, isTrue, reason: 'once the recovered chunk uploads and the queue is empty, the session must still complete');
    });

    test(
        'REGRESSION (real Internet test finding): a session whose chunks are ALL already uploaded -- including the final one -- still gets /complete called on recovery, even though this pass never had to drain anything',
        () async {
      // Physically reproduced: all 6 chunks of a real recording (including
      // is_last_chunk=true) reached upload_status=uploaded server-side, but
      // the app process died (device went "offline", no further
      // heartbeats) in the narrow window between the final chunk's upload
      // succeeding and _pump()'s own post-upload completion check running.
      // The session stayed stuck at status=recording indefinitely despite
      // having 100% of its evidence safely stored -- because the old
      // recoverOnStartup() folded "every chunk already uploaded" into the
      // same early-exit as "nothing uploadable at all" and never called
      // /complete for it.
      final tempRoot = Directory.systemTemp.createTempSync('bodycam_already_uploaded_recovery_test_');
      addTearDown(() => tempRoot.deleteSync(recursive: true));
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempRoot.path);

      const localSessionId = 'already-uploaded-local-session';

      await OfflineQueueService.upsertSession(LocalRecordingSession(
        localSessionId: localSessionId,
        backendSessionId: 'rec-already-uploaded',
        deviceIdentifier: 'uuid-1',
        triggerType: TriggerType.manual,
        lifecycleState: RecordingLifecycleState.uploading.name,
        startedAt: DateTime.now().subtract(const Duration(minutes: 5)),
        endedAt: null,
      ));
      for (var n = 1; n <= 6; n++) {
        await OfflineQueueService.enqueueChunk(QueuedChunk(
          localSessionId: localSessionId,
          backendSessionId: 'rec-already-uploaded',
          chunkNumber: n,
          localFilePath: p.join(tempRoot.path, 'segment_${n.toString().padLeft(6, '0')}.mp4'),
          durationSeconds: 20,
          isLastChunk: n == 6,
          uploadState: QueuedChunk.stateUploaded, // every single chunk already confirmed uploaded
          retryCount: 0,
          createdAt: DateTime.now(),
        ));
      }

      var completeCalled = false;
      var chunkUploadCalled = false;
      ApiClient.httpClient = MockClient((request) async {
        if (request.url.path.endsWith('/chunks') && request.method == 'POST') {
          chunkUploadCalled = true; // must never happen -- nothing is pending
          return http.Response('{}', 200);
        }
        if (request.url.path.endsWith('/complete')) {
          completeCalled = true;
          return http.Response(jsonEncode(_sessionJson(id: 'rec-already-uploaded', status: 'completed')), 200);
        }
        return http.Response(jsonEncode(<dynamic>[]), 200);
      });

      final messages = <String>[];
      await RecordingService.recoverOnStartup(onRecovered: messages.add);

      expect(chunkUploadCalled, isFalse, reason: 'no chunk was pending -- recovery must not attempt to re-upload anything');
      expect(
        completeCalled,
        isTrue,
        reason: 'every chunk being ALREADY uploaded before this recovery pass began must still result in /complete being called -- the old early-exit silently skipped this exact case',
      );
    });
  });
}
