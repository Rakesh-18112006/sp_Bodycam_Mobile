import 'package:camera/camera.dart' show CameraLensDirection;

/// What a recognized volume-button gesture (double-press or long-press,
/// either key) should do, given only the CURRENT recording state -- pure
/// decision logic with no side effects, so the full state-aware toggle is
/// unit-testable without a running camera/recording engine:
///   - not recording: VOLUME_UP -> [startFront], VOLUME_DOWN -> [startBack]
///   - recording: any recognized gesture on EITHER key -> [stop]
/// Gesture kind (double vs long) never changes the outcome -- only key and
/// current state do -- so it isn't a parameter here.
/// See home_screen.dart::_handleEmergencyTrigger for where this is applied.
enum VolumeTriggerAction { startFront, startBack, stop }

VolumeTriggerAction decideVolumeTriggerAction({
  required bool isRecordingActive,
  required bool isVolumeUp,
}) {
  if (isRecordingActive) return VolumeTriggerAction.stop;
  return isVolumeUp ? VolumeTriggerAction.startFront : VolumeTriggerAction.startBack;
}

/// The camera a [VolumeTriggerAction] should record with -- null for
/// [VolumeTriggerAction.stop], which never touches camera selection.
CameraLensDirection? cameraForVolumeTriggerAction(VolumeTriggerAction action) {
  switch (action) {
    case VolumeTriggerAction.startFront:
      return CameraLensDirection.front;
    case VolumeTriggerAction.startBack:
      return CameraLensDirection.back;
    case VolumeTriggerAction.stop:
      return null;
  }
}
