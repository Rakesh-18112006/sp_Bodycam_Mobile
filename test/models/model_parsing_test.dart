// Verifies every typed model deserializes real backend-shaped JSON
// correctly. This is the concrete payoff of implementation brief §21:
// a backend field rename/removal now fails a fast, specific unit test
// here instead of surfacing as a runtime null/TypeError deep inside the
// UI. Every JSON fixture below is copied field-for-field from the
// corresponding Pydantic schema in backend/app/schemas.py, not guessed.
import 'package:flutter_test/flutter_test.dart';
import 'package:police_body_cam/models/auth_models.dart';
import 'package:police_body_cam/models/command_models.dart';
import 'package:police_body_cam/models/device_models.dart';
import 'package:police_body_cam/models/recording_models.dart';

void main() {
  group('auth_models', () {
    test('TokenResponse.fromJson matches schemas.TokenResponse', () {
      final json = {
        'access_token': 'jwt.token.value',
        'token_type': 'bearer',
        'expires_in': 3600,
        'user': {
          'id': 'a1b2c3d4-0000-0000-0000-000000000001',
          'phone': '9990001111',
          'role': 'constable',
          'is_active': true,
          'station_id': null,
          'created_at': '2026-01-01T00:00:00Z',
        },
      };
      final token = TokenResponse.fromJson(json);
      expect(token.accessToken, 'jwt.token.value');
      expect(token.expiresIn, 3600);
      expect(token.user.phone, '9990001111');
      expect(token.user.role, 'constable');
      expect(token.user.stationId, isNull);
    });
  });

  group('device_models', () {
    test('DeviceResponse.fromJson matches schemas.DeviceResponse', () {
      final json = {
        'id': 'device-1',
        'constable_id': 'constable-1',
        'device_identifier': 'uuid-install-1',
        'platform': 'android',
        'app_version': '1.0.0',
        'device_model': 'Pixel 7',
        'status': 'online',
        'last_heartbeat_at': '2026-01-01T00:00:00Z',
        'last_seen_at': '2026-01-01T00:00:00Z',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': null,
        'battery_percent': 87,
        'is_charging': false,
        'latitude': 12.34,
        'longitude': 56.78,
        'location_updated_at': null,
      };
      final device = DeviceResponse.fromJson(json);
      expect(device.status, 'online');
      expect(device.batteryPercent, 87);
      expect(device.latitude, 12.34);
      expect(device.locationUpdatedAt, isNull);
    });

    test('ConstableLocationResponse.fromJson matches schemas.ConstableLocationResponse', () {
      final json = {
        'status': 'ok',
        'constable_id': 'constable-1',
        'latitude': 12.34,
        'longitude': 56.78,
        'accuracy': 5.0,
        'timestamp': '2026-01-01T00:00:00Z',
      };
      final loc = ConstableLocationResponse.fromJson(json);
      expect(loc.latitude, 12.34);
      expect(loc.accuracy, 5.0);
    });
  });

  group('recording_models', () {
    test('RecordingSessionResponse.fromJson matches schemas.RecordingSessionResponse', () {
      final json = {
        'id': 'rec-1',
        'constable_id': 'constable-1',
        'device_id': 'device-1',
        'trigger_type': 'emergency_button',
        'status': 'recording',
        'started_at': '2026-01-01T00:00:00Z',
        'ended_at': null,
        'incident_id': null,
        'created_at': '2026-01-01T00:00:00Z',
        'chunk_count': 3,
        'highest_chunk_number': 3,
        'missing_chunk_numbers': [2],
      };
      final session = RecordingSessionResponse.fromJson(json);
      expect(session.triggerType, TriggerType.emergencyButton);
      expect(session.status, RecordingStatus.recording);
      expect(session.missingChunkNumbers, [2]);
      expect(session.playableStatus, 'not_ready'); // field omitted above -- must default, never crash
      expect(session.cameraLensDirection, 'back'); // field omitted above -- must default, never crash

      final readyJson = {...json, 'playable_status': 'ready', 'camera_lens_direction': 'front'};
      final readySession = RecordingSessionResponse.fromJson(readyJson);
      expect(readySession.playableStatus, 'ready');
      expect(readySession.cameraLensDirection, 'front');
    });

    test('RecordingManifestResponse.fromJson matches schemas.RecordingManifestResponse', () {
      final json = {
        'recording_session_id': 'rec-1',
        'status': 'completed',
        'chunks': [
          {
            'id': 'chunk-1',
            'recording_session_id': 'rec-1',
            'chunk_number': 1,
            'file_size': 1024,
            'duration_seconds': 20.0,
            'file_hash': 'abc123',
            'mime_type': 'video/mp4',
            'is_last_chunk': false,
            'upload_status': 'uploaded',
            'created_at': '2026-01-01T00:00:00Z',
          },
        ],
        'highest_chunk_number': 1,
        'missing_chunk_numbers': <int>[],
        'is_complete': true,
      };
      final manifest = RecordingManifestResponse.fromJson(json);
      expect(manifest.chunks, hasLength(1));
      expect(manifest.chunks.first.chunkNumber, 1);
      expect(manifest.isComplete, isTrue);
    });

    test('TriggerType.fromWire covers every backend enum value exactly', () {
      expect(TriggerType.fromWire('emergency_button'), TriggerType.emergencyButton);
      expect(TriggerType.fromWire('manual'), TriggerType.manual);
      expect(TriggerType.fromWire('remote'), TriggerType.remote);
    });
  });

  group('command_models', () {
    test('RemoteCommandResponse.fromJson matches schemas.RemoteCommandResponse', () {
      final json = {
        'id': 'cmd-1',
        'device_id': 'device-1',
        'issued_by': 'user-1',
        'command_type': 'start_live_stream',
        'status': 'sent',
        'created_at': '2026-01-01T00:00:00Z',
        'sent_at': '2026-01-01T00:00:01Z',
        'acknowledged_at': null,
        'executed_at': null,
        'failure_reason': null,
      };
      final command = RemoteCommandResponse.fromJson(json);
      expect(command.commandType, RemoteCommandType.startLiveStream);
      expect(command.status, RemoteCommandStatus.sent);
    });

    test('RemoteCommandType.fromWire returns null (never guesses) for an unrecognized value', () {
      expect(RemoteCommandType.fromWire('some_future_command'), isNull);
    });

    test('RemoteCommandType covers all four backend RemoteCommandType values', () {
      expect(RemoteCommandType.fromWire('start_recording'), RemoteCommandType.startRecording);
      expect(RemoteCommandType.fromWire('stop_recording'), RemoteCommandType.stopRecording);
      expect(RemoteCommandType.fromWire('start_live_stream'), RemoteCommandType.startLiveStream);
      expect(RemoteCommandType.fromWire('stop_live_stream'), RemoteCommandType.stopLiveStream);
    });
  });

  group('QueuedChunk (GPS/timestamp watermark fields)', () {
    test('toDb/fromDb round-trips a real GPS fix + recordedAt losslessly', () {
      final recordedAt = DateTime.utc(2026, 9, 16, 16, 24, 31);
      final chunk = QueuedChunk(
        id: 1,
        localSessionId: 'local-1',
        backendSessionId: 'rec-1',
        chunkNumber: 1,
        localFilePath: '/tmp/segment_1.mp4',
        durationSeconds: 20.0,
        isLastChunk: false,
        uploadState: QueuedChunk.statePending,
        retryCount: 0,
        createdAt: DateTime.utc(2026, 9, 16, 16, 24, 51),
        latitude: 16.5062,
        longitude: 80.648,
        recordedAt: recordedAt,
      );

      final restored = QueuedChunk.fromDb(chunk.toDb());

      expect(restored.latitude, 16.5062);
      expect(restored.longitude, 80.648);
      expect(restored.recordedAt, recordedAt);
    });

    test('toDb/fromDb round-trips a genuinely GPS-unavailable chunk as null, never a fabricated 0.0', () {
      final chunk = QueuedChunk(
        id: 1,
        localSessionId: 'local-1',
        backendSessionId: 'rec-1',
        chunkNumber: 1,
        localFilePath: '/tmp/segment_1.mp4',
        durationSeconds: 20.0,
        isLastChunk: false,
        uploadState: QueuedChunk.statePending,
        retryCount: 0,
        createdAt: DateTime.utc(2026, 9, 16, 16, 24, 51),
      );

      final restored = QueuedChunk.fromDb(chunk.toDb());

      expect(restored.latitude, isNull);
      expect(restored.longitude, isNull);
      expect(restored.recordedAt, isNull);
    });
  });
}
