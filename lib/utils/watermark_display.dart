/// Pure, side-effect-free formatting helpers for the Go-Live recording
/// screen's on-screen overlay (home_screen.dart::_recordingGoLiveCard).
/// Extracted out of the widget specifically so this logic -- timestamp
/// formatting, GPS text, camera label, upload status text, and the
/// RECORDING/EMERGENCY RECORDING/UPLOADING/COMPLETING status label -- is
/// unit-testable without needing a real widget/camera/location platform
/// channel. This is the ON-SCREEN UI text only; the backend independently
/// computes its own equivalent text to burn into the actual video frames
/// (see backend/app/routers/recordings.py::_format_watermark_text) from
/// the same underlying real data, not from this module.
library;

import 'package:camera/camera.dart' show CameraLensDirection;
import '../models/location_models.dart';
import '../models/recording_models.dart';
import '../services/location_service.dart' show LocationAvailability;

String formatWatermarkTimestamp(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}

/// Never returns a fabricated coordinate -- "SIGNAL UNAVAILABLE"/"WAITING
/// FOR LOCATION" whenever there is no real fix yet, matching exactly what
/// the backend does when latitude/longitude are omitted from a chunk
/// upload (see _format_watermark_text's gps_text branch).
String gpsWatermarkText({required GpsFix? fix, required LocationAvailability availability}) {
  if (fix != null) return 'GPS: ${fix.latitude.toStringAsFixed(6)}, ${fix.longitude.toStringAsFixed(6)}';
  if (availability == LocationAvailability.available) return 'GPS: WAITING FOR LOCATION';
  return 'GPS: SIGNAL UNAVAILABLE';
}

String cameraWatermarkLabel(CameraLensDirection direction) => direction == CameraLensDirection.front ? 'FRONT' : 'BACK';

/// Distinguishes RECORDING from UPLOADING from COMPLETING -- these are
/// genuinely different RecordingLifecycleState values and must never be
/// collapsed into one label.
String recordingTopStatusLabel({required RecordingLifecycleState state, required bool isEmergency}) {
  final prefix = isEmergency ? 'EMERGENCY ' : '';
  switch (state) {
    case RecordingLifecycleState.starting:
      return '${prefix}STARTING';
    case RecordingLifecycleState.uploading:
      return '${prefix}FINISHING UPLOAD';
    case RecordingLifecycleState.offline:
      return '${prefix}RECORDING -- OFFLINE';
    case RecordingLifecycleState.backgroundPaused:
      return '${prefix}RECORDING -- PAUSED (BACKGROUND)';
    case RecordingLifecycleState.completing:
      return '${prefix}COMPLETING';
    case RecordingLifecycleState.recording:
    default:
      return '${prefix}RECORDING';
  }
}

String uploadStatusText({required int uploaded, required int pending, required int failed}) {
  final allUploaded = pending == 0 && failed == 0 && uploaded > 0;
  if (allUploaded) return '✓ All chunks uploaded';
  return 'Upload: $uploaded uploaded, $pending pending${failed > 0 ? ', $failed failed' : ''}';
}
