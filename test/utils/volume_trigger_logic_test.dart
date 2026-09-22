import 'package:camera/camera.dart' show CameraLensDirection;
import 'package:flutter_test/flutter_test.dart';
import 'package:police_body_cam/utils/volume_trigger_logic.dart';

void main() {
  group('decideVolumeTriggerAction', () {
    // Matrix items 1-4: idle + double/long UP/DOWN. Kind (double vs long)
    // is deliberately not a parameter of the decision function -- both
    // gesture kinds are dispatched through the exact same call, so testing
    // "double" here also proves "long" produces the identical outcome
    // (there's no separate code path for kind to diverge on).
    test('1+3. idle + UP (double or long) -> start FRONT emergency', () {
      final action = decideVolumeTriggerAction(isRecordingActive: false, isVolumeUp: true);
      expect(action, VolumeTriggerAction.startFront);
      expect(cameraForVolumeTriggerAction(action), CameraLensDirection.front);
    });

    test('2+4. idle + DOWN (double or long) -> start BACK emergency', () {
      final action = decideVolumeTriggerAction(isRecordingActive: false, isVolumeUp: false);
      expect(action, VolumeTriggerAction.startBack);
      expect(cameraForVolumeTriggerAction(action), CameraLensDirection.back);
    });

    // Matrix items 5-8: recording + double/long UP/DOWN -> stop, never a
    // new start, regardless of which key was pressed.
    test('5+7. recording + UP (double or long) -> STOP, never starts a new recording', () {
      final action = decideVolumeTriggerAction(isRecordingActive: true, isVolumeUp: true);
      expect(action, VolumeTriggerAction.stop);
      expect(cameraForVolumeTriggerAction(action), isNull);
    });

    test('6+8. recording + DOWN (double or long) -> STOP, never starts a new recording', () {
      final action = decideVolumeTriggerAction(isRecordingActive: true, isVolumeUp: false);
      expect(action, VolumeTriggerAction.stop);
      expect(cameraForVolumeTriggerAction(action), isNull);
    });

    // Matrix items 9-10 (single quick press -> no action) and 11-12 (held
    // press with OS repeat events -> exactly one action) are enforced
    // natively in MainActivity.kt: a lone press that never reaches the
    // double-press window or the long-press threshold sends NO method-channel
    // call at all, so there is nothing for this Dart-level decision
    // function to receive or act on for those cases -- verified by native
    // code inspection (repeatCount > 0 events are ignored entirely; a
    // single short press updates only the internal timestamp and fires no
    // trigger), not something a Dart unit test can exercise without a
    // native/instrumented test harness.

    // Matrix item 17 (stopping never creates a duplicate RecordingSession):
    // structurally guaranteed here -- when isRecordingActive is true, the
    // function can ONLY return `stop`, never `startFront`/`startBack`, for
    // both key values. Exhaustively checked below.
    test('17. while recording, no key/state combination ever produces a start action', () {
      for (final isUp in [true, false]) {
        final action = decideVolumeTriggerAction(isRecordingActive: true, isVolumeUp: isUp);
        expect(action, VolumeTriggerAction.stop, reason: 'isVolumeUp=$isUp must never start a second recording');
      }
    });

    test('idle: only startFront/startBack are ever produced, never stop', () {
      for (final isUp in [true, false]) {
        final action = decideVolumeTriggerAction(isRecordingActive: false, isVolumeUp: isUp);
        expect(action, isNot(VolumeTriggerAction.stop));
      }
    });
  });
}
