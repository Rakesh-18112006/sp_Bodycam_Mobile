import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart' show CameraLensDirection, CameraPreview;
import 'package:livekit_client/livekit_client.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../main.dart';
import '../models/command_models.dart';
import '../models/device_models.dart';
import '../models/recording_models.dart';
import '../services/api_client.dart';
import '../services/audio_feedback_service.dart';
import '../services/auth_service.dart';
import '../services/battery_service.dart';
import '../services/command_listener_service.dart';
import '../services/device_service.dart';
import '../services/emergency_trigger_service.dart';
import '../services/foreground_service.dart';
import '../services/live_stream_service.dart';
import '../services/location_service.dart';
import '../services/recording_service.dart';
import '../utils/remote_command_audio_logic.dart';
import '../utils/volume_trigger_logic.dart';
import '../utils/watermark_display.dart';
import '../theme/app_theme.dart';
import '../widgets/status_chip.dart';
import 'login_screen.dart';
import 'my_recordings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // --- Live streaming (PRESERVED, unchanged behavior from the original
  // implementation -- live streaming and recording are two separate
  // features; a live view is never presented as recorded evidence). ---
  final _liveStream = LiveStreamService();
  bool _live = false;
  VideoTrack? _localVideoTrack;
  CameraPosition _selectedCameraPosition = CameraPosition.back;

  // --- Emergency/normal recording camera selection -- separate from the
  // live-stream selector above (different package, different camera
  // pipeline: RecordingEngine uses package:camera's CameraController, not
  // LiveKit's WebRTC camera track). Defaults to back, the existing,
  // unchanged behavior; only applies when the constable explicitly picks
  // front here. ---
  CameraLensDirection _emergencyCameraLensDirection = CameraLensDirection.back;

  // --- Core device/session state ---
  DeviceResponse? _device;
  String? _deviceIdentifier;
  bool _initializing = true;
  bool _busy = false;
  String? _error;

  // --- Body-camera subsystems ---
  // Constructed in initState() (not here) because it needs to pass
  // _handleChargingChanged, an instance method -- not legal in a field
  // initializer, which runs before `this` is fully constructed.
  late final BatteryService _battery;
  final AudioFeedbackService _audioFeedback = AudioFeedbackService();
  LocationService? _location;
  LocationAvailability _locationAvailability = LocationAvailability.unknown;
  HeartbeatScheduler? _heartbeat;
  CommandListenerService? _commandListener;
  CommandChannelStatus _commandStatus = CommandChannelStatus.disconnected;
  RecordingService? _recording;
  RecordingLifecycleState _recordingState = RecordingLifecycleState.idle;
  int _chunksUploaded = 0;
  int _chunksPending = 0;
  int _chunksFailed = 0;
  List<int> _missingChunks = const [];
  EmergencyTriggerService? _emergencyTrigger;
  Timer? _uiTicker;

  bool _handlingForcedLogout = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _battery = BatteryService(onChargingChanged: _handleChargingChanged);
    // Centralized 401 handling (implementation brief §20) -- installed
    // once, here, rather than duplicated in every API call site.
    ApiClient.onUnauthorized = () => _handleForcedLogout();
    _init();
  }

  /// Fires only on a genuine charging-state transition (see
  /// BatteryService._updateCharging's doc comment) -- never merely because
  /// a battery percentage/heartbeat tick happened while already
  /// charging/not-charging.
  void _handleChargingChanged(bool isCharging) {
    _audioFeedback.play(isCharging ? AudioFeedbackSound.chargingConnected : AudioFeedbackSound.chargingDisconnected);
  }

  /// Flutter's own official app-lifecycle API (no unsupported/invented
  /// APIs, no Accessibility Service, no device-owner, no root). This is
  /// the actual fix for a real, physically-reproduced crash: the
  /// `camera_android_camerax` plugin binds its CameraX pipeline directly
  /// to THIS Activity's own Lifecycle and automatically, forcibly
  /// unbinds/tears it down the instant Activity.onStop() fires (confirmed
  /// by reading the plugin's own source --
  /// ProxyLifecycleProvider.java/ProxyApiRegistrar.java -- not
  /// assumed) -- entirely outside this app's control. If a new recording
  /// segment is still being configured when that automatic unbind hits,
  /// CameraX's own Recorder throws a FATAL, process-killing
  /// AssertionError ("Unexpectedly invoke onConfigured() in a STOPPING
  /// state"). [AppLifecycleState.inactive] fires EARLIEST (roughly
  /// Activity.onPause(), before onStop()), giving RecordingEngine the
  /// chance to proactively, gracefully finalize the current segment and
  /// tear the camera down itself -- deterministically, before the
  /// plugin's automatic unbind can ever race against anything still in
  /// flight. [AppLifecycleState.resumed] starts a fresh segment
  /// continuing the SAME recording session. See
  /// RecordingEngine.pauseForBackground/resumeFromBackground's own doc
  /// comments for the full mechanism.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
        _recording?.pauseForBackground();
        break;
      case AppLifecycleState.resumed:
        _recording?.resumeFromBackground();
        break;
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        break;
    }
  }

  Future<void> _init() async {
    try {
      _deviceIdentifier = await DeviceService.getOrCreateDeviceIdentifier();
      final device = await DeviceService.register(deviceIdentifier: _deviceIdentifier!);
      _device = device;

      _battery.start();
      await FlutterForegroundTask.requestNotificationPermission();
      // Starts the foreground service in its idle "Ready" state so the
      // notification's START RECORDING button is available immediately
      // after login, without waiting for a recording to begin -- see
      // ForegroundRecordingService's doc comment for the trade-off this
      // implies (the service now runs for the whole logged-in session).
      await ForegroundRecordingService.ensureReady();
      ForegroundRecordingService.onButtonPressed = _handleNotificationButton;

      _location = LocationService(
        onAvailabilityChanged: (a) {
          if (mounted) setState(() => _locationAvailability = a);
        },
        onError: (e) {
          if (mounted) setState(() => _error = 'Location: $e');
        },
      );
      await _location!.start();

      _heartbeat = HeartbeatScheduler(
        deviceIdentifier: _deviceIdentifier!,
        batteryPercentProvider: () => _battery.currentPercent,
        isChargingProvider: () => _battery.isCharging,
        onSuccess: (d) {
          if (mounted) setState(() => _device = d);
        },
        onError: (e) {
          if (mounted) setState(() => _error = 'Heartbeat: $e');
        },
      )..start();

      _recording = RecordingService(
        deviceIdentifier: _deviceIdentifier!,
        deviceId: device.id,
        // Reuses the SAME LocationService instance/cache started above --
        // never a second GPS subscription. See
        // RecordingService.locationProvider's doc comment.
        locationProvider: () => _location?.lastFix,
        onStateChanged: _handleRecordingStateChanged,
        onProgress: ({required uploaded, required pending, required failed}) {
          if (!mounted) return;
          setState(() {
            _chunksUploaded = uploaded;
            _chunksPending = pending;
            _chunksFailed = failed;
          });
        },
        onError: (e) {
          if (mounted) setState(() => _error = 'Recording: $e');
        },
      );

      _emergencyTrigger = EmergencyTriggerService(onTrigger: _handleEmergencyTrigger);

      _commandListener = CommandListenerService(
        deviceId: device.id,
        onCommand: _handleRemoteCommand,
        onStatusChanged: (s) {
          if (mounted) setState(() => _commandStatus = s);
        },
        onUnknownCommand: (raw) {
          if (mounted) setState(() => _error = 'Received unrecognized command_type "$raw" -- ignored');
        },
      );
      await _commandListener!.start();

      _uiTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _recording != null && _recording!.isActive) setState(() {});
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  // ---------------------------------------------------------------------
  // Remote commands -- ack is now inside the try/catch (the original
  // audit's critical finding: an unguarded ackCommand() call outside the
  // try block could silently drop a command with zero feedback). A failed
  // ack means the command was never genuinely received/processed, so no
  // action is attempted and no result is reported -- it stays
  // pending/sent server-side and will be re-delivered by the missed-command
  // poll on the next reconnect (see CommandListenerService._recoverMissedCommands).
  // ---------------------------------------------------------------------

  Future<void> _handleRemoteCommand(String commandId, RemoteCommandType type) async {
    // Diagnostic instrumentation (temporary, per investigation into
    // remote-start-while-backgrounded/locked): a lifecycleState log line
    // right at command entry distinguishes "the command genuinely never
    // arrived/was never dispatched while locked" from "it arrived and was
    // acted on, but the underlying camera call stalled" -- see
    // recording_engine.dart's matching [CAMERA]/[SEGMENT] tags for the
    // rest of this trace.
    debugPrint('[REMOTE_START] command received: id=$commandId type=${type.name} appLifecycleState=${WidgetsBinding.instance.lifecycleState}');
    try {
      await _commandListener!.ackCommand(commandId);
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed to acknowledge command $commandId: $e');
      return;
    }

    try {
      switch (type) {
        case RemoteCommandType.startRecording:
          if (_recording == null || !_recording!.isActive) {
            debugPrint('[RECORDING_SERVICE] starting recording, trigger=remote');
            await _startRecording(TriggerType.remote);
            debugPrint('[RECORDING_SERVICE] start attempt finished, state=${_recording?.state}');
            // Only the genuine, newly-successful transition into RECORDING
            // gets a beep -- not a call that reached START_FAILED (see
            // RecordingService.start()'s own doc comment: a failure sets
            // state to startFailed, it never throws), and not this branch
            // at all when the command was a duplicate (the isActive check
            // above already skipped calling _startRecording entirely).
            if (_recording != null && shouldPlayRemoteStartBeep(_recording!.state)) {
              await _audioFeedback.play(AudioFeedbackSound.remoteStart);
            }
          }
          break;
        case RemoteCommandType.stopRecording:
          if (_recording != null && _recording!.isActive) {
            await _recording!.stop();
            // stop() never throws and never leaves a definitive "it
            // worked" flag -- the real signal that the camera genuinely
            // stopped capturing is that state has left every
            // actively-recording state (recording/backgroundPaused/
            // offline all mean the camera is still live -- see
            // RecordingService.isActive's own doc comment) and moved on
            // to uploading/completing/completed.
            if (shouldPlayRemoteStopBeep(_recording!.state)) {
              await _audioFeedback.play(AudioFeedbackSound.remoteStop);
            }
          }
          break;
        case RemoteCommandType.startLiveStream:
          if (!_liveStream.isLive) {
            await _goLive(triggeringCommandId: commandId);
          }
          break;
        case RemoteCommandType.stopLiveStream:
          if (_liveStream.isLive) {
            await _stopLive();
          }
          break;
      }
      // "SENT" != "EXECUTED" (implementation brief §14/§24): this line is
      // only reached once the corresponding action above has genuinely
      // been attempted and did not throw.
      await _commandListener!.reportResult(commandId, success: true);
    } catch (e) {
      try {
        await _commandListener!.reportResult(commandId, success: false, failureReason: e.toString());
      } catch (_) {
        // Reporting the failure itself failed (e.g. offline) -- the
        // command stays stuck at "acknowledged" server-side until this
        // device can reach the backend again. Nothing more can be done
        // locally; surfaced to the constable below regardless.
      }
      if (mounted) setState(() => _error = 'Command $commandId failed: $e');
    }
  }

  // ---------------------------------------------------------------------
  // Recording
  // ---------------------------------------------------------------------

  /// State-aware volume toggle (decision logic in
  /// utils/volume_trigger_logic.dart, unit-tested there): while idle,
  /// either recognized gesture (double-press or long-press) on VOLUME_UP
  /// starts a FRONT-camera emergency recording and on VOLUME_DOWN starts a
  /// BACK-camera one; while a recording is already active, ANY recognized
  /// gesture on EITHER key stops the existing recording -- never starts a
  /// second one, never switches camera mid-recording, never creates a
  /// duplicate RecordingSession. `kind` (double vs long) never changes the
  /// resulting action, only which key/current state does.
  void _handleEmergencyTrigger(VolumeButtonKey key, VolumeButtonKind kind) {
    if (_recording == null) return;
    final action = decideVolumeTriggerAction(
      isRecordingActive: _recording!.isActive,
      isVolumeUp: key == VolumeButtonKey.up,
    );
    if (action == VolumeTriggerAction.stop) {
      _stopRecording();
      return;
    }
    setState(() => _emergencyCameraLensDirection = cameraForVolumeTriggerAction(action)!);
    _startRecording(TriggerType.emergencyButton);
  }

  Future<void> _startRecording(TriggerType trigger) async {
    final rec = _recording;
    if (rec == null || rec.isActive) return;
    setState(() => _error = null);
    await ForegroundRecordingService.start(notificationText: 'Starting recording...');
    await rec.start(triggerType: trigger, cameraLensDirection: _emergencyCameraLensDirection);
    if (rec.state == RecordingLifecycleState.startFailed) {
      await ForegroundRecordingService.stop();
    }
  }

  Future<void> _stopRecording() async {
    await _recording?.stop();
  }

  /// Fired (on the main isolate, via ForegroundRecordingService's
  /// cross-isolate relay) when the notification's START/STOP RECORDING
  /// button is pressed -- reuses the exact same start/stop paths the
  /// in-app button and emergency trigger already use, so there is one
  /// recording-control code path, not a second implementation.
  void _handleNotificationButton(String buttonId) {
    switch (buttonId) {
      case 'start_recording':
        if (_recording == null || !_recording!.isActive) {
          _startRecording(TriggerType.manual);
        }
        break;
      case 'stop_recording':
        if (_recording != null && _recording!.isActive) {
          _stopRecording();
        }
        break;
    }
  }

  void _handleRecordingStateChanged(RecordingLifecycleState s) {
    if (!mounted) return;
    setState(() => _recordingState = s);
    if (s == RecordingLifecycleState.completed) {
      setState(() => _missingChunks = _recording?.lastMissingChunkNumbers ?? const []);
    }
    if (s == RecordingLifecycleState.completed || s == RecordingLifecycleState.cancelled || s == RecordingLifecycleState.startFailed) {
      // Returns the notification to "Ready" (START RECORDING button)
      // rather than tearing the whole service down -- see
      // ForegroundRecordingService's doc comment. Full stop() only
      // happens on logout.
      ForegroundRecordingService.returnToReady();
    } else {
      final label = switch (s) {
        RecordingLifecycleState.recording => 'Recording -- $_chunksUploaded uploaded, $_chunksPending pending',
        RecordingLifecycleState.backgroundPaused => 'Recording paused (app in background) -- will resume automatically',
        RecordingLifecycleState.uploading => 'Finishing upload -- $_chunksPending pending',
        RecordingLifecycleState.offline => 'Recording -- offline, chunks queued locally',
        RecordingLifecycleState.completing => 'Completing recording...',
        _ => 'Body camera active',
      };
      ForegroundRecordingService.updateText(label);
    }
  }

  // ---------------------------------------------------------------------
  // Live streaming (PRESERVED from the original implementation)
  // ---------------------------------------------------------------------

  Future<void> _goLive({String? triggeringCommandId}) async {
    if (_device == null || _liveStream.isLive) return;
    setState(() => _busy = true);
    try {
      final room = await _liveStream.start(
        deviceId: _device!.id,
        triggeringCommandId: triggeringCommandId,
        cameraPosition: _selectedCameraPosition,
      );
      final videoTrack = room.localParticipant?.videoTrackPublications.firstOrNull?.track as VideoTrack?;
      setState(() {
        _live = true;
        _localVideoTrack = videoTrack;
      });
    } catch (e) {
      setState(() => _error = e.toString());
      rethrow;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Switches the published camera in place (see LiveStreamService.switchCamera
  /// -- restarts just the capture track, never leaves the LiveKit room).
  /// Only meaningful while actually live; the selector shown before "Go
  /// Live" just sets [_selectedCameraPosition] directly via setState.
  Future<void> _switchCamera() async {
    if (!_live || _busy) return;
    setState(() => _busy = true);
    try {
      await _liveStream.switchCamera();
      // setCameraPosition restarts the SAME LocalVideoTrack instance in
      // place (see the SDK's LocalVideoTrackExt) -- _localVideoTrack's
      // reference is still valid; this setState just repaints the
      // Front/Back indicator.
      setState(() => _selectedCameraPosition = _liveStream.cameraPosition);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopLive() async {
    setState(() => _busy = true);
    try {
      await _liveStream.stop();
      setState(() {
        _live = false;
        _localVideoTrack = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------------
  // Auth / forced logout
  // ---------------------------------------------------------------------

  Future<void> _handleForcedLogout() async {
    if (_handlingForcedLogout) return;
    _handlingForcedLogout = true;
    _heartbeat?.stop();
    _battery.stop();
    _location?.stop();
    _commandListener?.stop();
    if (_recording != null && _recording!.isActive) {
      // Finalizes locally -- the backend calls this triggers will also
      // fail (the token is already gone), but the local sqflite queue
      // survives untouched and is picked back up automatically by
      // RecordingService.recoverOnStartup() the next time this constable
      // logs in. Evidence already captured is never discarded here.
      await _recording!.stop();
    }
    if (_liveStream.isLive) {
      try {
        await _liveStream.stop();
      } catch (_) {}
    }
    await ForegroundRecordingService.stop();
    await forceLogoutAndReturnToLogin();
  }

  Future<void> _logout() async {
    _heartbeat?.stop();
    _battery.stop();
    _location?.stop();
    _commandListener?.stop();
    if (_liveStream.isLive) await _liveStream.stop();
    await ForegroundRecordingService.stop();
    await AuthService.logout();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ApiClient.onUnauthorized = null;
    ForegroundRecordingService.onButtonPressed = null;
    _uiTicker?.cancel();
    _heartbeat?.stop();
    _battery.stop();
    _location?.stop();
    _commandListener?.stop();
    _emergencyTrigger?.dispose();
    _recording?.dispose();
    _audioFeedback.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------

  String _deviceStatusLabel() => _device?.status ?? 'unknown';

  String _recordingDuration() {
    final started = _recording?.recordingStartedAt;
    if (started == null || !(_recording?.isActive ?? false)) return '';
    final d = DateTime.now().difference(started);
    final mm = d.inMinutes.toString().padLeft(2, '0');
    final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  /// The prominent, body-camera-style "Go-Live" recording view: a REAL
  /// live camera preview (the exact same CameraController RecordingEngine
  /// itself is recording from -- see RecordingService.cameraController's
  /// doc comment; never a fake/static preview) with a clear recording
  /// indicator, timer, GPS/time/camera, and upload status overlaid on top.
  /// This is purely an on-screen UI overlay for the constable -- it does
  /// NOT put any text into the recorded video file itself; that happens
  /// server-side once each chunk uploads (see chunk_uploader.dart's doc
  /// comment and routers/recordings.py::_burn_watermark_best_effort), so
  /// what's shown here and what ends up burned into the video are computed
  /// independently but represent the same real, non-fabricated data.
  Widget _recordingGoLiveCard() {
    final controller = _recording?.cameraController;
    final previewReady = controller != null && controller.value.isInitialized;
    final isEmergency = _recording?.activeTriggerType == TriggerType.emergencyButton;
    final statusLabel = recordingTopStatusLabel(state: _recordingState, isEmergency: isEmergency);
    final cameraLabel = cameraWatermarkLabel(_emergencyCameraLensDirection);
    final allUploaded = _chunksPending == 0 && _chunksFailed == 0 && _chunksUploaded > 0;
    final uploadText = uploadStatusText(uploaded: _chunksUploaded, pending: _chunksPending, failed: _chunksFailed);

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: isEmergency ? AppColors.emergency : AppColors.border, width: isEmergency ? 2 : 1),
        ),
        child: Container(
          color: Colors.black,
          child: AspectRatio(
            aspectRatio: previewReady ? controller.value.aspectRatio : 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (previewReady)
                  CameraPreview(controller)
                else
                  const Center(child: CircularProgressIndicator(color: Colors.white)),
                // Top: recording indicator + status + timer -- kept out of
                // the vertical center so it never blocks the scene.
                Positioned(
                  top: 10,
                  left: 10,
                  right: 10,
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: isEmergency ? AppColors.emergency : Colors.black54,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const RecordingPulseDot(color: Colors.white),
                            const SizedBox(width: 6),
                            Icon(isEmergency ? Icons.emergency : Icons.fiber_manual_record, color: Colors.white, size: 12),
                            const SizedBox(width: 5),
                            Text(
                              statusLabel,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(999)),
                        child: Text(
                          _recordingDuration(),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
                // Bottom: GPS / time / camera / upload status.
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(AppRadii.sm)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(gpsWatermarkText(fix: _location?.lastFix, availability: _locationAvailability), style: const TextStyle(color: Colors.white, fontSize: 12)),
                        Text('TIME: ${formatWatermarkTimestamp(DateTime.now())}', style: const TextStyle(color: Colors.white, fontSize: 12)),
                        Text('CAMERA: $cameraLabel', style: const TextStyle(color: Colors.white, fontSize: 12)),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              allUploaded ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
                              size: 14,
                              color: allUploaded ? const Color(0xFF6FCF97) : Colors.white,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              uploadText,
                              style: TextStyle(
                                color: allUploaded ? const Color(0xFF6FCF97) : Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final recordingActive = _recording?.isActive ?? false;

    // The Android BACK button must never be allowed to finish this
    // Activity while a recording (including a backgroundPaused one) is
    // active. Root cause this prevents (confirmed via a real physical
    // crash, NOT the CameraX Recorder.onConfigured AssertionError -- a
    // separate bug): destroying the Activity/FlutterEngine while the
    // camera plugin's live-preview texture (Flutter's own
    // ImageReaderSurfaceProducer) still has a frame callback in flight
    // throws `RuntimeException: Cannot execute operation because
    // FlutterJNI is not attached to native` and crashes the whole
    // process -- because the camera's ImageReader can still deliver a
    // queued frame after FlutterJNI has already detached from native,
    // with no way for this app to synchronously guarantee the texture is
    // torn down before Android finishes destroying the Activity. The fix
    // is to never let that race start: while idle, BACK behaves exactly
    // as before (this is the app's root screen, so BACK exits/finishes
    // the Activity normally -- unchanged). While a recording is active,
    // BACK is a no-op that keeps the recording screen open; Home
    // (backgroundPaused, see RecordingEngine) remains the only supported
    // way to leave the app mid-recording.
    return PopScope(
      canPop: !recordingActive,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Stop the recording before leaving this screen')),
          );
        }
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text('Body Camera'),
        actions: [
          IconButton(
            icon: const Icon(Icons.video_library_outlined),
            tooltip: 'My Recordings',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MyRecordingsScreen())),
          ),
          IconButton(icon: const Icon(Icons.logout_outlined), tooltip: 'Sign out', onPressed: _logout),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(color: AppColors.dangerBg, borderRadius: BorderRadius.circular(AppRadii.sm)),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline, color: AppColors.danger, size: 18),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(child: Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 13))),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
              ],
              const SectionHeader(title: 'Device status'),
              _statusCard(recordingActive),
              const SizedBox(height: AppSpacing.xl),
              const SectionHeader(title: 'Recording'),
              if (recordingActive) _recordingGoLiveCard(),
              if (!recordingActive && _recordingState == RecordingLifecycleState.completed)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                  child: StatusChip.success(label: 'RECORDING COMPLETED'),
                ),
              if (_missingChunks.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                  child: Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(color: AppColors.warningBg, borderRadius: BorderRadius.circular(AppRadii.sm)),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_outlined, color: AppColors.warning, size: 18),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            'Last completed recording is missing chunk(s): ${_missingChunks.join(', ')}',
                            style: const TextStyle(color: AppColors.warning, fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (!recordingActive) ...[
                const Text('Recording camera', style: AppTypography.body),
                const SizedBox(height: AppSpacing.sm),
                SegmentedButton<CameraLensDirection>(
                  segments: const [
                    ButtonSegment(value: CameraLensDirection.back, label: Text('Back'), icon: Icon(Icons.camera_rear_outlined)),
                    ButtonSegment(value: CameraLensDirection.front, label: Text('Front'), icon: Icon(Icons.camera_front_outlined)),
                  ],
                  selected: {_emergencyCameraLensDirection},
                  onSelectionChanged: _busy ? null : (s) => setState(() => _emergencyCameraLensDirection = s.first),
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              ElevatedButton.icon(
                onPressed: _busy ? null : (recordingActive ? _stopRecording : () => _startRecording(TriggerType.manual)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: recordingActive ? AppColors.danger : AppColors.primary,
                  minimumSize: const Size.fromHeight(54),
                ),
                icon: Icon(recordingActive ? Icons.stop_circle_outlined : Icons.fiber_manual_record, size: 22),
                label: Text(
                  recordingActive ? 'STOP RECORDING' : 'START RECORDING',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 0.3),
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              const Divider(),
              const SizedBox(height: AppSpacing.lg),
              const SectionHeader(title: 'Live stream (separate from recording)'),
              if (_live)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(color: AppColors.secondary, borderRadius: BorderRadius.circular(AppRadii.sm)),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.sensors, color: Colors.white, size: 16),
                      SizedBox(width: 8),
                      Text(
                        'LIVE -- being viewed by Control Room',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              if (_live && _localVideoTrack != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  child: SizedBox(height: 200, child: VideoTrackRenderer(_localVideoTrack!)),
                ),
              const SizedBox(height: AppSpacing.sm),
              if (!_live)
                // Picked before Go Live -- LiveStreamService.start() defaults
                // to the back camera (see its doc comment), but the
                // constable can choose front instead here rather than the
                // choice being hardcoded either way.
                SegmentedButton<CameraPosition>(
                  segments: const [
                    ButtonSegment(value: CameraPosition.back, label: Text('Back'), icon: Icon(Icons.camera_rear_outlined)),
                    ButtonSegment(value: CameraPosition.front, label: Text('Front'), icon: Icon(Icons.camera_front_outlined)),
                  ],
                  selected: {_selectedCameraPosition},
                  onSelectionChanged: _busy ? null : (s) => setState(() => _selectedCameraPosition = s.first),
                )
              else
                OutlinedButton.icon(
                  onPressed: _busy ? null : _switchCamera,
                  icon: const Icon(Icons.cameraswitch_outlined),
                  label: Text('Switch to ${_selectedCameraPosition == CameraPosition.back ? 'Front' : 'Back'} camera'),
                ),
              const SizedBox(height: AppSpacing.sm),
              ElevatedButton.icon(
                onPressed: _busy ? null : (_live ? _stopLive : _goLive),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _live ? AppColors.textSecondary : AppColors.secondary,
                  minimumSize: const Size.fromHeight(48),
                ),
                icon: _busy
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Icon(_live ? Icons.stop_outlined : Icons.sensors_outlined, size: 20),
                label: Text(_live ? 'Stop Live Stream' : 'Go Live'),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _statusCard(bool recordingActive) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _statusRow(Icons.smartphone_outlined, 'Device', _deviceStatusLabel(), _deviceStatusColor()),
            const Divider(height: AppSpacing.lg),
            _statusRow(
              Icons.battery_std_outlined,
              'Battery',
              _battery.currentPercent != null ? '${_battery.currentPercent}%${_battery.isCharging == true ? ' (charging)' : ''}' : 'Unknown',
              AppColors.textSecondary,
            ),
            const Divider(height: AppSpacing.lg),
            _statusRow(Icons.gps_fixed_outlined, 'GPS', _locationLabel(), _locationColor()),
            const Divider(height: AppSpacing.lg),
            _statusRow(Icons.wifi_tethering_outlined, 'Command channel', _commandStatus.name, _commandStatusColor()),
          ],
        ),
      ),
    );
  }

  Widget _statusRow(IconData icon, String label, String value, Color statusColor) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.textSecondary),
        const SizedBox(width: AppSpacing.sm),
        Text(label, style: AppTypography.body),
        const Spacer(),
        StatusDot(color: statusColor),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: AppTypography.bodySecondary.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Color _deviceStatusColor() {
    switch (_device?.status) {
      case 'online':
      case 'recording':
        return AppColors.success;
      case 'stale':
        return AppColors.warning;
      default:
        return AppColors.danger;
    }
  }

  String _locationLabel() {
    switch (_locationAvailability) {
      case LocationAvailability.available:
        return 'Available';
      case LocationAvailability.permissionRequired:
        return 'Permission required';
      case LocationAvailability.permissionDeniedForever:
        return 'Permission permanently denied -- enable in system settings';
      case LocationAvailability.serviceDisabled:
        return 'Location services disabled';
      case LocationAvailability.unavailable:
        return 'Unavailable';
      case LocationAvailability.unknown:
        return 'Checking...';
    }
  }

  Color _locationColor() => _locationAvailability == LocationAvailability.available ? AppColors.success : AppColors.warning;

  Color _commandStatusColor() {
    switch (_commandStatus) {
      case CommandChannelStatus.connected:
        return AppColors.success;
      case CommandChannelStatus.connecting:
        return AppColors.warning;
      case CommandChannelStatus.disconnected:
        return AppColors.danger;
    }
  }
}
