import 'package:flutter_test/flutter_test.dart';
import 'package:police_body_cam/models/recording_models.dart';
import 'package:police_body_cam/utils/remote_command_audio_logic.dart';

/// Exhaustive tests for the pure decision logic home_screen.dart's
/// _handleRemoteCommand actually calls (see remote_command_audio_logic.dart's
/// doc comment) -- covers test-plan items 1-4 (successful/failed remote
/// start and stop). Item 5 (duplicate command -> no duplicate beep) is
/// enforced by the CALLER's own pre-existing isActive guard, already
/// covered by RecordingService's own "start() while active is a no-op" and
/// "isActive" tests in recording_service_test.dart; item 6 (ACK/result
/// behavior unchanged) is a code-inspection/regression-suite fact (the
/// ack()/reportResult() calls in home_screen.dart were not touched by this
/// feature) rather than something this pure-function layer can observe. A
/// full HomeScreen widget test to exercise the actual switch-statement
/// end-to-end is not feasible in this environment -- see
/// test/screens/recording_back_behavior_test.dart's own doc comment.
void main() {
  group('shouldPlayRemoteStartBeep', () {
    test('1. RECORDING (the only genuine-success state) -> true', () {
      expect(shouldPlayRemoteStartBeep(RecordingLifecycleState.recording), isTrue);
    });

    test('2. every other state, including startFailed, -> false', () {
      for (final s in RecordingLifecycleState.values) {
        if (s == RecordingLifecycleState.recording) continue;
        expect(shouldPlayRemoteStartBeep(s), isFalse, reason: 'state $s must never trigger the start beep');
      }
    });
  });

  group('shouldPlayRemoteStopBeep', () {
    test('3. states that mean the camera genuinely stopped capturing -> true', () {
      for (final s in [
        RecordingLifecycleState.uploading,
        RecordingLifecycleState.completing,
        RecordingLifecycleState.completed,
        RecordingLifecycleState.completeFailed,
        RecordingLifecycleState.cancelled,
        RecordingLifecycleState.idle,
        RecordingLifecycleState.starting,
        RecordingLifecycleState.startFailed,
      ]) {
        expect(shouldPlayRemoteStopBeep(s), isTrue, reason: 'state $s means capture is no longer live -- stop genuinely happened');
      }
    });

    test('4. states where the camera is still actively capturing -> false (stop did not genuinely take effect yet)', () {
      for (final s in [
        RecordingLifecycleState.recording,
        RecordingLifecycleState.backgroundPaused,
        RecordingLifecycleState.offline,
      ]) {
        expect(shouldPlayRemoteStopBeep(s), isFalse, reason: 'state $s means the camera is still live');
      }
    });
  });
}
