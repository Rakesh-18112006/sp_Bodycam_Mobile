// Unit tests for the Go-Live screen's pure display-formatting helpers (see
// lib/utils/watermark_display.dart). These verify the ON-SCREEN UI text
// only -- see recording_watermark_test.dart / the backend's own pytest
// suite for what's actually burned into the video frames. A passing test
// here is NEVER evidence that GPS/time text exists inside an encoded video
// file.
import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:police_body_cam/models/location_models.dart';
import 'package:police_body_cam/models/recording_models.dart';
import 'package:police_body_cam/services/location_service.dart';
import 'package:police_body_cam/utils/watermark_display.dart';

void main() {
  group('formatWatermarkTimestamp', () {
    test('formats as YYYY-MM-DD HH:MM:SS with zero-padding', () {
      final dt = DateTime(2026, 9, 16, 6, 4, 3);
      expect(formatWatermarkTimestamp(dt), '2026-09-16 06:04:03');
    });

    test('does not zero-pad the year and does pad every other component', () {
      final dt = DateTime(2026, 1, 2, 23, 59, 5);
      expect(formatWatermarkTimestamp(dt), '2026-01-02 23:59:05');
    });
  });

  group('gpsWatermarkText', () {
    test('a real fix formats latitude/longitude to 6 decimal places', () {
      final fix = GpsFix(latitude: 16.5062, longitude: 80.648, accuracy: 5.0, capturedAt: DateTime.now());
      expect(gpsWatermarkText(fix: fix, availability: LocationAvailability.available), 'GPS: 16.506200, 80.648000');
    });

    test('never fabricates coordinates -- shows WAITING FOR LOCATION when available but no fix yet', () {
      expect(gpsWatermarkText(fix: null, availability: LocationAvailability.available), 'GPS: WAITING FOR LOCATION');
    });

    test('shows SIGNAL UNAVAILABLE when permission/service is not available', () {
      expect(gpsWatermarkText(fix: null, availability: LocationAvailability.permissionDeniedForever), 'GPS: SIGNAL UNAVAILABLE');
      expect(gpsWatermarkText(fix: null, availability: LocationAvailability.serviceDisabled), 'GPS: SIGNAL UNAVAILABLE');
      expect(gpsWatermarkText(fix: null, availability: LocationAvailability.unknown), 'GPS: SIGNAL UNAVAILABLE');
    });
  });

  group('cameraWatermarkLabel', () {
    test('front lens', () => expect(cameraWatermarkLabel(CameraLensDirection.front), 'FRONT'));
    test('back lens', () => expect(cameraWatermarkLabel(CameraLensDirection.back), 'BACK'));
  });

  group('recordingTopStatusLabel', () {
    test('normal recording', () {
      expect(recordingTopStatusLabel(state: RecordingLifecycleState.recording, isEmergency: false), 'RECORDING');
    });

    test('emergency recording is visually/textually distinct from normal recording', () {
      final normal = recordingTopStatusLabel(state: RecordingLifecycleState.recording, isEmergency: false);
      final emergency = recordingTopStatusLabel(state: RecordingLifecycleState.recording, isEmergency: true);
      expect(emergency, 'EMERGENCY RECORDING');
      expect(emergency, isNot(equals(normal)));
    });

    test('uploading is never confused with recording', () {
      final recording = recordingTopStatusLabel(state: RecordingLifecycleState.recording, isEmergency: false);
      final uploading = recordingTopStatusLabel(state: RecordingLifecycleState.uploading, isEmergency: false);
      expect(uploading, 'FINISHING UPLOAD');
      expect(uploading, isNot(equals(recording)));
    });

    test('completing is never confused with recording or uploading', () {
      expect(recordingTopStatusLabel(state: RecordingLifecycleState.completing, isEmergency: false), 'COMPLETING');
    });

    test('offline recording is labeled distinctly, with emergency prefix preserved', () {
      expect(recordingTopStatusLabel(state: RecordingLifecycleState.offline, isEmergency: false), 'RECORDING -- OFFLINE');
      expect(recordingTopStatusLabel(state: RecordingLifecycleState.offline, isEmergency: true), 'EMERGENCY RECORDING -- OFFLINE');
    });

    test('starting is labeled distinctly', () {
      expect(recordingTopStatusLabel(state: RecordingLifecycleState.starting, isEmergency: false), 'STARTING');
    });
  });

  group('uploadStatusText', () {
    test('all chunks uploaded shows a checkmark, distinct from "uploaded" mid-recording', () {
      expect(uploadStatusText(uploaded: 3, pending: 0, failed: 0), '✓ All chunks uploaded');
    });

    test('zero chunks so far is not shown as "all uploaded"', () {
      expect(uploadStatusText(uploaded: 0, pending: 0, failed: 0), 'Upload: 0 uploaded, 0 pending');
    });

    test('pending chunks are shown, not conflated with uploaded', () {
      expect(uploadStatusText(uploaded: 2, pending: 1, failed: 0), 'Upload: 2 uploaded, 1 pending');
    });

    test('failed chunks are surfaced explicitly', () {
      expect(uploadStatusText(uploaded: 2, pending: 0, failed: 1), 'Upload: 2 uploaded, 0 pending, 1 failed');
    });
  });
}
