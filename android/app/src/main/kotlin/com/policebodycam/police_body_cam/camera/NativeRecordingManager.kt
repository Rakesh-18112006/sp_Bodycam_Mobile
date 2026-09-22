package com.policebodycam.police_body_cam.camera

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Owns the actual CameraX camera pipeline for body-camera recording.
 *
 * This is a process-wide singleton, deliberately NOT held inside
 * MainActivity and NOT constructed with an Activity Context -- it is bound
 * to [RecordingLifecycleOwner] (see that class's doc comment for why),
 * using the application Context throughout, so a recording started here
 * keeps running -- real camera capture, real segment files -- for as long
 * as the process is alive, independent of MainActivity being backgrounded,
 * stopped, or even destroyed/recreated. What keeps the PROCESS itself alive
 * while backgrounded is the existing `flutter_foreground_task`-based
 * foreground service (see foreground_service.dart), which already declares
 * and starts with the camera|microphone|location foregroundServiceType for
 * the whole logged-in session -- this class does not duplicate that; it
 * only fixes what CAMERA lifecycle that already-running process is allowed
 * to keep doing.
 *
 * Segment rotation mirrors the previous Dart-side RecordingEngine exactly
 * (stop the current Recording, finalize it as one complete independently-
 * playable MP4, start a new one) -- including its most important lesson,
 * physically learned the hard way there: never start a new segment's
 * recording while the previous one's finalize/teardown is still in flight.
 * Here that means beginSegment() is only ever called from
 * handleRecordEvent()'s Finalize branch (after CameraX has told us the
 * previous Recording is genuinely closed), never immediately after calling
 * `.stop()` on it.
 *
 * File naming (`segment_NNNNNN.mp4` inside the session directory Dart
 * already creates via getApplicationDocumentsDirectory()) is kept byte-for-
 * byte identical to the old Dart implementation so chunk_uploader.dart /
 * offline_queue_service.dart need no changes at all -- they only ever see a
 * finished File on disk plus the same RecordingSegment-shaped metadata,
 * never anything camera-specific.
 */
object NativeRecordingManager {
    private const val TAG = "NativeRecordingManager"

    private var appContext: Context? = null
    private var channel: MethodChannel? = null

    private var lifecycleOwner: RecordingLifecycleOwner? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var activeRecording: Recording? = null

    private var sessionDir: String? = null
    private var segmentDurationMs: Long = 20000
    private var segmentIndex = 0
    private var segmentStartedAtMillis = 0L
    private var stopRequested = false
    private var rotating = false

    /**
     * MethodChannel [MethodChannel.Result]s from Dart's "stop" call(s) that
     * are held open -- NOT resolved -- until the currently-finalizing
     * segment's real [VideoRecordEvent.Finalize] arrives (see
     * [handleRecordEvent]'s isLast branch, the only place these are ever
     * resolved). A list, not a single field, because [stop] is idempotent
     * and may legitimately be called more than once (e.g. RecordingService's
     * own stop()/cancel() both call it) while a stop is already in flight --
     * every caller's result gets resolved together once the real finalize
     * happens, none silently dropped.
     *
     * ROOT CAUSE this exists to fix (physically reproduced via a real
     * remote-STOP-while-locked test, not theorized): CameraX's
     * `Recording.stop()` is asynchronous -- it only *requests* finalization;
     * the actual `VideoRecordEvent.Finalize` (and this manager's own
     * "segmentReady" report to Dart for that final segment) arrives later,
     * on its own executor callback. The previous version of [stop] called
     * `result.success(null)` immediately after requesting the stop, without
     * waiting for that Finalize -- so Dart's `RecordingService.stop()`
     * (which awaits the "stop" MethodChannel call and then immediately
     * pumps the upload queue and calls the backend's /complete) could, and
     * during that test physically did, run to completion BEFORE the final
     * segment's file even existed yet. The backend correctly completed the
     * RecordingSession with only the chunks that existed at that instant;
     * the true final chunk then uploaded a moment later to an already-
     * completed session, was rejected, and -- compounded by a separate bug
     * in chunk_uploader.dart's 409 handling (see that file) -- its local
     * copy was deleted, permanently losing that segment's footage.
     *
     * Holding the "stop" result open until Finalize restores the same
     * end-to-end guarantee the old Dart CameraController-based engine had
     * (its stop() awaited stopVideoRecording() synchronously before
     * returning) without reintroducing the STOPPING-state crash race: this
     * is purely event-driven off CameraX's own Finalize callback, never a
     * fixed delay/poll/sleep.
     */
    private val pendingStopResults = mutableListOf<MethodChannel.Result>()

    private val mainHandler = Handler(Looper.getMainLooper())
    private var rotateRunnable: Runnable? = null

    val isRecording: Boolean
        get() = activeRecording != null

    /**
     * Re-registers the MethodChannel this manager reports segment-ready/
     * error events on. Called from MainActivity.configureFlutterEngine(),
     * which can run again (e.g. after a config change) -- reassigning here
     * each time (last-attached wins) mirrors exactly how
     * camera_android_camerax's own ProxyApiRegistrar re-points its Context
     * on re-attachment, for the same reason: the underlying FlutterEngine
     * and its BinaryMessenger stay valid across this, so simply pointing at
     * the latest channel instance is correct and sufficient.
     */
    fun attach(context: Context, methodChannel: MethodChannel) {
        appContext = context.applicationContext
        channel = methodChannel
    }

