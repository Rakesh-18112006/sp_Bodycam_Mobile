import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart' show CameraController, CameraLensDirection;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/location_models.dart';
import '../models/recording_models.dart';
import 'api_client.dart';
import 'chunk_uploader.dart';
import 'offline_queue_service.dart';
import 'recording_engine.dart';

/// Raw backend calls for the RecordingSession lifecycle -- kept separate
/// from RecordingService's orchestration/state-machine logic below so each
/// half stays independently testable. Every field/endpoint here was
/// verified directly against backend/app/routers/recordings.py and
/// backend/app/schemas.py, not against docs/FLUTTER_API_HANDOFF.md alone.
class RecordingApi {
  static Future<RecordingSessionResponse> start({
    required String deviceIdentifier,
    required TriggerType triggerType,
    String? incidentId,
    CameraLensDirection cameraLensDirection = CameraLensDirection.back,
  }) async {
    final result = await ApiClient.post('/recordings/start', body: {
      'device_identifier': deviceIdentifier,
      'trigger_type': triggerType.wire,
      if (incidentId != null) 'incident_id': incidentId,
      // CameraLensDirection.name is already exactly "front"/"back"/"external";
      // the backend only accepts the first two (see
      // routers/recordings.py::start_recording), so an "external" lens
      // (not something this app's UI ever offers, but defensively handled)
      // falls back to "back" rather than sending a value the backend would 422 on.
      'camera_lens_direction': cameraLensDirection == CameraLensDirection.front ? 'front' : 'back',
    });
    return RecordingSessionResponse.fromJson(result as Map<String, dynamic>);
  }

