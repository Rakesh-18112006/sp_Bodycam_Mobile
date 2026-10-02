import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart' show CameraLensDirection;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One finished, independently-playable recording segment.
///
/// IMPORTANT (see the implementation brief's explicit warning against
/// byte-slicing): this is never produced by cutting bytes out of a larger
/// MP4. Each segment is a *complete, separately-finalized recording* --
/// the native CameraX Recorder closes the MP4 container properly (moov
/// atom written, valid header) before this is reported, so every single
/// segment on its own is a fully valid, independently playable video+audio
/// file. Chunk N is not "part of" a bigger file; it IS a file.
class RecordingSegment {
  final int chunkNumber;
  final File file;
  final double durationSeconds;
  final bool isLastChunk;
  // The real device-local wall-clock time this segment's capture began --
  // used to burn an accurate TIME watermark into the video server-side
  // (see chunk_uploader.dart/recording_service.dart), not the later
  // moment it happens to finish uploading.
  final DateTime startedAt;
  RecordingSegment({
    required this.chunkNumber,
    required this.file,
    required this.durationSeconds,
    required this.isLastChunk,
    required this.startedAt,
  });
}

/// Drives real Android camera hardware to produce a sequence of real
/// video+audio segments -- via native CameraX (see
/// android/.../camera/NativeRecordingManager.kt), not the Flutter `camera`
/// plugin's Dart-side CameraController.
///
/// ARCHITECTURE (background/locked-screen recording): camera ownership
/// lives entirely in native Kotlin, bound to a custom
/// [RecordingLifecycleOwner] that this app controls directly -- NOT to
/// MainActivity's own Lifecycle. This class is now a thin proxy over a
/// MethodChannel to that native code; it holds no CameraController and
/// performs no camera calls itself.
///
/// WHY THIS CHANGED (root cause, confirmed by reading
/// camera_android_camerax 0.6.30's own source): that plugin's
/// ProxyApiRegistrar/ProxyLifecycleProvider bind CameraX directly to
/// MainActivity's Lifecycle and CameraX force-unbinds every camera use
/// case the instant that Activity's onStop() fires -- i.e. the moment the
/// app is backgrounded or the screen locks -- entirely inside the plugin,
/// outside this app's control. No Dart-side or Flutter-engine-hosting
/// workaround changes that; it is a hard architectural limitation of the
/// plugin. Moving the actual camera pipeline into native code bound to a
/// LifecycleOwner this app owns (see RecordingLifecycleOwner.kt) removes
/// that dependency entirely: the camera keeps running for as long as this
/// engine says it should, independent of Activity foreground/background/
/// locked state. The already-existing `flutter_foreground_task` service
/// (see foreground_service.dart) is what keeps the OS from killing the
/// process while backgrounded -- unchanged, still required, not duplicated
/// here.
///
/// Segmentation strategy is unchanged from the previous implementation:
/// rather than recording one unbounded file or slicing an MP4's bytes,
/// the native side stops and immediately restarts its own Recorder every
/// [segmentDuration]. Each stop/start cycle produces one complete,
/// independently valid MP4, with an honest, auditable gap in the recorded
/// timeline at every segment boundary -- Control Room sees exactly which
/// chunk numbers exist and when.
class RecordingEngine {
  static const MethodChannel _channel = MethodChannel('com.policebodycam.recording');

  final Duration segmentDuration;
  // Future<void>, not void: stop() below awaits this callback's completion
  // for the final segment specifically -- see stop()'s doc comment for why
  // that guarantee is load-bearing, not cosmetic.
  final Future<void> Function(RecordingSegment segment) onSegmentReady;
  final void Function(Object error) onError;

  bool _recording = false;
  // One entry per concurrent/repeated stop() call currently awaited (see
  // NativeRecordingManager.kt's mirroring pendingStopResults for why this
  // must be a list, not a single field: a second stop() call arriving
  // before the first has resolved -- e.g. RecordingService.stop() and
  // .cancel() both call this -- would otherwise overwrite the first
  // caller's Completer, leaving it uncompleted forever). Completed
  // together, only once the final segment's onSegmentReady call has
  // itself finished (see _handleNativeCall's isLastChunk branch) -- see
  // stop()'s doc comment.
  final List<Completer<void>> _pendingStops = [];

  RecordingEngine({
    this.segmentDuration = const Duration(seconds: 20),
    required this.onSegmentReady,
    required this.onError,
  });

  bool get isRecording => _recording;

  /// Native CameraX owns the camera; there is no Dart-side CameraController
  /// any more (see NativeRecordingManager.kt's doc comment for why camera
  /// ownership moved to native code). The live on-screen self-view is
  /// instead backed by a second CameraX `Preview` use case bound alongside
  /// the actual recording one, rendered into a Flutter `Texture` via this
  /// id -- set once native `start()` returns, null whenever no engine is
  /// active or the native side couldn't provide one.
  int? get textureId => _textureId;
  int? _textureId;

  /// Initializes native camera capture (this is what triggers the real
  /// Android CAMERA/RECORD_AUDIO permission prompts on first use, via the
  /// same permissions the app already requests -- never bypassed or
  /// pre-granted here) and starts the first segment. Throws on permission
  /// denial or hardware unavailability -- callers must not swallow this
  /// into a fake "started" state.
  Future<void> start({required String localSessionId, CameraLensDirection lensDirection = CameraLensDirection.back}) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final sessionDir = Directory(p.join(docsDir.path, 'recordings', localSessionId));
    await sessionDir.create(recursive: true);

