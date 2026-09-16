import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
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
  }) async {
    final result = await ApiClient.post('/recordings/start', body: {
      'device_identifier': deviceIdentifier,
      'trigger_type': triggerType.wire,
      if (incidentId != null) 'incident_id': incidentId,
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

  final void Function(RecordingLifecycleState state)? onStateChanged;
  final void Function({required int uploaded, required int pending, required int failed})? onProgress;
  final void Function(Object error)? onError;

  RecordingService({
    required this.deviceIdentifier,
    required this.deviceId,
    this.segmentDuration = const Duration(seconds: 20),
    this.onStateChanged,
    this.onProgress,
    this.onError,
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
      state == RecordingLifecycleState.uploading ||
      state == RecordingLifecycleState.offline ||
      state == RecordingLifecycleState.completing;

  // ---------------------------------------------------------------------
  // Start
  // ---------------------------------------------------------------------

  Future<void> start({required TriggerType triggerType}) async {
    if (isActive) return; // one recording at a time; the UI must not offer Start while already active
    _stopRequested = false;
    _cancelRequested = false;
    _consecutiveNetworkFailures = 0;
    lastMissingChunkNumbers = const [];
    _localSessionId = const Uuid().v4();
    _backendSessionId = null;
    recordingStartedAt = DateTime.now();
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
      await _engine!.start(localSessionId: _localSessionId!);
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
  /// GET /recordings/?device_id=&status=recording first closes that gap.
  Future<void> _resolveBackendSession(TriggerType triggerType) async {
    if (_backendSessionId != null) return;
    try {
      final active = await RecordingApi.listActiveForDevice(deviceId);
      if (active.isNotEmpty) {
        _backendSessionId = active.first.id;
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

    final session = await RecordingApi.start(deviceIdentifier: deviceIdentifier, triggerType: triggerType);
    _backendSessionId = session.id;
    await OfflineQueueService.setBackendSessionIdForSession(_localSessionId!, _backendSessionId!);
  }

  // ---------------------------------------------------------------------
  // Segment handling
  // ---------------------------------------------------------------------

  Future<void> _handleSegmentReady(RecordingSegment segment) async {
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

    await _pump();
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
      if (allUploaded) {
        await _complete();
      } else if (anyPermanentlyFailed && afterPending.isEmpty) {
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

  /// Graceful stop: finalizes the current segment as the last chunk,
  /// uploads everything, then calls /complete. Never discards footage
  /// already captured.
  Future<void> stop() async {
    if (!isActive) return;
    _stopRequested = true;
    await _engine?.stop();
    // If the engine had no active segment (e.g. stop() called during the
    // narrow STARTING window), the segment-ready callback above will never
    // fire, so nudge the pump directly to still attempt completion.
    await _pump();
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
      final chunks = await OfflineQueueService.allChunksForSession(session.localSessionId);
      final pending = chunks.where((c) => c.uploadState != QueuedChunk.stateUploaded).toList();
      if (session.backendSessionId == null || pending.isEmpty) {
        // Nothing uploadable, or no backend session was ever obtained --
        // there's nothing more this recovery pass can safely do beyond
        // what the next active RecordingService instance's own _pump
        // would already retry once a new recording starts. Leave the row
        // as-is; it remains visible/queryable for support/debugging.
        continue;
      }
      final uploader = ChunkUploader();
      for (final chunk in pending) {
        // Re-point stuck "uploading" rows (from a process death mid-upload)
        // back to pending so drain() will actually pick them up.
        if (chunk.uploadState == QueuedChunk.stateUploading) {
          await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.statePending);
        }
      }
      await uploader.drain();
      final remaining = await OfflineQueueService.pendingChunks(localSessionId: session.localSessionId);
      if (remaining.isEmpty) {
        try {
          await RecordingApi.complete(session.backendSessionId!);
          onRecovered('Recovered and completed recording ${session.localSessionId} (${chunks.length} chunks)');
        } catch (_) {
          // Will be retried the next time the app starts, or when
          // connectivity/auth allows -- never silently dropped.
        }
      } else {
        onRecovered('Recording ${session.localSessionId} still has ${remaining.length} chunk(s) queued -- will resume on the next connectivity/app-start attempt');
      }
    }
  }

  Future<void> dispose() async {
    _pumpTimer?.cancel();
    await _engine?.dispose();
  }
}
