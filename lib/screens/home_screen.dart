import 'dart:async';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../main.dart';
import '../models/command_models.dart';
import '../models/device_models.dart';
import '../models/recording_models.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/battery_service.dart';
import '../services/command_listener_service.dart';
import '../services/device_service.dart';
import '../services/emergency_trigger_service.dart';
import '../services/foreground_service.dart';
import '../services/live_stream_service.dart';
import '../services/location_service.dart';
import '../services/recording_service.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // --- Live streaming (PRESERVED, unchanged behavior from the original
  // implementation -- live streaming and recording are two separate
  // features; a live view is never presented as recorded evidence). ---
  final _liveStream = LiveStreamService();
  bool _live = false;
  VideoTrack? _localVideoTrack;
  CameraPosition _selectedCameraPosition = CameraPosition.back;

  // --- Core device/session state ---
  DeviceResponse? _device;
  String? _deviceIdentifier;
  bool _initializing = true;
  bool _busy = false;
  String? _error;

  // --- Body-camera subsystems ---
  final BatteryService _battery = BatteryService();
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
    // Centralized 401 handling (implementation brief §20) -- installed
    // once, here, rather than duplicated in every API call site.
    ApiClient.onUnauthorized = () => _handleForcedLogout();
    _init();
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
            await _startRecording(TriggerType.remote);
          }
          break;
        case RemoteCommandType.stopRecording:
          if (_recording != null && _recording!.isActive) {
            await _recording!.stop();
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

  void _handleEmergencyTrigger() {
    if (_recording == null || _recording!.isActive) return; // ignore a stray double-press mid-recording
    _startRecording(TriggerType.emergencyButton);
  }

  Future<void> _startRecording(TriggerType trigger) async {
    final rec = _recording;
    if (rec == null || rec.isActive) return;
    setState(() => _error = null);
    await ForegroundRecordingService.start(notificationText: 'Starting recording...');
    await rec.start(triggerType: trigger);
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
    ApiClient.onUnauthorized = null;
    ForegroundRecordingService.onButtonPressed = null;
    _uiTicker?.cancel();
    _heartbeat?.stop();
    _battery.stop();
    _location?.stop();
    _commandListener?.stop();
    _emergencyTrigger?.dispose();
    _recording?.dispose();
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

  String _recordingStateLabel() {
    switch (_recordingState) {
      case RecordingLifecycleState.recording:
        return 'RECORDING';
      case RecordingLifecycleState.uploading:
        return 'FINISHING UPLOAD';
      case RecordingLifecycleState.offline:
        return 'RECORDING -- OFFLINE, QUEUED LOCALLY';
      case RecordingLifecycleState.completing:
        return 'COMPLETING';
      case RecordingLifecycleState.starting:
        return 'STARTING';
      default:
        return 'RECORDING';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final recordingActive = _recording?.isActive ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Body Camera'),
        actions: [IconButton(icon: const Icon(Icons.logout), onPressed: _logout)],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!, style: const TextStyle(color: Colors.red)),
                ),
              _statusCard(recordingActive),
              const SizedBox(height: 16),
              if (recordingActive)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  color: Colors.red.shade700,
                  child: Text(
                    '● ${_recordingStateLabel()} -- ${_recordingDuration()}\nUploaded: $_chunksUploaded  Pending: $_chunksPending${_chunksFailed > 0 ? '  Failed: $_chunksFailed' : ''}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                ),
              if (_missingChunks.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Last completed recording is missing chunk(s): ${_missingChunks.join(', ')}',
                    style: const TextStyle(color: Colors.orange),
                  ),
                ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _busy ? null : (recordingActive ? _stopRecording : () => _startRecording(TriggerType.manual)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: recordingActive ? Colors.grey : Colors.red,
                  minimumSize: const Size.fromHeight(50),
                ),
                child: Text(
                  recordingActive ? 'STOP RECORDING' : 'EMERGENCY RECORD',
                  style: const TextStyle(fontSize: 18),
                ),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 8),
              const Text('Live Stream (separate from recording)', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (_live)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  color: Colors.blue.shade700,
                  child: const Text(
                    '● Camera is LIVE -- being viewed by Control Room',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                ),
              if (_live && _localVideoTrack != null)
                SizedBox(height: 200, child: VideoTrackRenderer(_localVideoTrack!)),
              const SizedBox(height: 8),
              if (!_live)
                // Picked before Go Live -- LiveStreamService.start() defaults
                // to the back camera (see its doc comment), but the
                // constable can choose front instead here rather than the
                // choice being hardcoded either way.
                SegmentedButton<CameraPosition>(
                  segments: const [
                    ButtonSegment(value: CameraPosition.back, label: Text('Back')),
                    ButtonSegment(value: CameraPosition.front, label: Text('Front')),
                  ],
                  selected: {_selectedCameraPosition},
                  onSelectionChanged: _busy ? null : (s) => setState(() => _selectedCameraPosition = s.first),
                )
              else
                OutlinedButton.icon(
                  onPressed: _busy ? null : _switchCamera,
                  icon: const Icon(Icons.cameraswitch),
                  label: Text('Switch to ${_selectedCameraPosition == CameraPosition.back ? 'Front' : 'Back'} camera'),
                ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _busy ? null : (_live ? _stopLive : _goLive),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _live ? Colors.grey : Colors.blue,
                  minimumSize: const Size.fromHeight(44),
                ),
                child: _busy
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(_live ? 'Stop Live Stream' : 'Go Live'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusCard(bool recordingActive) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _statusRow('Device', _deviceStatusLabel(), _deviceStatusColor()),
            _statusRow('Battery', _battery.currentPercent != null ? '${_battery.currentPercent}%${_battery.isCharging == true ? ' (charging)' : ''}' : 'Unknown', Colors.grey),
            _statusRow('GPS', _locationLabel(), _locationColor()),
            _statusRow('Command channel', _commandStatus.name, _commandStatusColor()),
          ],
        ),
      ),
    );
  }

  Widget _statusRow(String label, String value, Color dotColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(Icons.circle, size: 10, color: dotColor),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w600)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Color _deviceStatusColor() {
    switch (_device?.status) {
      case 'online':
      case 'recording':
        return Colors.green;
      case 'stale':
        return Colors.orange;
      default:
        return Colors.red;
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

  Color _locationColor() => _locationAvailability == LocationAvailability.available ? Colors.green : Colors.orange;

  Color _commandStatusColor() {
    switch (_commandStatus) {
      case CommandChannelStatus.connected:
        return Colors.green;
      case CommandChannelStatus.connecting:
        return Colors.orange;
      case CommandChannelStatus.disconnected:
        return Colors.red;
    }
  }
}