    _channel.setMethodCallHandler(_handleNativeCall);

    debugPrint('[bodycam] starting native recording, session=$localSessionId dir=${sessionDir.path}');
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('start', {
      'sessionDir': sessionDir.path,
      'lensDirection': lensDirection == CameraLensDirection.front ? 'front' : 'back',
      'segmentDurationMs': segmentDuration.inMilliseconds,
    });
    _textureId = (result?['textureId'] as num?)?.toInt();
    _recording = true;
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'segmentReady':
        final map = Map<Object?, Object?>.from(call.arguments as Map);
        final isLast = map['isLastChunk'] as bool;
        // Awaited deliberately (see this class's onSegmentReady doc
        // comment): for the final segment, stop() must not let its caller
        // proceed until this -- which enqueues the chunk into
        // OfflineQueueService -- has genuinely finished, not merely been
        // kicked off.
        await onSegmentReady(RecordingSegment(
          chunkNumber: map['chunkNumber'] as int,
          file: File(map['path'] as String),
          durationSeconds: (map['durationSeconds'] as num).toDouble(),
          isLastChunk: isLast,
          startedAt: DateTime.fromMillisecondsSinceEpoch(map['startedAtMillis'] as int),
        ));
        if (isLast) {
          _recording = false;
          _textureId = null;
          _resolvePendingStops();
        }
        break;
      case 'recordingError':
        onError(StateError(call.arguments?.toString() ?? 'native recording error'));
        // If a stop() is currently awaited, this error report IS its
        // resolution: NativeRecordingManager's own isLast computation
        // (mirrored by stop()'s pendingStopResults) treats a failed
        // finalize of the final segment the same as a successful one for
        // the purpose of unblocking a pending stop -- only one finalize is
        // ever in flight at a time (see rotating's role there), so a
        // recordingError arriving while stop() is waiting can only be for
        // the segment stop() is waiting on. Without this, a real
        // Finalize-with-error on the final segment would leave every
        // pending stop() uncompleted forever, hanging indefinitely.
        if (_pendingStops.isNotEmpty) {
          _recording = false;
          _textureId = null;
          _resolvePendingStops();
        }
        break;
    }
    return null;
  }

  void _resolvePendingStops() {
    final toResolve = List<Completer<void>>.from(_pendingStops);
    _pendingStops.clear();
    for (final completer in toResolve) {
      if (!completer.isCompleted) completer.complete();
    }
  }

  /// No-op by design under this architecture (see this class's top doc
  /// comment): the native camera pipeline is bound to its own
  /// Activity-independent LifecycleOwner, so it never needs pausing around
  /// backgrounding. Kept as a real, callable method -- NOT removed -- so
  /// home_screen.dart's existing WidgetsBindingObserver call site needs no
  /// changes, exactly as the architecture brief required.
  Future<void> pauseForBackground() async {}

  /// No-op by design -- see [pauseForBackground].
  Future<void> resumeFromBackground() async {}

  /// Requests a graceful stop: the current segment is finalized
  /// (is_last_chunk=true) natively rather than discarded, so a
  /// manually-stopped recording still ends with a complete, playable final
  /// chunk instead of a truncated/corrupt one. Idempotent -- safe to call
  /// even if nothing is currently recording.
  ///
  /// REAL DATA LOSS BUG FIXED HERE, physically reproduced via a real
  /// remote-stop-while-locked test: this used to just await the native
  /// "stop" MethodChannel call, which (before NativeRecordingManager.kt's
  /// matching fix) resolved immediately after merely REQUESTING the native
  /// stop, before CameraX's asynchronous Finalize event for the final
  /// segment had actually fired. That let the caller (RecordingService.stop())
  /// proceed to pump the upload queue and call the backend's /complete
  /// using only the chunks that existed at that instant -- completing the
  /// session one chunk early. The true final chunk then uploaded moments
  /// later to an already-completed session, was rejected, and (compounded
  /// by a separate chunk_uploader.dart bug, also fixed alongside this) its
  /// only copy was deleted -- permanently losing that segment's footage.
  ///
  /// The fix has two cooperating halves: NativeRecordingManager.kt now
  /// holds the "stop" MethodChannel result open until the real Finalize
  /// event, AND -- belt and suspenders, so this guarantee does not depend
  /// on cross-message platform-channel ordering assumptions -- this method
  /// now waits on [_pendingStop], which [_handleNativeCall] only completes
  /// once the final segment's [onSegmentReady] call has itself finished
  /// (i.e. the chunk is genuinely enqueued in OfflineQueueService, not
  /// merely reported). Purely event-driven off the real Finalize callback;
  /// no fixed delay, sleep, or poll of any kind.
  Future<void> stop() async {
    if (!_recording) return;
    final completer = Completer<void>();
    _pendingStops.add(completer);
    unawaited(_channel.invokeMethod('stop').catchError((Object e) {
      if (!completer.isCompleted) completer.completeError(e);
      return null;
    }));
    await completer.future;
  }

  Future<void> dispose() async {
    if (!_recording) return;
    try {
      await stop();
    } catch (_) {
      // Best-effort teardown -- never throw out of dispose().
    }
    _recording = false;
  }
}