    fun start(sessionDirPath: String, lensDirection: String, segDurationMs: Long, result: MethodChannel.Result) {
        val context = appContext
        if (context == null) {
            result.error("NOT_ATTACHED", "NativeRecordingManager.attach() was never called", null)
            return
        }
        if (isRecording) {
            result.success(mapOf("alreadyRecording" to true))
            return
        }

        sessionDir = sessionDirPath
        segmentDurationMs = segDurationMs
        segmentIndex = 0
        stopRequested = false
        rotating = false

        val owner = RecordingLifecycleOwner()
        lifecycleOwner = owner
        owner.start()

        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener({
            try {
                val provider = providerFuture.get()
                cameraProvider = provider

                val selector = if (lensDirection == "front") {
                    CameraSelector.DEFAULT_FRONT_CAMERA
                } else {
                    CameraSelector.DEFAULT_BACK_CAMERA
                }
                val qualitySelector = QualitySelector.from(
                    Quality.HD,
                    FallbackStrategy.higherQualityOrLowerThan(Quality.SD),
                )
                val recorder = Recorder.Builder().setQualitySelector(qualitySelector).build()
                val capture = VideoCapture.withOutput(recorder)
                videoCapture = capture

                provider.unbindAll()
                provider.bindToLifecycle(owner, selector, capture)

                beginSegment()
                result.success(mapOf("started" to true))
            } catch (e: Exception) {
                Log.e(TAG, "camera bind failed", e)
                teardown()
                result.error("CAMERA_BIND_FAILED", e.message, null)
            }
        }, ContextCompat.getMainExecutor(context))
    }

    fun stop(result: MethodChannel.Result) {
        if (!isRecording) {
            result.success(null)
            return
        }
        stopRequested = true
        rotateRunnable?.let { mainHandler.removeCallbacks(it) }
        rotateRunnable = null
        pendingStopResults.add(result)
        if (!rotating) {
            rotating = true
            activeRecording?.stop()
        }
        // Deliberately NOT resolved here -- see pendingStopResults' doc
        // comment. Resolved only once the real Finalize event for this
        // final segment arrives, in handleRecordEvent()'s isLast branch.
    }

    private fun beginSegment() {
        val context = appContext ?: return
        val dir = sessionDir ?: return
        val capture = videoCapture ?: return
        if (stopRequested) {
            teardown()
            return
        }

        segmentIndex += 1
        segmentStartedAtMillis = System.currentTimeMillis()
        val fileName = "segment_" + segmentIndex.toString().padStart(6, '0') + ".mp4"
        val file = File(dir, fileName)

        val outputOptions = FileOutputOptions.Builder(file).build()
        val pending = capture.output.prepareRecording(context, outputOptions).withAudioEnabled()
        val thisSegmentIndex = segmentIndex
        val thisSegmentStartedAt = segmentStartedAtMillis
        activeRecording = pending.start(ContextCompat.getMainExecutor(context)) { event ->
            handleRecordEvent(event, file, thisSegmentIndex, thisSegmentStartedAt)
        }

        val runnable = Runnable { rotateSegment() }
        rotateRunnable = runnable
        mainHandler.postDelayed(runnable, segmentDurationMs)
    }

    private fun rotateSegment() {
        if (rotating) return // a stop() already in flight is handling this
        if (activeRecording == null) return
        rotating = true
        activeRecording?.stop()
        // The next segment (or final teardown, if stopRequested) is started
        // from handleRecordEvent()'s Finalize branch below, once THIS
        // segment is genuinely closed -- see this file's top doc comment
        // for why starting it here instead would reintroduce the exact
        // "onConfigured() in a STOPPING state" class of race this
        // architecture exists to eliminate.
    }

    private fun handleRecordEvent(event: VideoRecordEvent, file: File, chunkNumber: Int, startedAtMillis: Long) {
        if (event !is VideoRecordEvent.Finalize) return
        rotating = false
        rotateRunnable?.let { mainHandler.removeCallbacks(it) }
        rotateRunnable = null

        val hadError = event.hasError()
        val isLast = stopRequested
        val durationSeconds = (System.currentTimeMillis() - startedAtMillis) / 1000.0

        if (hadError) {
            Log.e(TAG, "segment $chunkNumber finalize error: ${event.error}", event.cause)
            channel?.invokeMethod(
                "recordingError",
                "segment $chunkNumber finalize error code=${event.error}: ${event.cause?.message}",
            )
        } else {
            channel?.invokeMethod(
                "segmentReady",
                mapOf(
                    "chunkNumber" to chunkNumber,
                    "path" to file.absolutePath,
                    "durationSeconds" to durationSeconds,
                    "isLastChunk" to isLast,
                    "startedAtMillis" to startedAtMillis,
                ),
            )
        }

        if (isLast) {
            teardown()
            // Resolve every "stop" call that was waiting on THIS segment's
            // finalize -- see pendingStopResults' doc comment. Only now,
            // after the segment above has already been reported to Dart
            // via "segmentReady"/"recordingError", is it safe to let
            // Dart's RecordingService.stop() proceed to pump the upload
            // queue and complete the backend session.
            val resultsToResolve = pendingStopResults.toList()
            pendingStopResults.clear()
            resultsToResolve.forEach { it.success(null) }
        } else {
            beginSegment()
        }
    }

    private fun teardown() {
        try {
            cameraProvider?.unbindAll()
        } catch (e: Exception) {
            Log.e(TAG, "unbindAll failed (non-fatal, segments already saved)", e)
        }
        lifecycleOwner?.destroy()
        lifecycleOwner = null
        videoCapture = null
        activeRecording = null
        cameraProvider = null
        rotating = false
    }
}
