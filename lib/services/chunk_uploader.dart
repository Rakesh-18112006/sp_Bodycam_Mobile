import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/recording_models.dart';
import 'api_client.dart';
import 'offline_queue_service.dart';

/// Uploads queued chunks to POST /recordings/{recording_id}/chunks and
/// keeps the local sqflite queue (offline_queue_service.dart) in sync with
/// what the backend actually confirmed. Every rule here comes directly
/// from docs/FLUTTER_API_HANDOFF.md §H/§O, verified against the real
/// implementation in backend/app/routers/recordings.py::upload_chunk:
///   - retry the SAME chunk_number on failure, never skip/renumber it
///   - a 409 means one of two different things, told apart via the
///     X-Conflict-Reason response header (see ApiException.conflictReason
///     and this file's own handling below): "duplicate_chunk" (a retry of
///     an already-accepted chunk -- safe to treat as success) is NOT the
///     same as "recording_not_active" (this chunk was never accepted at
///     all -- its local copy must be preserved, never deleted). Treating
///     every 409 as success was a real, physically-reproduced evidence-loss
///     bug; do not reintroduce that.
///   - never invent/guess a mime type: this app only ever produces
///     video/mp4 segments (see recording_engine.dart), so that's the only
///     mime type sent, and it's one of the backend's ALLOWED_MIME_TO_EXT
///     values, content-sniffed and verified server-side regardless.
class ChunkUploader {
  static const _mimeType = 'video/mp4';
  static const _maxRetries = 8;

  final void Function(QueuedChunk chunk)? onChunkUploaded;
  final void Function(QueuedChunk chunk, Object error)? onChunkFailed;

  // In-flight pass, if any -- see drain()'s doc comment for why this is a
  // Future (awaited by a concurrent caller) rather than the plain boolean
  // flag this used to be.
  Completer<void>? _activePass;
  bool _redoRequested = false;

  ChunkUploader({this.onChunkUploaded, this.onChunkFailed});

