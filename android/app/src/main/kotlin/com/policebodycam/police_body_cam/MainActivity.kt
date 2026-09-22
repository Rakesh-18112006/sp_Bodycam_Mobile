package com.policebodycam.police_body_cam

import android.Manifest
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.policebodycam.police_body_cam.camera.NativeRecordingManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Real (native) volume-button double-press AND long-press detection for
 * the state-aware emergency recording toggle (see
 * lib/screens/home_screen.dart::_handleEmergencyTrigger for the Dart-side
 * state machine: not-recording -> starts an emergency recording (VOLUME_UP
 * = front camera, VOLUME_DOWN = back camera); recording -> any recognized
 * double/long trigger, either key, stops it). Both gesture kinds are
 * reported identically as a single `volumeButtonTrigger` call with a
 * `key`/`kind` payload; this Activity is only a thin adapter over
 * [VolumeGestureDetector], which holds the actual (framework-independent,
 * deterministically unit-tested -- see VolumeGestureDetectorTest)
 * double-press/long-press/key-repeat-filtering logic.
 *
 * HONEST LIMITATION, stated up front rather than discovered later:
 * `dispatchKeyEvent` only ever fires while THIS Activity has input focus
 * -- i.e. the app is in the foreground and on-screen. It does NOT fire
 * when the screen is off, the app is backgrounded, or another app/the
 * lock screen has focus. Investigated: no ordinary (non-accessibility,
 * non-device-owner, non-root) Android mechanism delivers global hardware
 * volume-key events to a backgrounded app's Activity -- a plain
 * foreground Service (like ForegroundRecordingService) has no window and
 * receives no input events regardless of its notification/process
 * lifetime. The one theoretical alternative,
 * MediaSessionCompat.setPlaybackToRemote(VolumeProviderCompat), requires
 * this app to masquerade as "currently playing media" to have any chance
 * of the OS routing volume keys to it while backgrounded, which is
 * neither reliable (Android/OEMs are free to route volume keys to
 * whichever app they consider "active media" instead) nor honest UX for
 * an app that isn't actually playing media -- treated as exactly the kind
 * of "unsafe hack" this feature must not resort to, so it was not
 * implemented. The always-available fallback is the in-app "Emergency
 * Record" button, which works regardless of this limitation.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.policebodycam.police_body_cam/volume_trigger"
    private var methodChannel: MethodChannel? = null
    private val handler = Handler(Looper.getMainLooper())

    // Real (never bypassed/pre-granted) CAMERA/RECORD_AUDIO runtime
    // permission request for native recording. Previously the Flutter
    // `camera` plugin's own CameraPermissionsManager triggered this
    // automatically the first time CameraController.initialize() ran; now
    // that NativeRecordingManager owns the camera directly (see that
    // class's doc comment), this Activity must request them itself before
    // the first recording ever starts. Once granted, Android remembers the
    // grant permanently (until the user revokes it), so this only prompts
    // on a genuine first use, exactly like the old behavior. A recording
    // "start" always originates from a foreground user action, an
    // in-app remote-command handler, or the notification button -- all of
    // which run with this Activity attached, so requesting here (rather
    // than from a background/locked context, where no permission dialog
    // could be shown anyway) is always the right place.
    private val recordingPermissions = arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
    private val requestCodeRecordingPermissions = 4201
    private var pendingRecordingStart: Pair<Map<*, *>, MethodChannel.Result>? = null

    private val detector = VolumeGestureDetector(
        now = { System.currentTimeMillis() },
        schedule = { delayMs, run ->
            val runnable = Runnable { run() }
            handler.postDelayed(runnable, delayMs)
            VolumeGestureDetector.Cancellable { handler.removeCallbacks(runnable) }
        },
        onTrigger = { keyIsVolumeUp, kind ->
            val key = if (keyIsVolumeUp) "volume_up" else "volume_down"
            methodChannel?.invokeMethod("volumeButtonTrigger", mapOf("key" to key, "kind" to kind))
        },
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)

        // Background/locked-screen recording (see
        // camera/NativeRecordingManager.kt and camera/RecordingLifecycleOwner.kt
        // for the full architecture and the root cause this replaces). This
        // channel is bidirectional: Dart calls "start"/"stop" on it, and
        // NativeRecordingManager independently calls back into it with
        // "segmentReady"/"recordingError" whenever a segment finishes --
        // including while this Activity is stopped/backgrounded, since the
        // camera pipeline itself no longer depends on this Activity's own
        // lifecycle at all. attach() is (re-)called every time this method
        // runs (matches camera_android_camerax's own Activity-reattachment
        // pattern) so the manager always reports to the latest live channel.
        val recordingChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.policebodycam.recording")
        NativeRecordingManager.attach(applicationContext, recordingChannel)
        recordingChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val args = call.arguments as Map<*, *>
                    if (hasRecordingPermissions()) {
                        startNativeRecording(args, result)
                    } else {
                        pendingRecordingStart = Pair(args, result)
                        ActivityCompat.requestPermissions(this, recordingPermissions, requestCodeRecordingPermissions)
                    }
                }
                "stop" -> NativeRecordingManager.stop(result)
                // The native camera pipeline is bound to its own
                // Activity-independent LifecycleOwner (see
                // RecordingLifecycleOwner's doc comment) precisely so it
                // never needs pausing/resuming around backgrounding or
                // screen-lock -- these are accepted as no-ops so
                // home_screen.dart's existing WidgetsBindingObserver calls
                // (kept unchanged, per the architecture brief's explicit
                // instruction not to remove them) need no adaptation.
                "pauseForBackground", "resumeFromBackground" -> result.success(null)
                else -> result.notImplemented()
            }
        }
    }

    private fun hasRecordingPermissions(): Boolean = recordingPermissions.all {
        ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
    }

    private fun startNativeRecording(args: Map<*, *>, result: MethodChannel.Result) {
        NativeRecordingManager.start(
            sessionDirPath = args["sessionDir"] as String,
            lensDirection = args["lensDirection"] as String,
            segDurationMs = (args["segmentDurationMs"] as Number).toLong(),
            result = result,
        )
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != requestCodeRecordingPermissions) return
        val (args, result) = pendingRecordingStart ?: return
        pendingRecordingStart = null
        if (hasRecordingPermissions()) {
            startNativeRecording(args, result)
        } else {
            result.error("PERMISSION_DENIED", "Camera/microphone permission was denied", null)
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val isVolumeKey = event.keyCode == KeyEvent.KEYCODE_VOLUME_UP || event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN
        if (!isVolumeKey) return super.dispatchKeyEvent(event)
        val keyIsVolumeUp = event.keyCode == KeyEvent.KEYCODE_VOLUME_UP

        when (event.action) {
            KeyEvent.ACTION_DOWN -> {
                if (detector.onKeyDown(keyIsVolumeUp, event.repeatCount)) return true
            }
            KeyEvent.ACTION_UP -> detector.onKeyUp(keyIsVolumeUp)
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        // Cancels any pending long-press timer so it can never fire (and
        // invoke a MethodChannel that's about to be torn down) after the
        // Activity is gone.
        detector.dispose()
        super.onDestroy()
    }
}
