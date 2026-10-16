import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/recording_models.dart';
import 'api_client.dart';
import 'network_hopping_service.dart';
import 'offline_queue_service.dart';
import 'receiver_client.dart';

/// Moves queued chunks to where they must go and keeps the local sqflite
/// queue (offline_queue_service.dart) in step with what the far end actually
/// confirmed.
///
/// TARGETS
///   Online mode (default, unchanged): every chunk goes to the control room,
///   POST /recordings/{id}/chunks. Success deletes the local file.
///   Network Hopping mode: [NetworkHoppingService.resolveTarget] picks, per
///   sweep, the site receiver (preferred), else the control room directly,
///   else nowhere (the chunks simply wait). A chunk accepted by a receiver is
///   only `local_acked`: the receiver has it durably, but the control room
///   does not yet, so the phone KEEPS its file. Once the control room's own
///   manifest shows the same chunk with the same SHA-256, the chunk becomes
///   `uploaded` and only then is the local file deleted.
///
/// RULES (each came from a real defect; do not weaken them)
///   - retry the SAME chunk_number on failure, never skip/renumber it
///   - a network or server problem NEVER gives up on a chunk: it is retried
///     forever with persisted exponential back-off and jitter. (The old
///     "8 retries then failed" rule stranded evidence on the phone.) Only a
///     definitive refusal of the content (hash conflict, forbidden, too large,
///     not found) marks a chunk `failed`, and its file is always preserved.
///   - a 409 means different things, told apart by X-Conflict-Reason:
///     "duplicate_chunk" (already stored: success) vs "recording_not_active"
///     / "hash_conflict" (NOT stored: keep the file). Treating every 409 as
///     success once destroyed evidence.
///   - a local file is deleted only after the control room positively
///     confirmed it holds the chunk.
///   - only video/mp4 is sent.
class ChunkUploader {
  static const _mimeType = 'video/mp4';
  static const _backoffBaseSeconds = 5;
  static const _backoffMaxSeconds = 300;
  static final _random = Random();

  final void Function(QueuedChunk chunk)? onChunkUploaded;
  final void Function(QueuedChunk chunk, Object error)? onChunkFailed;

  // In-flight pass, if any. STATIC so the recording pump, startup recovery and
  // the background sync timer (separate ChunkUploader instances) can never
  // upload the same chunk concurrently. See drain() for why this is a Future
  // that concurrent callers wait on rather than a boolean flag.
  static Completer<void>? _activePass;
  static bool _redoRequested = false;
  // Whether the previous sweep had nowhere to send anything. When a route
  // reappears, back-off timers are cleared so recovery is immediate rather
  // than waiting out a long delay.
  static bool _lastSweepBlocked = false;

  ChunkUploader({this.onChunkUploaded, this.onChunkFailed});

  /// Sends every chunk that is due, in chunk_number order per session, then
  /// reconciles chunks that are only receiver-acknowledged. Stops early when a
  /// network-level failure is seen (connectivity just dropped); the next
  /// trigger resumes exactly where this left off because state only changes
  /// after a definitive answer.
  ///
  /// A caller that finds a pass already running WAITS for it and marks it
  /// dirty so it re-scans the queue at least once more before releasing. That
  /// guarantees a chunk enqueued while a pass is mid-upload (notably the final
  /// chunk at stop()) is picked up by that same pass. A plain "return if busy"
  /// once left a finished recording stuck in `recording` forever.
  Future<void> drain() async {
    if (_activePass != null) {
      debugPrint('[bodycam] drain() joining an already-running pass (requesting a re-sweep)');
      _redoRequested = true;
      await _activePass!.future;
      return;
    }
    final completer = Completer<void>();
    _activePass = completer;
    try {
      while (true) {
        _redoRequested = false;
        final blocked = await _sweep();
        if (blocked || !_redoRequested) break;
      }
    } finally {
      _activePass = null;
      completer.complete();
    }
  }

  /// "Sync now": makes every waiting chunk due immediately, then sweeps.
  Future<void> syncNow() async {
    await OfflineQueueService.clearBackoff();
    NetworkHoppingService.instance.invalidateSession();
    NetworkHoppingService.instance.clearReceiverAuthBlock();
    await drain();
  }