  /// Uploads every currently-pending/failed chunk that has a known backend
  /// session id, in chunk_number order per session. Stops early (rather
  /// than burning through retries) the moment a network-level failure is
  /// seen, on the assumption connectivity just dropped -- the next trigger
  /// (reconnect, next segment finished, periodic retry timer) will resume
  /// from exactly where this left off, because state is only ever mutated
  /// after a definitive server response.
  ///
  /// REAL INTERNET-ONLY DATA LOSS BUG FIXED HERE (root-caused via a
  /// physically-reproduced stuck session: chunk 1 uploaded, no final chunk
  /// ever stored, recording stuck in status=recording indefinitely). A
  /// single chunk upload over a public HTTPS/Cloudflare-Tunnel path
  /// routinely takes several seconds to tens of seconds -- vs.
  /// sub-second on local/USB -- which opens a wide window for this race:
  /// RecordingEngine.stop() enqueues the final chunk and immediately calls
  /// _pump() -> drain() (see recording_service.dart), but if the periodic
  /// pump timer's PREVIOUS drain() pass is still mid-upload of an earlier
  /// chunk at that instant, the old implementation here just returned
  /// instantly as a no-op -- it neither waited for that pass nor told it
  /// about the newly-queued final chunk. That pass's own `pending` list was
  /// snapshotted BEFORE the final chunk existed, so it never uploaded it
  /// either. The final chunk was then only rescued by pure luck of a
  /// future timer tick starting with no other pass in flight -- on a slow
  /// connection, that could take arbitrarily long, or never happen if the
  /// session/app moved on first. This never reproduced locally because the
  /// race window there is negligible.
  ///
  /// Fix: a caller that finds a pass already running now WAITS for it
  /// (rather than bailing) and marks that pass "dirty" so it re-scans the
  /// queue from the database at least once more before releasing --
  /// guaranteeing any chunk enqueued concurrently with an in-flight pass is
  /// picked up by that very pass, and that callers awaiting drain() only
  /// ever see it return once the queue has genuinely been swept as of a
  /// point in time after their call.
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
        final pending = await OfflineQueueService.pendingChunks();
        debugPrint('[bodycam] drain() sweep starting: ${pending.length} pending chunk(s) across all sessions');
        var networkDown = false;
        for (final chunk in pending) {
          if (chunk.backendSessionId == null) continue; // recording session not yet registered server-side
          if (chunk.retryCount >= _maxRetries && chunk.uploadState == QueuedChunk.stateFailed) continue; // give up silently retrying; still visible to the UI as failed
          final keepGoing = await _uploadOne(chunk);
          if (!keepGoing) {
            networkDown = true;
            break; // network-level failure -- stop this pass entirely
          }
        }
        // Only re-sweep (to pick up chunks enqueued while we were mid-pass,
        // e.g. the final chunk on stop()) when the network is actually up;
        // a genuine connectivity failure still stops this call exactly as
        // before, leaving retry to the next external trigger.
        if (networkDown || !_redoRequested) break;
      }
    } finally {
      _activePass = null;
      completer.complete();
    }
  }

  /// Returns false if the caller should stop draining further chunks this
  /// pass (a network-level failure, vs. a definitive server response).
  Future<bool> _uploadOne(QueuedChunk chunk) async {
    await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateUploading);
    debugPrint('[bodycam] upload starting: recording=${chunk.backendSessionId} chunk=${chunk.chunkNumber} retry=${chunk.retryCount}');

    final file = File(chunk.localFilePath);
    if (!await file.exists()) {
      // The segment file is gone (e.g. user cleared app storage, or a
      // prior run deleted it after a bug) -- this chunk can never be
      // uploaded. Mark it failed permanently rather than retrying forever
      // against a file that will never exist.
      await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateFailed);
      onChunkFailed?.call(chunk, StateError('Local segment file missing: ${chunk.localFilePath}'));
      return true;
    }

    try {
      // Response is a VideoChunkResponse -- not currently needed by the
      // caller beyond confirming success, but decoding it here (implicitly,
      // via ApiClient) means a malformed response still surfaces as a
      // thrown error rather than a silently-wrong "success".
      await ApiClient.postMultipart(
        '/recordings/${chunk.backendSessionId}/chunks',
        fields: {
          'chunk_number': chunk.chunkNumber.toString(),
          if (chunk.durationSeconds != null) 'duration_seconds': chunk.durationSeconds!.toString(),
          'is_last_chunk': chunk.isLastChunk.toString(),
          // Real GPS fix + capture time for this exact segment (see
          // QueuedChunk's doc comment) -- omitted entirely when GPS was
          // unavailable at capture time, never sent as a fabricated 0,0.
          // The backend burns these into the chunk's actual video frames
          // (routers/recordings.py::_burn_watermark_best_effort).
          if (chunk.latitude != null) 'latitude': chunk.latitude!.toString(),
          if (chunk.longitude != null) 'longitude': chunk.longitude!.toString(),
          if (chunk.recordedAt != null) 'recorded_at': chunk.recordedAt!.toIso8601String(),
        },
        file: file,
        fileFieldName: 'file',
        mimeType: _mimeType,
      );
      // 2xx: genuinely uploaded.
      debugPrint('[bodycam] upload SUCCESS: recording=${chunk.backendSessionId} chunk=${chunk.chunkNumber}');
      await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateUploaded);
      onChunkUploaded?.call(chunk.copyWith(uploadState: QueuedChunk.stateUploaded));
      await _deleteLocalFile(chunk);
      return true;
    } on ApiException catch (e) {
      debugPrint('[bodycam] upload HTTP ${e.statusCode} reason=${e.conflictReason}: recording=${chunk.backendSessionId} chunk=${chunk.chunkNumber}');
      if (e.isConflict) {
        // 409 has more than one real meaning -- see
        // backend/app/routers/recordings.py::upload_chunk and
        // ApiException.conflictReason's doc comment. A REAL evidence-loss
        // bug was physically reproduced (real remote-stop-while-locked
        // device test) by treating every 409 as "already uploaded, safe to
        // delete": the final segment of a recording can genuinely finish
        // uploading a moment AFTER the backend has already completed the
        // session (a race independently closed in recording_engine.dart's
        // stop(), but this is the last line of defense for any case that
        // isn't) -- that chunk was NEVER accepted, and deleting its only
        // local copy permanently destroyed evidence footage. The two
        // causes are now told apart via the backend's X-Conflict-Reason
        // header; only a *confirmed* duplicate is safe to delete.
        if (e.conflictReason == 'duplicate_chunk') {
          // The backend has positively confirmed this exact chunk_number
          // already exists server-side (e.g. the previous attempt actually
          // succeeded but the response was lost to a network blip) -- safe
          // to treat as success per §H.
          await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateUploaded);
          onChunkUploaded?.call(chunk.copyWith(uploadState: QueuedChunk.stateUploaded));
          await _deleteLocalFile(chunk);
          return true;
        }
        // 'recording_not_active', or any unrecognized/absent reason (e.g.
        // an older backend without this header): the chunk was NOT
        // confirmed to exist server-side. The evidentiary safety
        // invariant is that a local file is only ever deleted after the
        // application has positively established the backend has it --
        // so this is marked permanently failed (never silently retried
        // forever against a session that can never accept it again) and
        // the local file is explicitly preserved.
        await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateFailed, retryCount: chunk.retryCount + 1);
        onChunkFailed?.call(chunk, e);
        return true;
      }
      if (e.isUnauthorized) {
        // ApiClient.onUnauthorized has already fired (global logout). Put
        // the chunk back to pending so it's retried once the constable
        // logs back in -- do not mark it failed, this isn't the chunk's fault.
        await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.statePending);
        onChunkFailed?.call(chunk, e);
        return false; // stop this pass -- every subsequent call will also 401
      }
      if (e.isPayloadTooLarge || e.isValidationError || e.isForbidden || e.isNotFound) {
        // These are never fixed by retrying the identical bytes: the
        // segment genuinely exceeds the backend's cap, the request is
        // malformed, the recording isn't ours, or it no longer exists.
        await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateFailed, retryCount: chunk.retryCount + 1);
        onChunkFailed?.call(chunk, e);
        return true; // not a network problem -- keep draining the rest of the queue
      }
      // Any other definitive server error (e.g. 500, or the recording is
      // in a non-"recording" status per routers/recordings.py:174-178,
      // which itself returns 409 -- already handled above): retry later.
      await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.statePending, retryCount: chunk.retryCount + 1);
      onChunkFailed?.call(chunk, e);
      return true;
    } catch (e) {
      // Network-level failure (no connectivity, timeout, connection reset,
      // DNS failure, etc.). Uvicorn closing the connection abruptly before
      // consuming a duplicate chunk's body causes a TCP reset here.
      debugPrint('[bodycam] upload NETWORK FAILURE: recording=${chunk.backendSessionId} chunk=${chunk.chunkNumber} error=${e.runtimeType}');
      
      // RECONCILIATION: Check if the chunk was actually accepted by the backend
      // before this connection reset happened.
      try {
        final manifestRaw = await ApiClient.get('/recordings/${chunk.backendSessionId}/chunks');
        final manifest = RecordingManifestResponse.fromJson(manifestRaw as Map<String, dynamic>);
        final exists = manifest.chunks.any((c) => c.chunkNumber == chunk.chunkNumber && c.uploadStatus == 'uploaded');
        if (exists) {
          debugPrint('[bodycam] upload RECONCILED: chunk ${chunk.chunkNumber} was successfully uploaded despite network error');
          await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateUploaded);
          onChunkUploaded?.call(chunk.copyWith(uploadState: QueuedChunk.stateUploaded));
          await _deleteLocalFile(chunk);
          return true; // proceed to the next chunk in the queue
        }
      } catch (manifestError) {
        debugPrint('[bodycam] upload reconciliation failed (genuine offline/error): $manifestError');
      }

      final newCount = chunk.retryCount + 1;
      if (newCount >= _maxRetries) {
        // Prevent an infinite queue lock: if we exceed retries, mark it failed.
        // It remains on disk for future recovery, but stop() can now proceed to
        // upload the final chunk and complete the session.
        await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateFailed, retryCount: newCount);
      } else {
        await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.statePending, retryCount: newCount);
      }
      onChunkFailed?.call(chunk, e);
      return false; // stop this pass -- assume connectivity is down
    }
  }

  /// Deletes the on-disk segment file for a chunk that has just been
  /// durably confirmed uploaded (2xx, or the 409-already-uploaded path
  /// above -- never for a pending/failed/mid-retry chunk). Segments are
  /// otherwise never cleaned up (see recording_engine.dart), so without
  /// this, `<AppDocuments>/recordings/<sessionId>/` grows without bound for
  /// the lifetime of the app. Mirrors the "never let cleanup break the
  /// primary flow" pattern already used for the plugin's own temp file in
  /// recording_engine.dart::_rotateSegment -- a failed delete is logged and
  /// otherwise ignored, never allowed to surface as an upload failure.
  Future<void> _deleteLocalFile(QueuedChunk chunk) async {
    try {
      final file = File(chunk.localFilePath);
      if (await file.exists()) {
        await file.delete();
        debugPrint('[bodycam] deleted uploaded local segment: ${chunk.localFilePath}');
      }
    } catch (e) {
      debugPrint('[bodycam] failed to delete uploaded local segment (non-fatal): ${chunk.localFilePath} error=$e');
    }
  }
}
