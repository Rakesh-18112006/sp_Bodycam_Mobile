import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Registered with the plugin via `startService(callback: ...)` rather than
/// called directly from the main isolate. This is REQUIRED, not optional --
/// physical device testing found that calling `setTaskHandler()` directly
/// from the main isolate (the previous approach here) left the plugin's
/// background-isolate/notification-button dispatch never properly wired
/// up: pressing a notification button just re-opened the app (the default
/// bare-notification tap behavior) instead of invoking
/// [_RecordingTaskHandler.onNotificationButtonPressed], and the main
/// isolate then threw
/// `MissingPluginException(...flutter_foreground_task/background)` the
/// next time it touched the service. The official plugin example uses
/// exactly this top-level-callback-plus-`initCommunicationPort()` pattern
/// (see main.dart) for the same reason.
@pragma('vm:entry-point')
void _startForegroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_RecordingTaskHandler());
}

/// Wraps `flutter_foreground_task` to promote the app process to a genuine
/// Android foreground service (with a persistent notification and
/// camera/microphone/location `foregroundServiceType`s -- see
/// AndroidManifest.xml) while a body-cam recording is active, AND to give
/// that notification a real Android notification action (a button) so a
/// constable can start/stop recording without opening the app at all --
/// real physical testing found no such trigger existed before this file's
/// current form: the service previously only ever started once a recording
/// was already underway, with plain text and no buttons, so there was no
/// way to START one from the notification, only to watch it update.
///
/// HONEST SCOPE (do not overstate this): this does NOT move camera control
/// into a separate background isolate. The `camera` plugin's platform
/// channel is tied to the app's Activity/Flutter engine, so
/// RecordingEngine keeps running in the normal main isolate exactly as it
/// does in the foreground -- what this class buys is that Android is far
/// less likely to kill that process for being backgrounded/screen-off,
/// because a foreground service with an active notification is one of the
/// few states Android treats as "the user knows this is still running."
/// It does NOT, and cannot, prevent a full user swipe-away/force-stop, and
/// it does not survive that -- that limitation was already honestly
/// documented in the pre-existing code (home_screen.dart's original
/// comment about a "fully killed app") and remains true here; only the
/// original "any backgrounding at all" failure mode is fixed.
///
/// TRADE-OFF, made explicit rather than silently decided: giving the
/// notification a START RECORDING button while genuinely idle means the
/// foreground service (and its persistent notification) now runs for the
/// whole time a constable is logged in, not only during an active
/// recording as before. That is the only way Android can offer a always-
/// available notification button with nothing already running behind it.
/// [ensureReady] is what starts this idle state; call it once after
/// login. A recording ending calls [returnToReady] (service stays up,
/// notification reverts to Ready) rather than [stop] (which fully tears
/// the service down) -- [stop] is reserved for logout.
///
/// The [TaskHandler] below still does almost nothing on its own (only
/// keeps the notification's elapsed-time text current and forwards button
/// presses) -- it is not where recording happens. Button presses arrive on
/// the plugin's own background isolate (see flutter_foreground_task's
/// docs), so they are relayed to the main isolate via
/// FlutterForegroundTask.sendDataToMain/addTaskDataCallback rather than
/// calling into RecordingService directly from here.
class ForegroundRecordingService {
  static bool _initialized = false;

  /// Set by home_screen.dart after login. Invoked (on the main isolate)
  /// with 'start_recording' or 'stop_recording' when the corresponding
  /// notification button is pressed -- the caller reuses its EXISTING
  /// _startRecording/_stopRecording methods, the same ones the in-app
  /// button calls, so there is exactly one recording-start/stop code path.
  static void Function(String buttonId)? onButtonPressed;

  static const _readyButtons = [NotificationButton(id: 'start_recording', text: 'START RECORDING')];
  static const _recordingButtons = [NotificationButton(id: 'stop_recording', text: 'STOP RECORDING')];
  static const _serviceTypes = [
    ForegroundServiceTypes.camera,
    ForegroundServiceTypes.microphone,
    ForegroundServiceTypes.location,
  ];