  /// Returns true when the pass stopped because nothing could be reached.
  Future<bool> _sweep() async {
    final nh = NetworkHoppingService.instance;
    final unsent = await OfflineQueueService.unsentChunks();
    final awaiting = await OfflineQueueService.awaitingCentralChunks();
    debugPrint('[bodycam] drain() sweep: ${unsent.length} unsent, ${awaiting.length} awaiting central confirmation');
    if (unsent.isEmpty && awaiting.isEmpty) return false;

    var blocked = false;
    if (unsent.isNotEmpty) {
      // Routing is decided PER CHUNK.
      //  - Online-mode chunks (no site id) always belong at the control room, whatever the Network Hopping settings say, and
      //    are sent exactly as before (no readiness probe; a network failure is handled by the send itself).
      //  - Site chunks follow the Network Hopping target: the receiver of THEIR site, else the control room if the fallback
      //    policy allows and it answers, else they wait. With Network Hopping switched off they go to the control room.
      // A site chunk with no route is skipped without affecting the Online-mode chunks of the same queue.
      final hasSite = unsent.any((c) => c.siteId != null);
      final siteTarget = hasSite ? await nh.resolveTarget() : null;
      if (siteTarget != null && siteTarget.kind != UploadTarget.none && _lastSweepBlocked) {
        await OfflineQueueService.clearBackoff(); // a route reappeared: do not make chunks sit out their old back-off
        _lastSweepBlocked = false;
      }
      var noRoute = false;
      final registeredReceiver = <String>{};
      final registeredCentral = <String>{};
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final chunk in await OfflineQueueService.unsentChunks()) {
        if (chunk.nextAttemptAt > now) continue; // backing off
        bool keepGoing;
        if (chunk.siteId == null) {
          keepGoing = await _sendToCentral(chunk, registeredCentral);
        } else if (siteTarget!.kind == UploadTarget.none) {
          noRoute = true;
          continue;
        } else if (siteTarget.kind == UploadTarget.receiver) {
          if (chunk.siteId != siteTarget.session!.siteId) continue; // never hand a chunk to another site's receiver
          keepGoing = await _sendToReceiver(chunk, siteTarget.session!, registeredReceiver);
        } else {
          keepGoing = await _sendToCentral(chunk, registeredCentral);
        }
        if (!keepGoing) {
          blocked = true;
          break; // network-level failure: stop this pass entirely
        }
      }
      if (noRoute) {
        _lastSweepBlocked = true;
        blocked = true;
        debugPrint('[bodycam] no route for site chunks (${siteTarget?.reason}); they wait, nothing is lost');
      }
    }