  /// Used only to check for an already-active recording for this device
  /// before creating a new one (see RecordingService._resolveBackendSession
  /// for why). Constable role is authorized to list their own recordings
  /// per routers/recordings.py::list_recordings.
  static Future<List<RecordingSessionResponse>> listActiveForDevice(String deviceId) async {
    final result = await ApiClient.get('/recordings/?device_id=$deviceId&status=recording');
    return (result as List<dynamic>).map((e) => RecordingSessionResponse.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<RecordingSessionResponse> complete(String recordingId) async {
    final result = await ApiClient.post('/recordings/$recordingId/complete');
    return RecordingSessionResponse.fromJson(result as Map<String, dynamic>);
  }

  static Future<RecordingSessionResponse> cancel(String recordingId) async {
    final result = await ApiClient.post('/recordings/$recordingId/cancel');
    return RecordingSessionResponse.fromJson(result as Map<String, dynamic>);
  }

  static Future<RecordingManifestResponse> manifest(String recordingId) async {
    final result = await ApiClient.get('/recordings/$recordingId/chunks');
    return RecordingManifestResponse.fromJson(result as Map<String, dynamic>);
  }
}

/// Orchestrates one recording attempt end-to-end: local camera capture
/// (RecordingEngine) + persistent chunk queue (OfflineQueueService) +
/// upload (ChunkUploader) + backend session lifecycle (RecordingApi),
/// implementing the state machine described in the implementation brief:
///
///   IDLE -> STARTING -> RECORDING -> UPLOADING -> COMPLETING -> COMPLETED
///
/// with OFFLINE, START_FAILED, UPLOAD_FAILED, COMPLETE_FAILED and
/// CANCELLED as the failure/exception branches. RECORDING and UPLOADING
/// are deliberately distinct: RECORDING covers the entire time the camera
/// is actively capturing (chunks are queued and opportunistically uploaded
/// in the background throughout, but the camera is never blocked on
/// network state -- see docs/FLUTTER_API_HANDOFF.md §O, "continue
/// recording locally... do not stop recording just because upload is
/// failing"); UPLOADING begins only once the constable stops the
/// recording and covers draining whatever chunks are still queued before
/// COMPLETING can call POST /recordings/{id}/complete.
class RecordingService {
  final String deviceIdentifier;
  final String deviceId; // backend Device.id (UUID) -- needed for the active-session lookup below
  final Duration segmentDuration;

  RecordingEngine? _engine;
  late final ChunkUploader _uploader;
  String? _localSessionId;
  String? _backendSessionId;
  bool _stopRequested = false;
  bool _cancelRequested = false;
  Timer? _pumpTimer;
  int _consecutiveNetworkFailures = 0;
  Duration _currentPumpInterval = const Duration(seconds: 10);

  RecordingLifecycleState state = RecordingLifecycleState.idle;
  List<int> lastMissingChunkNumbers = const [];
  DateTime? recordingStartedAt;
  // The trigger/camera actually in effect for the CURRENT recording
  // attempt (set once, at the top of start(), read by the UI for the
  // Go-Live-style recording view -- see home_screen.dart). Distinct from
  // the [cameraLensDirection] parameter passed into start() itself, which
  // only the caller sees -- this is what the rest of the service (and the
  // UI) reads afterward.
  TriggerType? activeTriggerType;
  CameraLensDirection _activeCameraLensDirection = CameraLensDirection.back;

  /// Read-only passthrough so the UI can render a REAL, live
  /// `CameraPreview(controller)` -- see RecordingEngine.controller's doc
  /// comment. Null whenever no engine is active.
  CameraController? get cameraController => _engine?.controller;

  final void Function(RecordingLifecycleState state)? onStateChanged;
  final void Function({required int uploaded, required int pending, required int failed})? onProgress;
  final void Function(Object error)? onError;

  /// Reads the app's EXISTING cached GPS fix (see location_service.dart's
  /// LocationService.lastFix) at the moment each segment finishes, so it
  /// can be attached to that chunk's upload -- never a new GPS
  /// poll/request of its own. Null when the caller has no location service
  /// wired up, or when GPS is genuinely unavailable right now; either way
  /// this is passed straight through to the backend as "unavailable"
  /// rather than a fabricated coordinate (see chunk_uploader.dart).
  final GpsFix? Function()? locationProvider;

  RecordingService({
    required this.deviceIdentifier,
    required this.deviceId,
    this.segmentDuration = const Duration(seconds: 20),
    this.onStateChanged,
    this.onProgress,
    this.onError,
    this.locationProvider,
  }) {
    _uploader = ChunkUploader(
      onChunkUploaded: (_) => _reportProgress(),
      onChunkFailed: (_, _) => _reportProgress(),
    );
  }

  void _setState(RecordingLifecycleState s) {
    state = s;
    onStateChanged?.call(s);
  }

  Future<void> _reportProgress() async {
    if (_localSessionId == null || onProgress == null) return;
    final chunks = await OfflineQueueService.allChunksForSession(_localSessionId!);
    final uploaded = chunks.where((c) => c.uploadState == QueuedChunk.stateUploaded).length;
    final failed = chunks.where((c) => c.uploadState == QueuedChunk.stateFailed).length;
    final pending = chunks.length - uploaded - failed;
    onProgress!(uploaded: uploaded, pending: pending, failed: failed);
  }

  bool get isActive => state == RecordingLifecycleState.starting ||
      state == RecordingLifecycleState.recording ||
      state == RecordingLifecycleState.backgroundPaused ||
      state == RecordingLifecycleState.uploading ||
      state == RecordingLifecycleState.offline ||
      state == RecordingLifecycleState.completing;

  // ---------------------------------------------------------------------
  // Start
  // ---------------------------------------------------------------------

  /// [cameraLensDirection] defaults to back -- unchanged existing behavior
  /// for every call site that doesn't explicitly pass it. Only the
  /// emergency-trigger UI currently passes front, per the constable's own
  /// selection (see home_screen.dart) -- never remembered/reused beyond
  /// that one call.
  Future<void> start({required TriggerType triggerType, CameraLensDirection cameraLensDirection = CameraLensDirection.back}) async {
    if (isActive) return; // one recording at a time; the UI must not offer Start while already active
    _stopRequested = false;
    _cancelRequested = false;
    _consecutiveNetworkFailures = 0;
    lastMissingChunkNumbers = const [];
    _localSessionId = const Uuid().v4();
    _backendSessionId = null;
    recordingStartedAt = DateTime.now();
    activeTriggerType = triggerType;
    _activeCameraLensDirection = cameraLensDirection;
    _setState(RecordingLifecycleState.starting);

    await OfflineQueueService.upsertSession(LocalRecordingSession(
      localSessionId: _localSessionId!,
      backendSessionId: null,
      deviceIdentifier: deviceIdentifier,
      triggerType: triggerType,
      lifecycleState: RecordingLifecycleState.starting.name,
      startedAt: recordingStartedAt!,
      endedAt: null,
    ));

    // Local capture must never be blocked on the network (§O), so the
    // backend session is resolved in the background (see _pump) rather
    // than awaited here -- but a DEFINITIVE rejection (not owned, device
    // not registered, bad trigger_type, etc.) is still checked up front,
    // synchronously, so the constable gets immediate, honest feedback
    // instead of a camera that starts recording evidence nobody can ever
    // attribute to a valid session.
    try {
      await _resolveBackendSession(triggerType);
    } on ApiException catch (e) {
      // A definitive (non-network) rejection: do not start the camera at
      // all -- there is no scenario where locally recording anyway helps
      // if the backend has already told us this device/trigger is invalid.
      _setState(RecordingLifecycleState.startFailed);
      await OfflineQueueService.upsertSession(LocalRecordingSession(
        localSessionId: _localSessionId!,
        backendSessionId: null,
        deviceIdentifier: deviceIdentifier,
        triggerType: triggerType,
        lifecycleState: RecordingLifecycleState.startFailed.name,
        startedAt: recordingStartedAt!,
        endedAt: DateTime.now(),
      ));
      onError?.call(e);
      return;
    } catch (_) {
      // Network-level failure resolving the backend session -- proceed to
      // record locally anyway; _pump keeps retrying resolution in the
      // background.
    }

    _engine = RecordingEngine(
      segmentDuration: segmentDuration,
      onSegmentReady: _handleSegmentReady,
      onError: (e) {
        onError?.call(e);
      },
    );

    try {
      await _engine!.start(localSessionId: _localSessionId!, lensDirection: cameraLensDirection);
    } catch (e) {
      // Camera/microphone permission denied, no camera hardware, or the
      // platform genuinely failed to start -- this MUST surface as
      // START_FAILED, never as a silent no-op or a fake "recording" state.
      _setState(RecordingLifecycleState.startFailed);
      await OfflineQueueService.upsertSession(LocalRecordingSession(
        localSessionId: _localSessionId!,
        backendSessionId: _backendSessionId,
        deviceIdentifier: deviceIdentifier,
        triggerType: triggerType,
        lifecycleState: RecordingLifecycleState.startFailed.name,
        startedAt: recordingStartedAt!,
        endedAt: DateTime.now(),
      ));
      // REAL BUG, physically reproduced (11 stuck RecordingSession rows
      // found server-side, several created mere milliseconds-to-seconds
      // apart on the same device): _resolveBackendSession above may have
      // already created and committed a backend RecordingSession (status
      // "recording") before the camera itself failed to start here -- e.g.
      // a double-trigger race (manual button + emergency volume gesture
      // firing within the same window), the camera already being held by
      // another attempt, or a genuine hardware/permission failure. Without
      // this, that backend session is never told the truth: it sits at
      // status="recording" with zero chunks forever, indistinguishable
      // server-side from a device that is still actively (but silently)
      // recording -- exactly the "stuck recording" symptom reported from
      // real Internet testing. Best-effort and never allowed to change the
      // outcome the constable sees (still STARTFAILED either way): if this
      // cancel call itself fails (offline, already-changed session state,
      // etc.), the session remains an orphan to be cleaned up separately,
      // but this closes the common case.
      if (_backendSessionId != null) {
        try {
          await RecordingApi.cancel(_backendSessionId!);
        } catch (_) {}
      }
      onError?.call(e);
      return;
    }

    _setState(RecordingLifecycleState.recording);
    await OfflineQueueService.upsertSession(LocalRecordingSession(
      localSessionId: _localSessionId!,
      backendSessionId: _backendSessionId,
      deviceIdentifier: deviceIdentifier,
      triggerType: triggerType,
      lifecycleState: RecordingLifecycleState.recording.name,
      startedAt: recordingStartedAt!,
      endedAt: null,
    ));

    _currentPumpInterval = const Duration(seconds: 10);
    _pumpTimer?.cancel();
    _pumpTimer = Timer.periodic(_currentPumpInterval, (_) => _pump());
  }

  /// Looks for an already-active recording for this device before creating
  /// a new one. POST /recordings/start has no idempotency-key protection
  /// server-side (confirmed in routers/recordings.py -- every call inserts
  /// a fresh RecordingSession row), so blindly retrying it after a timeout
  /// whose response we never saw could create a duplicate session that
  /// silently fragments the constable's evidence across two IDs. Checking
  /// GET /recordings/?device_id=&status=recording first closes that gap --
  /// BUT only ever adopts a session that is plausibly OUR OWN lost-response
  /// retry of THIS exact attempt, never an unrelated session left
  /// "recording" server-side by a previous crash/kill that
  /// recoverOnStartup hasn't reconciled yet. A genuine lost-response retry
  /// would be for the identical trigger_type/camera we're starting with
  /// right now, AND created within a realistic single-request retry
  /// window of our own recordingStartedAt (kNetworkTimeout is 30s; 60s
  /// gives a safe margin without reaching into "minutes/hours-old orphan"
  /// territory). Real bug found via physical device testing: without this
  /// filter, a fresh emergency-trigger recording silently adopted and
  /// later completed an unrelated stale session instead of creating (and
  /// completing) its own -- see docs/physical-verification notes.
  Future<void> _resolveBackendSession(TriggerType triggerType) async {
    if (_backendSessionId != null) return;
    try {
      final active = await RecordingApi.listActiveForDevice(deviceId);
      final wantCamera = _activeCameraLensDirection == CameraLensDirection.front ? 'front' : 'back';
      const retryWindow = Duration(seconds: 60);
      final ownRetry = active.where((s) =>
          s.triggerType == triggerType &&
          s.cameraLensDirection == wantCamera &&
          recordingStartedAt != null &&
          s.createdAt.difference(recordingStartedAt!).abs() <= retryWindow);
      if (ownRetry.isNotEmpty) {
        _backendSessionId = ownRetry.first.id;
        await OfflineQueueService.setBackendSessionIdForSession(_localSessionId!, _backendSessionId!);
        return;
      }
    } on ApiException {
      rethrow; // a definitive auth/authorization failure here is real and must propagate
    } catch (_) {
      // Network failure on the lookup -- fall through and let start()
      // attempt a fresh POST /recordings/start below; if THAT also fails
      // on the network, the caller's catch-all handles it the same way.
    }

    final session = await RecordingApi.start(
      deviceIdentifier: deviceIdentifier,
      triggerType: triggerType,
      cameraLensDirection: _activeCameraLensDirection,
    );
    _backendSessionId = session.id;
    await OfflineQueueService.setBackendSessionIdForSession(_localSessionId!, _backendSessionId!);
  }

  // ---------------------------------------------------------------------
  // Segment handling
  // ---------------------------------------------------------------------

  Future<void> _handleSegmentReady(RecordingSegment segment) async {
    // Existing cached fix only -- never a fresh GPS request per segment
    // (see locationProvider's doc comment above).
    final fix = locationProvider?.call();
    final chunk = QueuedChunk(
      localSessionId: _localSessionId!,
      backendSessionId: _backendSessionId,
      chunkNumber: segment.chunkNumber,
      localFilePath: segment.file.path,
      durationSeconds: segment.durationSeconds,
      isLastChunk: segment.isLastChunk,
      uploadState: QueuedChunk.statePending,
      retryCount: 0,
      createdAt: DateTime.now(),
      latitude: fix?.latitude,
      longitude: fix?.longitude,
      recordedAt: segment.startedAt,
    );
    await OfflineQueueService.enqueueChunk(chunk);
    debugPrint('[bodycam] chunk ${chunk.chunkNumber} queued for session=${_backendSessionId ?? "(unresolved)"}');
    await _reportProgress();

    if (segment.isLastChunk) {
      // The camera has finished (stop() was called and the final segment
      // is now queued) -- move into UPLOADING to drain everything before
      // we're allowed to call /complete.
      _setState(RecordingLifecycleState.uploading);
    }

    // REAL BUG FIXED HERE, found via physical testing: this used to be
    // `await _pump()`, which -- especially for the final segment -- can
    // take as long as the ENTIRE remaining upload queue takes to drain
    // (many chunks, each tens of seconds on real mobile Internet). Since
    // RecordingEngine's native "stop" MethodChannel result (and therefore
    // RecordingEngine.stop(), and therefore RecordingService.stop(), and
    // therefore whatever UI/remote-command code called stop() in the first
    // place) is held open until THIS callback (onSegmentReady) returns
    // (see RecordingEngine._handleNativeCall's isLast branch), awaiting
    // the full pump/drain cycle here meant STOP itself did not visibly
    // complete until every historical chunk had finished uploading --
    // exactly the "app continues appearing to record" symptom reported
    // from real Internet testing, where a single chunk upload can take
    // 20-40s and there can be several queued.
    //
    // The camera has ALREADY physically stopped by the time this runs
    // (CameraX Finalize already fired -- see NativeRecordingManager.kt).
    // The only thing that must complete before this method returns is the
    // enqueue above (durably persisting the chunk -- already done) and the
    // state transition (already done). Actually driving the upload queue
    // and checking for completion is a background concern from here on:
    // fire it off without blocking, backed by the still-running
    // _pumpTimer (unchanged, still ticks independently) as the safety net
    // if this particular call encounters a transient failure.
    unawaited(_pump().catchError((Object e) => onError?.call(e)));
  }

  // ---------------------------------------------------------------------
  // Pump: the single place that advances backend-session resolution,
  // upload draining, and completion. Safe to call repeatedly/concurrently
  // -- ChunkUploader.drain() and the resolve step are both internally
  // reentrancy-guarded.
  // ---------------------------------------------------------------------

  Future<void> _pump() async {
    if (_localSessionId == null) return;

    if (_backendSessionId == null) {
      try {
        // We don't have the trigger_type handy here (only start() does),
        // but a still-null backend session id after start() only happens
        // on the network-failure branch, where a fresh RecordingSession
        // (manual, since the original trigger context wasn't persisted
        // past that branch) is an acceptable, honestly-logged fallback --
        // never silently losing the footage, which matters far more than
        // preserving the exact original trigger_type label on a retry.
        await _resolveBackendSession(TriggerType.manual);
        _consecutiveNetworkFailures = 0;
      } catch (e) {
        _consecutiveNetworkFailures++;
        if (state == RecordingLifecycleState.uploading || state == RecordingLifecycleState.completing) {
          _setState(RecordingLifecycleState.offline);
        }
        onError?.call(e);
        return; // nothing else to do until we have a session id
      }
    }

    final beforePending = await OfflineQueueService.pendingChunks(localSessionId: _localSessionId!);
    if (beforePending.isNotEmpty) {
      await _uploader.drain();
    }
    final afterPending = await OfflineQueueService.pendingChunks(localSessionId: _localSessionId!);
    final stillFailingNetwork = afterPending.isNotEmpty && afterPending.length == beforePending.length && beforePending.isNotEmpty;

    if (stillFailingNetwork) {
      _consecutiveNetworkFailures++;
      if (state == RecordingLifecycleState.uploading) _setState(RecordingLifecycleState.offline);
    } else {
      _consecutiveNetworkFailures = 0;
      if (state == RecordingLifecycleState.offline) {
        _setState(_stopRequested ? RecordingLifecycleState.uploading : RecordingLifecycleState.recording);
      }
    }

    await _reportProgress();
    _rescheduleAfterFailureCount();

    if (_stopRequested && !_cancelRequested) {
      final allChunks = await OfflineQueueService.allChunksForSession(_localSessionId!);
      final allUploaded = allChunks.isNotEmpty && allChunks.every((c) => c.uploadState == QueuedChunk.stateUploaded);
      final anyPermanentlyFailed = allChunks.any((c) => c.uploadState == QueuedChunk.stateFailed);
      final allFinished = allChunks.isNotEmpty && allChunks.every((c) => c.uploadState == QueuedChunk.stateUploaded || c.uploadState == QueuedChunk.stateFailed);
      if (allUploaded) {
        await _complete();
      } else if (anyPermanentlyFailed && allFinished) {
        // Nothing left to retry, but not everything made it -- completing
        // is still correct per §I (the backend computes and surfaces
        // missing_chunk_numbers rather than blocking completion forever),
        // it just won't be a fully continuous recording.
        await _complete();
      }
    }
  }

  /// Widens the pump interval the longer connectivity/backend has been
  /// unreachable (capped at 2 minutes), instead of hammering an
  /// unreachable server every 10s for a multi-hour outage -- and snaps
  /// back to the normal 10s cadence the moment things recover. This is
  /// the actual consumer of [_consecutiveNetworkFailures]; without it the
  /// counter would exist purely for display, which isn't worth tracking.
  void _rescheduleAfterFailureCount() {
    final target = switch (_consecutiveNetworkFailures) {
      0 => const Duration(seconds: 10),
      1 || 2 => const Duration(seconds: 20),
      3 || 4 || 5 => const Duration(seconds: 45),
      _ => const Duration(minutes: 2),
    };
    if (target == _currentPumpInterval || _pumpTimer == null) return;
    _currentPumpInterval = target;
    _pumpTimer?.cancel();
    _pumpTimer = Timer.periodic(_currentPumpInterval, (_) => _pump());
  }

  Future<void> _complete() async {
    if (_backendSessionId == null) return;
    _setState(RecordingLifecycleState.completing);
    try {
      final result = await RecordingApi.complete(_backendSessionId!);
      lastMissingChunkNumbers = result.missingChunkNumbers;
      _setState(RecordingLifecycleState.completed);
      _pumpTimer?.cancel();
      final session = await OfflineQueueService.getSession(_localSessionId!);
      if (session != null) {
        await OfflineQueueService.upsertSession(session.copyWith(
          lifecycleState: RecordingLifecycleState.completed.name,
          endedAt: DateTime.now(),
        ));
      }
    } catch (e) {
      _setState(RecordingLifecycleState.completeFailed);
      onError?.call(e);
      // Left as completeFailed rather than retried automatically forever
      // here -- the periodic _pump loop above will naturally try again
      // next tick as long as _stopRequested stays true and the timer is
      // still running (only cancelled on genuine success), so this is not
      // a dead end.
    }
  }

  // ---------------------------------------------------------------------
  // Stop / Cancel
  // ---------------------------------------------------------------------

  /// Graceful stop. Returns as soon as the camera has genuinely stopped and
  /// the final segment is safely persisted/enqueued locally -- it does NOT
  /// wait for that (or any other) chunk to actually finish uploading, nor
  /// for the recording to reach COMPLETED. Uploading and completion happen
  /// asynchronously afterward (driven by the fire-and-forget _pump() calls
  /// this triggers, plus the still-running periodic _pumpTimer as a
  /// safety net) -- see _handleSegmentReady's matching doc comment for the
  /// real bug this fixes. Never discards footage already captured.
  Future<void> stop() async {
    if (!isActive) return;
    _stopRequested = true;
    await _engine?.stop();
    // If the engine had no active segment (e.g. stop() called during the
    // narrow STARTING window), the segment-ready callback above will never
    // fire, so nudge the pump directly to still attempt completion --
    // fire-and-forget for the same reason as _handleSegmentReady's own
    // _pump() call: this method must not block its caller on the upload
    // queue draining.
    unawaited(_pump().catchError((Object e) => onError?.call(e)));
  }

  // ---------------------------------------------------------------------
  // Background pause / resume
  // ---------------------------------------------------------------------

  /// Call the instant the app is about to leave the foreground (see
  /// home_screen.dart's WidgetsBindingObserver) -- kept as a real, called
  /// method rather than removed, per the background/locked-recording
  /// architecture brief's explicit instruction.
  ///
  /// UNDER THE CURRENT (native CameraX) ENGINE ARCHITECTURE this is a
  /// deliberate no-op: RecordingEngine now proxies to a native camera
  /// pipeline bound to its own Activity-independent LifecycleOwner (see
  /// recording_engine.dart's top doc comment and
  /// android/.../camera/RecordingLifecycleOwner.kt), so capture genuinely
  /// continues through backgrounding/screen-lock and there is nothing to
  /// pause -- entering [RecordingLifecycleState.backgroundPaused] here
  /// would be actively misleading (home_screen.dart displays that state as
  /// "Recording paused (app in background)", which would no longer be
  /// true). [state] simply stays [RecordingLifecycleState.recording] (or
  /// [RecordingLifecycleState.offline]) straight through backgrounding,
  /// same as it already does for any other momentary UI-irrelevant
  /// transition.
  Future<void> pauseForBackground() async {
    await _engine?.pauseForBackground();
  }

  /// Call when the app returns to the foreground after
  /// [pauseForBackground] -- a no-op under the current engine architecture
  /// for the same reason [pauseForBackground] is: see that method's doc
  /// comment. Kept, not removed, for the same call-site-compatibility
  /// reason.
  Future<void> resumeFromBackground() async {
    await _engine?.resumeFromBackground();
  }

  /// Explicit cancellation (docs/FLUTTER_API_HANDOFF.md §J) -- used when
  /// the recording should NOT be treated as a finished, reviewable
  /// session. Stops the camera immediately, marks any not-yet-uploaded
  /// chunks failed (the backend will reject further chunk uploads to a
  /// cancelled session anyway -- see routers/recordings.py:174-178, the
  /// same status!=recording guard used for chunk upload), and calls
  /// POST /recordings/{id}/cancel.
  Future<void> cancel() async {
    if (!isActive) return;
    _cancelRequested = true;
    _stopRequested = true;
    _pumpTimer?.cancel();
    await _engine?.stop();
    if (_localSessionId != null) {
      final chunks = await OfflineQueueService.pendingChunks(localSessionId: _localSessionId!);
      for (final c in chunks) {
        await OfflineQueueService.updateChunkState(c.id!, uploadState: QueuedChunk.stateFailed);
      }
    }
    try {
      if (_backendSessionId != null) {
        await RecordingApi.cancel(_backendSessionId!);
      }
    } catch (e) {
      onError?.call(e);
    }
    _setState(RecordingLifecycleState.cancelled);
    if (_localSessionId != null) {
      final session = await OfflineQueueService.getSession(_localSessionId!);
      if (session != null) {
        await OfflineQueueService.upsertSession(session.copyWith(lifecycleState: RecordingLifecycleState.cancelled.name, endedAt: DateTime.now()));
      }
    }
  }

  // ---------------------------------------------------------------------
  // Startup recovery (§12): resume any recording left in-flight by a
  // previous app process (crash, force-kill, battery-optimization kill).
  // ---------------------------------------------------------------------

  /// Must be called once at app startup, before any new recording is
  /// allowed to start. Never re-opens the camera for an interrupted
  /// session (there is no way to safely resume mid-segment capture after
  /// a process death -- the in-progress segment file, if any, is
  /// incomplete/corrupt and is discarded, never uploaded as if it were a
  /// valid chunk) -- it only resumes UPLOADING already-finalized segments
  /// and, once the queue drains, calls /complete so the session doesn't
  /// stay stuck in "recording" server-side forever.
  static Future<void> recoverOnStartup({required void Function(String message) onRecovered}) async {
    final unfinished = await OfflineQueueService.unfinishedSessions();
    for (final session in unfinished) {
      if (session.lifecycleState == RecordingLifecycleState.startFailed.name) continue;

      // REAL BUG HARDENED HERE (background/locked-upload audit): the
      // native camera pipeline is lifecycle-independent (see
      // RecordingEngine's own doc comment) and keeps writing finished
      // segment files to disk even if the Dart engine that would normally
      // enqueue each one into OfflineQueueService gets torn down first --
      // e.g. the OS (or an aggressive OEM background-app killer) kills the
      // Flutter engine/Activity between a segment finishing natively and
      // this app's Dart isolate processing the corresponding
      // "segmentReady" platform-channel call for it. Without this scan,
      // such a file sits on disk with no row in chunk_queue -- invisible
      // to drain()/_pump()/the completion check, silently indistinguishable
      // from evidence that was simply never captured. This recovers it as
      // an ordinary pending chunk on the next app launch, exactly as if it
      // had been enqueued the moment it was recorded.
      await _recoverOrphanedSegmentFiles(session);

      final chunks = await OfflineQueueService.allChunksForSession(session.localSessionId);
      var pending = chunks.where((c) => c.uploadState != QueuedChunk.stateUploaded).toList();

      if (session.backendSessionId == null) {
        // No backend session was ever obtained -- there's nothing this
        // recovery pass can safely do beyond what the next active
        // RecordingService instance's own _pump would already retry once
        // a new recording starts. Leave the row as-is; it remains
        // visible/queryable for support/debugging.
        continue;
      }

      if (pending.isNotEmpty) {
        final uploader = ChunkUploader();
        for (final chunk in pending) {
          // Re-point stuck "uploading" rows (from a process death mid-upload)
          // back to pending so drain() will actually pick them up.
          if (chunk.uploadState == QueuedChunk.stateUploading) {
            await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.statePending);
          }
        }
        await uploader.drain();
        pending = await OfflineQueueService.pendingChunks(localSessionId: session.localSessionId);
      }

      if (pending.isEmpty) {
        // REAL BUG FIXED HERE, physically reproduced (real Internet
        // testing: all 6 chunks of a session -- including the final one --
        // confirmed `upload_status=uploaded` server-side, yet the session
        // stayed stuck at status=recording indefinitely). Root cause: this
        // branch used to be folded into the same early-exit as "no backend
        // session at all" whenever EVERY chunk was ALREADY uploaded before
        // this recovery pass even began -- e.g. the app process died (OS
        // kill, dead battery, OEM background-app killer) in the narrow
        // window between the final chunk's upload succeeding and
        // RecordingService._pump()'s own post-upload completion check
        // running. The evidence was already 100% safely stored server-side;
        // only the final status transition was ever missing. This now
        // always attempts /complete whenever the local queue is (now, or
        // already was) fully drained, not only when THIS pass did the
        // draining.
        try {
          await RecordingApi.complete(session.backendSessionId!);
          onRecovered('Recovered and completed recording ${session.localSessionId} (${chunks.length} chunks)');
        } catch (_) {
          // Will be retried the next time the app starts, or when
          // connectivity/auth allows -- never silently dropped.
        }
      } else {
        onRecovered('Recording ${session.localSessionId} still has ${pending.length} chunk(s) queued -- will resume on the next connectivity/app-start attempt');
      }
    }
  }

  /// Filenames are always `segment_NNNNNN.mp4` (zero-padded chunk number --
  /// see NativeRecordingManager.kt's beginSegment(), the only place that
  /// creates them). Duration/GPS/timestamp metadata for a recovered file is
  /// unavailable (it was only ever computed by the native "segmentReady"
  /// event this file's own enqueue call never received) -- sent as null/
  /// unknown rather than guessed. is_last_chunk is always sent false: this
  /// scan has no way to positively confirm a recovered file was genuinely
  /// the session's true final segment (the process could have been killed
  /// before capturing a later one too), and the completion path below
  /// already calls /complete once the local queue is empty regardless of
  /// any single chunk's is_last_chunk flag -- see chunk_manifest.py for how
  /// the backend independently determines missing chunks either way.
  static final RegExp _segmentFilePattern = RegExp(r'^segment_(\d{6})\.mp4$');

  static Future<void> _recoverOrphanedSegmentFiles(LocalRecordingSession session) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final sessionDir = Directory(p.join(docsDir.path, 'recordings', session.localSessionId));
    if (!await sessionDir.exists()) return;

    final existing = await OfflineQueueService.allChunksForSession(session.localSessionId);
    final knownNumbers = existing.map((c) => c.chunkNumber).toSet();

    await for (final entry in sessionDir.list()) {
      if (entry is! File) continue;
      final match = _segmentFilePattern.firstMatch(p.basename(entry.path));
      if (match == null) continue;
      final chunkNumber = int.parse(match.group(1)!);
      if (knownNumbers.contains(chunkNumber)) continue;

      await OfflineQueueService.enqueueChunk(QueuedChunk(
        localSessionId: session.localSessionId,
        backendSessionId: session.backendSessionId,
        chunkNumber: chunkNumber,
        localFilePath: entry.path,
        durationSeconds: null,
        isLastChunk: false,
        uploadState: QueuedChunk.statePending,
        retryCount: 0,
        createdAt: DateTime.now(),
      ));
      knownNumbers.add(chunkNumber);
    }
  }

  Future<void> dispose() async {
    _pumpTimer?.cancel();
    await _engine?.dispose();
  }
}