  static void _ensureInit() {
    if (_initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'bodycam_recording_channel',
        channelName: 'Body Camera Recording',
        channelDescription: 'Shown while logged in, so recording can be started/stopped without opening the app.',
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
        onlyAlertOnce: true,
        visibility: NotificationVisibility.VISIBILITY_PUBLIC, // never hide that recording is happening -- see home_screen's mandatory-transparency requirement
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(15000),
        autoRunOnBoot: false,
        allowWakeLock: true, // recording must not be paused by CPU sleep while the screen is off
        allowWifiLock: true, // keep uploads flowing while the screen is off
      ),
    );
    FlutterForegroundTask.addTaskDataCallback(_handleTaskData);
    _initialized = true;
  }

  static void _handleTaskData(Object data) {
    if (data is String) onButtonPressed?.call(data);
  }

  /// Starts the foreground service in its idle "Ready" state, with a START
  /// RECORDING button -- call once after login. Safe to call again (e.g.
  /// app resume) while already running; just re-asserts the Ready state.
  static Future<void> ensureReady() async {
    _ensureInit();
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Body Camera',
        notificationText: 'Ready',
        notificationButtons: _readyButtons,
      );
      return;
    }
    await FlutterForegroundTask.startService(
      serviceTypes: _serviceTypes,
      notificationTitle: 'Body Camera',
      notificationText: 'Ready',
      notificationButtons: _readyButtons,
      callback: _startForegroundTaskCallback,
    );
  }

  /// Switches the (already-running, via [ensureReady]) notification into
  /// its Recording state with a STOP RECORDING button. Also handles the
  /// case where the service somehow isn't running yet (defensive only --
  /// normal login flow always calls ensureReady() first).
  static Future<bool> start({required String notificationText}) async {
    _ensureInit();
    if (await FlutterForegroundTask.isRunningService) {
      final result = await FlutterForegroundTask.updateService(
        notificationTitle: '● Body camera recording',
        notificationText: notificationText,
        notificationButtons: _recordingButtons,
      );
      return result is ServiceRequestSuccess;
    }
    final result = await FlutterForegroundTask.startService(
      serviceTypes: _serviceTypes,
      notificationTitle: '● Body camera recording',
      notificationText: notificationText,
      notificationButtons: _recordingButtons,
      callback: _startForegroundTaskCallback,
    );
    return result is ServiceRequestSuccess;
  }

  static Future<void> updateText(String notificationText) async {
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.updateService(notificationText: notificationText);
  }

  /// Called when a recording ends (completed/cancelled/failed) -- returns
  /// the notification to its idle Ready state rather than tearing the
  /// service down, so the START RECORDING button is available again
  /// without reopening the app. See [stop] for the logout path.
  static Future<void> returnToReady() async {
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: 'Body Camera',
      notificationText: 'Ready',
      notificationButtons: _readyButtons,
    );
  }

  /// Fully stops the foreground service and its notification -- only call
  /// on logout. Ending an individual recording should call [returnToReady]
  /// instead, so the notification (and its START button) survives.
  static Future<void> stop() async {
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.stopService();
  }
}

class _RecordingTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Deliberately empty: RecordingService (running in the main isolate)
    // is what drives actual recording/upload progress and calls
    // ForegroundRecordingService.updateText() directly with real state.
    // This periodic tick exists only because flutter_foreground_task
    // requires SOME eventAction for the service to stay alive; it is not
    // used to run business logic.
  }

  @override
  void onNotificationButtonPressed(String id) {
    // Runs on the plugin's own background isolate, which does not share
    // memory with the main isolate where RecordingService/CommandListener
    // actually live -- relay across via the plugin's own data channel
    // rather than trying to reach those objects directly from here.
    FlutterForegroundTask.sendDataToMain(id);
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
