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
///   - a 409 on retry means "already uploaded server-side" -- treat as success
///   - never invent/guess a mime type: this app only ever produces
///     video/mp4 segments (see recording_engine.dart), so that's the only
///     mime type sent, and it's one of the backend's ALLOWED_MIME_TO_EXT
///     values, content-sniffed and verified server-side regardless.
class ChunkUploader {
  static const _mimeType = 'video/mp4';
  static const _maxRetries = 8;

  final void Function(QueuedChunk chunk)? onChunkUploaded;
  final void Function(QueuedChunk chunk, Object error)? onChunkFailed;

  bool _draining = false;

  ChunkUploader({this.onChunkUploaded, this.onChunkFailed});

  /// Uploads every currently-pending/failed chunk that has a known backend
  /// session id, in chunk_number order per session. Stops early (rather
  /// than burning through retries) the moment a network-level failure is
  /// seen, on the assumption connectivity just dropped -- the next trigger
  /// (reconnect, next segment finished, periodic retry timer) will resume
  /// from exactly where this left off, because state is only ever mutated
  /// after a definitive server response.
  Future<void> drain() async {
    if (_draining) {
      debugPrint('[bodycam] drain() skipped -- already draining');
      return;
    }
    _draining = true;
    try {
      final pending = await OfflineQueueService.pendingChunks();
      debugPrint('[bodycam] drain() starting: ${pending.length} pending chunk(s) across all sessions');
      for (final chunk in pending) {
        if (chunk.backendSessionId == null) continue; // recording session not yet registered server-side
        if (chunk.retryCount >= _maxRetries && chunk.uploadState == QueuedChunk.stateFailed) continue; // give up silently retrying; still visible to the UI as failed
        final keepGoing = await _uploadOne(chunk);
        if (!keepGoing) break; // network-level failure -- stop this pass
      }
    } finally {
      _draining = false;
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
        },
        file: file,
        fileFieldName: 'file',
        mimeType: _mimeType,
      );
      // 2xx: genuinely uploaded.
      debugPrint('[bodycam] upload SUCCESS: recording=${chunk.backendSessionId} chunk=${chunk.chunkNumber}');
      await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateUploaded);
      onChunkUploaded?.call(chunk.copyWith(uploadState: QueuedChunk.stateUploaded));
      return true;
    } on ApiException catch (e) {
      debugPrint('[bodycam] upload HTTP ${e.statusCode}: recording=${chunk.backendSessionId} chunk=${chunk.chunkNumber}');
      if (e.isConflict) {
        // 409: this exact chunk_number was already accepted server-side
        // (e.g. the previous attempt actually succeeded but the response
        // was lost to a network blip). Per §H, treat as success.
        await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.stateUploaded);
        onChunkUploaded?.call(chunk.copyWith(uploadState: QueuedChunk.stateUploaded));
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
      // DNS failure, etc.) -- per §H/§O, retry the SAME chunk_number later.
      // Never treated as the chunk's fault; retryCount still increments so
      // a permanently-unreachable file (see _maxRetries above) doesn't
      // retry forever, but a genuinely-offline device isn't punished for
      // the time it spends offline.
      debugPrint('[bodycam] upload NETWORK FAILURE: recording=${chunk.backendSessionId} chunk=${chunk.chunkNumber} error=${e.runtimeType}');
      await OfflineQueueService.updateChunkState(chunk.id!, uploadState: QueuedChunk.statePending, retryCount: chunk.retryCount + 1);
      onChunkFailed?.call(chunk, e);
      return false; // stop this pass -- assume connectivity is down
    }
  }
}
