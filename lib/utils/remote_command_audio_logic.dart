import '../models/recording_models.dart';

/// Pure decision logic for FEATURE 1 (remote command audio feedback) --
/// factored out of home_screen.dart's _handleRemoteCommand exactly so it can
/// be unit-tested directly (a full HomeScreen widget test is not feasible in
/// this environment -- see test/screens/recording_back_behavior_test.dart's
/// own doc comment for why). home_screen.dart calls these same functions;
/// they are not a parallel copy of its logic.
///
/// Both take the RecordingService.state reached immediately AFTER the
/// corresponding start()/stop() call already completed -- never merely
/// "the WebSocket command was received" (see RecordingService.start()'s own
/// doc comment: a failure sets state to startFailed, it never throws, so
/// "the await didn't throw" is NOT a valid success signal on its own).

/// True only when a remote START command just genuinely, newly put the
/// camera into RECORDING. A duplicate start (already active before the
/// attempt) is filtered out by the CALLER before this is ever invoked --
/// see home_screen.dart's `if (_recording == null || !_recording!.isActive)`
/// guard, which decides whether to attempt a start at all in the first
/// place. False for startFailed (permission denied, no camera, backend
/// rejection, etc.) and for every other state.
bool shouldPlayRemoteStartBeep(RecordingLifecycleState stateAfterAttempt) {
  return stateAfterAttempt == RecordingLifecycleState.recording;
}

/// True only when a remote STOP command just genuinely moved the camera OUT
/// of active capture. RECORDING/backgroundPaused/offline all mean the
/// camera is still live (see RecordingService.isActive's own doc comment on
/// why offline counts as active: "the camera is never blocked on network
/// state") -- stop() never throws and never leaves an explicit boolean
/// success flag, so leaving one of those three states is the real signal
/// that capture actually stopped, whether it landed on uploading,
/// completing, or (if everything happened to finish synchronously) already
/// completed.
bool shouldPlayRemoteStopBeep(RecordingLifecycleState stateAfterAttempt) {
  return stateAfterAttempt != RecordingLifecycleState.recording &&
      stateAfterAttempt != RecordingLifecycleState.backgroundPaused &&
      stateAfterAttempt != RecordingLifecycleState.offline;
}