    if (awaiting.isNotEmpty && await nh.centralReachable()) {
      await _reconcileWithCentral();
    }
    return blocked;
  }

  // -------------------------------------------------------------------------
  // identity / integrity
  // -------------------------------------------------------------------------

  /// Gives the chunk a stable id and a SHA-256 (computed once, from the file
  /// exactly as it will be sent) before its first attempt, persisting both.
  /// Returns null if the file is gone (the chunk is then marked failed).
  Future<QueuedChunk?> _withIdentity(QueuedChunk chunk) async {
    final file = File(chunk.localFilePath);
    if (!await file.exists()) {
      await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateFailed, lastError: 'local_file_missing');
      onChunkFailed?.call(chunk, StateError('Local segment file missing: ${chunk.localFilePath}'));
      return null;
    }
    // Verify the file against what was recorded at capture BEFORE sending. The expected hash and size are never
    // recomputed to match the file: a changed file must not be able to "pass" by redefining what it should have been.
    final size = await file.length();
    final digest = (await crypto.sha256.bind(file.openRead()).first).toString();
    if ((chunk.sha256 != null && digest != chunk.sha256) || (chunk.sizeBytes != null && size != chunk.sizeBytes)) {
      // Local corruption is not a network error and retrying the same bytes cannot succeed. The file is KEPT for diagnosis,
      // the chunk is parked as failed (visible on the Network Hopping screen) and the recording stays incomplete.
      await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateFailed, retryCount: chunk.retryCount + 1, lastError: 'local_file_corrupt');
      onChunkFailed?.call(chunk, StateError('Local segment no longer matches its recorded SHA-256/size: ${chunk.localFilePath}'));
      return null;
    }
    if (chunk.chunkId != null && chunk.sha256 != null && chunk.sizeBytes != null) return chunk;
    final id = chunk.chunkId ?? const Uuid().v4();
    await OfflineQueueService.setChunkIdentity(chunk.id!, chunkId: id, sha256: chunk.sha256 ?? digest, sizeBytes: chunk.sizeBytes ?? size);
    return chunk.copyWith(chunkId: id, sha256: chunk.sha256 ?? digest, sizeBytes: chunk.sizeBytes ?? size);
  }

  /// Persisted exponential back-off with jitter: 5s, 10s, 20s ... capped at 5
  /// minutes, +/-25%. Survives app restarts because it is stored on the row.
  static int _nextAttempt(int retryCount, {int? atLeastSeconds}) {
    final base = min(_backoffMaxSeconds, _backoffBaseSeconds * pow(2, min(retryCount, 10)).toInt());
    final jittered = (base * (0.75 + _random.nextDouble() * 0.5)).round();
    return DateTime.now().millisecondsSinceEpoch + max(jittered, atLeastSeconds ?? 0) * 1000;
  }

  Future<void> _deferChunk(QueuedChunk chunk, String error, {int? atLeastSeconds}) async {
    await OfflineQueueService.updateChunkState(
      chunk.id!,
      uploadState: QueuedChunk.statePending,
      retryCount: chunk.retryCount + 1,
      nextAttemptAt: _nextAttempt(chunk.retryCount, atLeastSeconds: atLeastSeconds),
      lastError: error,
    );
  }

  // -------------------------------------------------------------------------
  // receiver target
  // -------------------------------------------------------------------------

  Future<bool> _sendToReceiver(QueuedChunk raw, ReceiverSession session, Set<String> registered) async {
    final chunk = await _withIdentity(raw);
    if (chunk == null) return true;
    await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateUploading);
    debugPrint('[bodycam] receiver upload starting: session=${chunk.localSessionId} chunk=${chunk.chunkNumber} retry=${chunk.retryCount}');
    try {
      if (!registered.contains(chunk.localSessionId)) {
        final local = await OfflineQueueService.getSession(chunk.localSessionId);
        await ReceiverClient.registerRecording(
          session,
          recordingId: chunk.localSessionId,
          startedAt: local?.startedAt ?? chunk.createdAt,
          triggerType: local?.triggerType.wire ?? TriggerType.manual.wire,
          cameraLensDirection: local?.cameraLens ?? 'back',
        );
        registered.add(chunk.localSessionId);
      }
      final ack = await ReceiverClient.putChunk(
        session,
        recordingId: chunk.localSessionId,
        chunkId: chunk.chunkId!,
        chunkNumber: chunk.chunkNumber,
        sha256: chunk.sha256!,
        sizeBytes: chunk.sizeBytes!,
        file: File(chunk.localFilePath),
        durationSeconds: chunk.durationSeconds,
        isLastChunk: chunk.isLastChunk,
        latitude: chunk.latitude,
        longitude: chunk.longitude,
        capturedStart: chunk.recordedAt,
        capturedEnd: chunk.recordedAt != null && chunk.durationSeconds != null ? chunk.recordedAt!.add(Duration(milliseconds: (chunk.durationSeconds! * 1000).round())) : null,
      );
      // Trust the acknowledgement only if it names the same content.
      if (ack['sync_state'] == 'quarantined') {
        // The receiver holds this chunk in quarantine: that is NOT receipt. Keep the original, surface it.
        await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateFailed, retryCount: chunk.retryCount + 1, lastError: 'receiver_quarantined');
        onChunkFailed?.call(chunk, StateError('receiver_quarantined'));
        return true;
      }
      if (ack['status'] != 'locally_durable' || ack['sha256'] != chunk.sha256 || ack['chunk_id'] != chunk.chunkId) {
        await _deferChunk(chunk, 'unexpected_receiver_ack');
        return true;
      }
      // Durable at the site, not yet at the control room: KEEP the local file.
      await OfflineQueueService.updateChunkState(
        chunk.id!,
        uploadState: QueuedChunk.stateLocalAcked,
        target: UploadTarget.receiver,
        localAckAt: DateTime.now(),
        clearLastError: true,
      );
      debugPrint('[bodycam] receiver ACK: chunk=${chunk.chunkNumber} duplicate=${ack['duplicate']}');
      onChunkUploaded?.call(chunk.copyWith(uploadState: QueuedChunk.stateLocalAcked));
      return true;
    } on ReceiverException catch (e) {
      debugPrint('[bodycam] receiver HTTP ${e.statusCode} ${e.code}');
      if (e.isUnauthorized && e.code.startsWith('session_')) {
        NetworkHoppingService.instance.invalidateSession();
        await _deferChunk(chunk, e.code, atLeastSeconds: 1);
        return false; // only the short session lapsed or was reset by a receiver restart: a fresh one is obtained on the next sweep
      }
      if (e.isGrantProblem) {
        // The grant itself was refused (revoked, expired, wrong site/device, operation not permitted). Retrying it as if
        // it were a network error would be wrong: pause receiver uploads, keep every chunk queued, and tell the officer.
        // Footage goes out once a valid grant is obtained or the control room is reachable (per the fallback policy).
        NetworkHoppingService.instance.blockReceiverAuth(e.code);
        await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.statePending, lastError: e.code, nextAttemptAt: _nextAttempt(5));
        onChunkFailed?.call(chunk, e);
        return false;
      }
      if (e.isStorageFull || e.isBusy) {
        await _deferChunk(chunk, e.code, atLeastSeconds: e.retryAfterSeconds ?? 60);
        return false; // next sweep re-checks the receiver and may use the control room
      }
      if (e.statusCode == 404 && e.code == 'recording_not_found') {
        await _deferChunk(chunk, e.code, atLeastSeconds: 1); // registration lost on the receiver: re-register next sweep
        return false;
      }
      if (e.isHashMismatch || (e.statusCode == 422 && e.code == 'size_mismatch')) {
        await _deferChunk(chunk, e.code); // corrupted in transit: send the same bytes again
        return true;
      }
      // Definitive refusal of this content (hash_conflict, recording_id_conflict,
      // chunk_too_large, unsupported_type ...): never retried blindly, file kept.
      await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateFailed, retryCount: chunk.retryCount + 1, lastError: e.code);
      onChunkFailed?.call(chunk, e);
      return true;
    } catch (e) {
      // Network-level failure: out of Wi-Fi range, receiver restarting, timeout.
      debugPrint('[bodycam] receiver NETWORK FAILURE: chunk=${chunk.chunkNumber} error=${e.runtimeType}');
      NetworkHoppingService.instance.invalidateSession();
      await _deferChunk(chunk, 'network_${e.runtimeType}');
      onChunkFailed?.call(chunk, e);
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // control-room target (the original Online-mode path, plus chunk id / hash)
  // -------------------------------------------------------------------------

  /// A Network Hopping recording is created on the phone with its own UUID
  /// and may not exist at the control room yet. POST /recordings/start is
  /// idempotent for a client-supplied recording_id, so this is safe to repeat.
  Future<String?> _ensureCentralSession(QueuedChunk chunk, Set<String> registered) async {
    final local = await OfflineQueueService.getSession(chunk.localSessionId);
    if (local == null || !local.networkHopping) return chunk.backendSessionId;
    if (registered.contains(chunk.localSessionId)) return local.localSessionId;
    await ApiClient.post('/recordings/start', body: {
      'device_identifier': local.deviceIdentifier,
      'trigger_type': local.triggerType.wire,
      'camera_lens_direction': local.cameraLens,
      'recording_id': local.localSessionId,
      if (local.siteId != null) 'site_id': local.siteId,
    });
    await OfflineQueueService.setBackendSessionIdForSession(local.localSessionId, local.localSessionId);
    registered.add(chunk.localSessionId);
    return local.localSessionId;
  }

  Future<bool> _sendToCentral(QueuedChunk raw, Set<String> registered) async {
    var chunk = await _withIdentity(raw);
    if (chunk == null) return true;

    String? sessionId;
    try {
      sessionId = await _ensureCentralSession(chunk, registered);
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        await _deferChunk(chunk, 'unauthorized', atLeastSeconds: 30);
        return false;
      }
      if (e.isForbidden || e.isNotFound || e.isValidationError || e.isConflict) {
        await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateFailed, retryCount: chunk.retryCount + 1, lastError: 'register_${e.statusCode}');
        onChunkFailed?.call(chunk, e);
        return true;
      }
      await _deferChunk(chunk, 'register_${e.statusCode}');
      return true;
    } catch (e) {
      await _deferChunk(chunk, 'network_${e.runtimeType}');
      return false;
    }
    if (sessionId == null) return true; // recording not yet registered server-side (Online mode: resolved by the pump)
    chunk = chunk.copyWith(backendSessionId: sessionId);
    final sent = chunk; // non-nullable alias for closures below

    await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateUploading);
    debugPrint('[bodycam] upload starting: recording=$sessionId chunk=${chunk.chunkNumber} retry=${chunk.retryCount}');
    try {
      await ApiClient.postMultipart(
        '/recordings/$sessionId/chunks',
        fields: {
          'chunk_number': chunk.chunkNumber.toString(),
          'chunk_id': chunk.chunkId!,
          'sha256': chunk.sha256!,
          if (chunk.durationSeconds != null) 'duration_seconds': chunk.durationSeconds!.toString(),
          'is_last_chunk': chunk.isLastChunk.toString(),
          // Real GPS fix + capture time for this exact segment -- omitted
          // entirely when GPS was unavailable, never a fabricated 0,0.
          if (chunk.latitude != null) 'latitude': chunk.latitude!.toString(),
          if (chunk.longitude != null) 'longitude': chunk.longitude!.toString(),
          if (chunk.recordedAt != null) 'recorded_at': chunk.recordedAt!.toIso8601String(),
        },
        file: File(chunk.localFilePath),
        fileFieldName: 'file',
        mimeType: _mimeType,
      );
      debugPrint('[bodycam] upload SUCCESS: recording=$sessionId chunk=${chunk.chunkNumber}');
      await _markUploaded(chunk, UploadTarget.central);
      return true;
    } on ApiException catch (e) {
      debugPrint('[bodycam] upload HTTP ${e.statusCode} reason=${e.conflictReason}: recording=$sessionId chunk=${chunk.chunkNumber}');
      if (e.isConflict) {
        if (e.conflictReason == 'duplicate_chunk') {
          // The control room positively confirmed this exact chunk exists
          // (e.g. the earlier attempt succeeded but its response was lost).
          await _markUploaded(chunk, UploadTarget.central);
          return true;
        }
        // 'recording_not_active', 'hash_conflict', or an unknown reason: the
        // chunk was NOT confirmed stored, so its file is preserved and it is
        // parked as failed rather than retried forever against a session that
        // can never accept it.
        await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateFailed, retryCount: chunk.retryCount + 1, lastError: e.conflictReason ?? 'conflict');
        onChunkFailed?.call(chunk, e);
        return true;
      }
      if (e.isUnauthorized) {
        // ApiClient.onUnauthorized already fired (or was suppressed by a valid
        // Network Hopping grant). Not the chunk's fault: keep it pending.
        await _deferChunk(chunk, 'unauthorized', atLeastSeconds: 30);
        onChunkFailed?.call(chunk, e);
        return false;
      }
      if (e.statusCode == 422 && (e.detail.contains('hash') || e.detail.contains('sha256'))) {
        await _deferChunk(chunk, 'hash_mismatch'); // corrupted in transit: resend
        onChunkFailed?.call(chunk, e);
        return true;
      }
      if (e.isPayloadTooLarge || e.isValidationError || e.isForbidden || e.isNotFound) {
        // Never fixed by retrying the identical bytes.
        await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateFailed, retryCount: chunk.retryCount + 1, lastError: 'rejected_${e.statusCode}');
        onChunkFailed?.call(chunk, e);
        return true;
      }
      // Any other server error: retry later with back-off.
      await _deferChunk(chunk, 'http_${e.statusCode}');
      onChunkFailed?.call(chunk, e);
      return true;
    } catch (e) {
      debugPrint('[bodycam] upload NETWORK FAILURE: recording=$sessionId chunk=${chunk.chunkNumber} error=${e.runtimeType}');
      // RECONCILIATION: the connection may have dropped after the server
      // already stored the chunk. Ask the manifest before deciding.
      try {
        final manifest = RecordingManifestResponse.fromJson(await ApiClient.get('/recordings/$sessionId/chunks') as Map<String, dynamic>);
        final exists = manifest.chunks.any((c) => c.chunkNumber == sent.chunkNumber && c.uploadStatus == 'uploaded' && (c.originalHash == null || c.originalHash == sent.sha256));
        if (exists) {
          debugPrint('[bodycam] upload RECONCILED: chunk ${chunk.chunkNumber} was stored despite the network error');
          await _markUploaded(chunk, UploadTarget.central);
          return true;
        }
      } catch (_) {
        // genuinely offline
      }
      await _deferChunk(chunk, 'network_${e.runtimeType}'); // retried forever, never "failed" for being offline
      onChunkFailed?.call(chunk, e);
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // central confirmation of receiver-acknowledged chunks
  // -------------------------------------------------------------------------

  /// For chunks a receiver holds: when the control room's manifest lists the
  /// same chunk with the SAME SHA-256, the control room has it, so the local
  /// file may finally be deleted. Anything else leaves the chunk untouched.
  Future<void> _reconcileWithCentral() async {
    final awaiting = await OfflineQueueService.awaitingCentralChunks();
    final bySession = <String, List<QueuedChunk>>{};
    for (final c in awaiting) {
      bySession.putIfAbsent(c.localSessionId, () => []).add(c);
    }
    for (final entry in bySession.entries) {
      try {
        final raw = await ApiClient.get('/recordings/${entry.key}/chunks');
        final manifest = RecordingManifestResponse.fromJson(raw as Map<String, dynamic>);
        for (final chunk in entry.value) {
          final match = manifest.chunks.where((m) => m.chunkNumber == chunk.chunkNumber && m.uploadStatus == 'uploaded');
          if (match.isEmpty) continue; // the receiver has not forwarded it yet
          final remote = match.first.originalHash;
          if (remote == null) continue; // cannot prove identity: keep the local copy
          if (remote == chunk.sha256) {
            await _markUploaded(chunk, UploadTarget.receiver);
          } else {
            // The control room holds DIFFERENT bytes under this chunk: a real
            // integrity problem. Keep our copy and surface it.
            await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateFailed, lastError: 'central_hash_mismatch');
            onChunkFailed?.call(chunk, StateError('central_hash_mismatch'));
          }
        }
      } on ApiException catch (e) {
        debugPrint('[bodycam] central reconciliation HTTP ${e.statusCode} for ${entry.key}: will retry');
      } catch (e) {
        debugPrint('[bodycam] central reconciliation failed (${e.runtimeType}): will retry');
        return; // control room unreachable: stop
      }
    }
  }

  Future<void> _markUploaded(QueuedChunk chunk, String target) async {
    await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateUploaded, target: target, clearLastError: true);
    onChunkUploaded?.call(chunk.copyWith(uploadState: QueuedChunk.stateUploaded));
    await _deleteLocalFile(chunk);
  }

  /// Deletes the on-disk segment of a chunk the CONTROL ROOM has confirmed
  /// (never for pending, failed or merely receiver-acknowledged chunks). A
  /// failed delete is logged and ignored: cleanup must never break upload.
  Future<void> _deleteLocalFile(QueuedChunk chunk) async {
    try {
      final file = File(chunk.localFilePath);
      if (await file.exists()) {
        await file.delete();
        debugPrint('[bodycam] deleted centrally-confirmed local segment: ${chunk.localFilePath}');
      }
    } catch (e) {
      debugPrint('[bodycam] failed to delete uploaded local segment (non-fatal): ${chunk.localFilePath} error=$e');
    }
  }

  /// DOCUMENTED LOW-STORAGE EXCEPTION. Normally a chunk's local file is kept
  /// until the control room confirms it. When the phone is critically short of
  /// space and the officer has enabled this, the OLDEST chunks that a site
  /// receiver already holds durably may be deleted to keep recording possible.
  /// The evidence then exists only on the receiver until it syncs. Returns the
  /// number of files removed. Off by default; see the Network Hopping screen.
  Future<int> purgeReceiverAckedForSpace({required int maxFiles}) async {
    final acked = await OfflineQueueService.awaitingCentralChunks();
    var removed = 0;
    for (final chunk in acked) {
      if (removed >= maxFiles) break;
      try {
        final f = File(chunk.localFilePath);
        if (await f.exists()) {
          await f.delete();
          removed++;
          await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateLocalAcked, lastError: 'local_copy_purged_low_storage');
        }
      } catch (_) {}
    }
    return removed;
  }
}
