package com.policebodycam.police_body_cam

import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Real (native) volume-button double-press detection for the emergency
 * recording trigger (implementation brief §13).
 *
 * HONEST LIMITATION, stated up front rather than discovered later:
 * `dispatchKeyEvent` only ever fires while THIS Activity has input focus
 * -- i.e. the app is in the foreground and on-screen. It does NOT fire
 * when the screen is off, the app is backgrounded, or another app/the
 * lock screen has focus. True system-wide hardware-key interception in
 * those states requires an AccessibilityService (or, on some OEMs, a
 * device-admin/dedicated-kiosk configuration) -- a materially different
 * and more invasive Android feature that is intentionally NOT implemented
 * here; it was out of scope for this pass and is called out explicitly in
 * the final report rather than silently assumed to work. The always-available
 * fallback is the in-app "Emergency Record" button, which works regardless
 * of this limitation.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.policebodycam.police_body_cam/volume_trigger"
    private var methodChannel: MethodChannel? = null

    private var lastVolumeDownPressAt: Long = 0
    private val doublePressWindowMs = 600L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN && event.action == KeyEvent.ACTION_DOWN) {
            val now = System.currentTimeMillis()
            if (now - lastVolumeDownPressAt in 1..doublePressWindowMs) {
                lastVolumeDownPressAt = 0
                methodChannel?.invokeMethod("volumeButtonDoublePress", null)
                // Consume the event so the double-press doesn't also nudge
                // system media volume during an emergency trigger.
                return true
            }
            lastVolumeDownPressAt = now
        }
        return super.dispatchKeyEvent(event)
    }
}
