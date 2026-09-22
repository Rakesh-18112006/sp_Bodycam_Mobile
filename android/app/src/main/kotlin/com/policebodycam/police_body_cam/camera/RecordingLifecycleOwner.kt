package com.policebodycam.police_body_cam.camera

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry

/**
 * A CameraX [LifecycleOwner] that is deliberately NOT bound to MainActivity
 * or any other Activity.
 *
 * ROOT CAUSE this exists to fix (confirmed by reading camera_android_camerax
 * 0.6.30's own source -- ProxyLifecycleProvider.java / ProxyApiRegistrar.java):
 * the Flutter `camera` plugin registers a LifecycleOwner that forwards
 * MainActivity's own onStop() straight into CameraX as Lifecycle.Event.ON_STOP,
 * and CameraX force-unbinds every bound use case (Preview/VideoCapture/etc.)
 * the instant its bound LifecycleOwner leaves STARTED -- entirely inside the
 * plugin/CameraX, outside this app's control. That is the actual, structural
 * reason camera capture previously paused on Home-press/screen-lock; it is
 * not a bug in this app's Dart code and cannot be fixed by Dart-side changes
 * alone (see recording_engine.dart's historical comments for the full
 * investigation).
 *
 * CameraX's own contract only requires SOME LifecycleOwner, not specifically
 * an Activity -- androidx.lifecycle.LifecycleRegistry is usable standalone by
 * any object. This class's state is driven manually by
 * NativeRecordingManager, moved to STARTED/RESUMED when a recording begins
 * and held there for as long as the recording is active, regardless of
 * whether MainActivity is foregrounded, backgrounded, or the screen is
 * locked -- so CameraX never sees a reason to unbind. It is only torn down
 * (ON_DESTROY) when the recording is explicitly stopped.
 *
 * A fresh instance is created per recording rather than reused, because
 * LifecycleRegistry cannot leave the terminal DESTROYED state once reached.
 *
 * All state transitions MUST happen on the main thread (LifecycleRegistry's
 * own requirement) -- callers are responsible for that; every call site in
 * NativeRecordingManager already runs on the main thread (Flutter platform
 * channel calls are dispatched there, and CameraX's own listeners here are
 * registered with ContextCompat.getMainExecutor()).
 */
class RecordingLifecycleOwner : LifecycleOwner {
    private val registry = LifecycleRegistry(this)

    override val lifecycle: Lifecycle
        get() = registry

    fun start() {
        registry.handleLifecycleEvent(Lifecycle.Event.ON_CREATE)
        registry.handleLifecycleEvent(Lifecycle.Event.ON_START)
        registry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME)
    }

    fun destroy() {
        registry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE)
        registry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
        registry.handleLifecycleEvent(Lifecycle.Event.ON_DESTROY)
    }
}
