package com.policebodycam.police_body_cam

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Deterministic tests for VolumeGestureDetector's double-press/long-press
 * state machine. A physical device could not be used for genuine
 * long-press timing (raw `sendevent` requires root; `adb input keyevent
 * --longpress` only injects a synthetic key-repeat, not a real timed
 * hold -- see the physical-verification report). This suite instead
 * proves the state machine deterministically with a fake clock and a
 * fake "scheduler" that only ever runs a callback when the test
 * explicitly advances time past it -- no Robolectric, emulator, or root
 * needed. Run with `./gradlew testDebugUnitTest`.
 */
class VolumeGestureDetectorTest {

    /** Records (fireAt, callback) pairs; advancing the fake clock past fireAt runs them, in schedule order. */
    private class FakeScheduler {
        private data class Pending(val fireAt: Long, val run: () -> Unit, var cancelled: Boolean = false)
        private val pending = mutableListOf<Pending>()
        var clock = 0L

        fun schedule(delayMs: Long, run: () -> Unit): VolumeGestureDetector.Cancellable {
            val p = Pending(clock + delayMs, run)
            pending += p
            return VolumeGestureDetector.Cancellable { p.cancelled = true }
        }

        fun advanceTo(t: Long) {
            clock = t
            val due = pending.filter { !it.cancelled && it.fireAt <= clock }
            pending.removeAll(due)
            due.forEach { it.run() }
        }
    }

    private lateinit var scheduler: FakeScheduler
    private val triggers = mutableListOf<Pair<Boolean, String>>() // (keyIsVolumeUp, kind)
    private lateinit var detector: VolumeGestureDetector

    @Before
    fun setUp() {
        scheduler = FakeScheduler()
        triggers.clear()
        detector = VolumeGestureDetector(
            doublePressWindowMs = 600L,
            longPressThresholdMs = 600L,
            now = { scheduler.clock },
            schedule = { delayMs, run -> scheduler.schedule(delayMs, run) },
            onTrigger = { up, kind -> triggers += up to kind },
        )
    }

    // Items 1+2: long press fires "long" for the correct key. (Which
    // camera each key starts is Dart-side mapping, already unit-tested in
    // volume_trigger_logic_test.dart -- this proves the NATIVE layer
    // reports the correct key/kind it's built on.)
    @Test
    fun `1 - held UP past threshold fires exactly one long trigger for volume_up`() {
        detector.onKeyDown(keyIsVolumeUp = true, repeatCount = 0)
        scheduler.advanceTo(600)
        assertEquals(listOf(true to "long"), triggers)
    }

    @Test
    fun `2 - held DOWN past threshold fires exactly one long trigger for volume_down`() {
        detector.onKeyDown(keyIsVolumeUp = false, repeatCount = 0)
        scheduler.advanceTo(600)
        assertEquals(listOf(false to "long"), triggers)
    }

    // Items 3+4: "recording -> stop" is Dart-side decision logic (already
    // covered by decideVolumeTriggerAction's own tests in
    // test/utils/volume_trigger_logic_test.dart) -- this detector has no
    // concept of recording state at all, only of which key/gesture fired,
    // which is what's asserted throughout this file.

    // Item 5: OS auto-repeat events during a long press must never add
    // extra actions or fire the trigger early.
    @Test
    fun `5 - OS auto-repeat events during a held press never produce extra or early triggers`() {
        detector.onKeyDown(keyIsVolumeUp = true, repeatCount = 0)
        for (r in 1..5) {
            val consumed = detector.onKeyDown(keyIsVolumeUp = true, repeatCount = r)
            assertEquals("a repeat event must never be consumed", false, consumed)
        }
        assertTrue("no trigger should fire before the threshold", triggers.isEmpty())
        scheduler.advanceTo(600)
        assertEquals("exactly one action despite 5 repeat events", listOf(true to "long"), triggers)
    }

    // Item 6: release before the long-press threshold -> no long action.
    @Test
    fun `6 - release before the long-press threshold produces no action`() {
        detector.onKeyDown(keyIsVolumeUp = true, repeatCount = 0)
        scheduler.advanceTo(300)
        detector.onKeyUp(keyIsVolumeUp = true)
        scheduler.advanceTo(1000)
        assertTrue(triggers.isEmpty())
    }

    // Item 7: two presses within the window -> exactly one double action.
    @Test
    fun `7 - two presses within the double-press window fire exactly one double trigger`() {
        detector.onKeyDown(keyIsVolumeUp = true, repeatCount = 0)
        scheduler.advanceTo(250)
        val consumedSecond = detector.onKeyDown(keyIsVolumeUp = true, repeatCount = 0)
        assertTrue("the second press of a genuine double must be consumed", consumedSecond)
        assertEquals(listOf(true to "double"), triggers)
        scheduler.advanceTo(900) // the first press's pending long-press timer must have been cancelled by the second down
        assertEquals("no extra long trigger must follow", listOf(true to "double"), triggers)
    }

    // Item 8: a long press must never also become eligible to complete a
    // (now stale) double press.
    @Test
    fun `8 - a press right after a fired long press starts its own fresh window, never completing a stale double`() {
        detector.onKeyDown(keyIsVolumeUp = true, repeatCount = 0)
        scheduler.advanceTo(600) // long fires
        assertEquals(listOf(true to "long"), triggers)
        detector.onKeyUp(keyIsVolumeUp = true)
        val consumed = detector.onKeyDown(keyIsVolumeUp = true, repeatCount = 0)
        assertEquals("must not be consumed as completing a double", false, consumed)
        assertEquals("still only the one long trigger", listOf(true to "long"), triggers)
    }

    // Item 9: dispose() cancels every pending timer.
    @Test
    fun `9 - dispose cancels a pending long-press timer so it never fires`() {
        detector.onKeyDown(keyIsVolumeUp = true, repeatCount = 0)
        detector.dispose()
        scheduler.advanceTo(600)
        assertTrue("a disposed detector must never fire a queued long press", triggers.isEmpty())
    }

    // Item 10: Activity lifecycle cleanup (MainActivity.onDestroy calling
    // detector.dispose()) is verified by direct code inspection of
    // MainActivity.kt's onDestroy override -- CODE VERIFIED, not exercised
    // by this plain-Kotlin suite, which deliberately has no
    // Android/Activity dependency to test against.

    @Test
    fun `independent keys never interfere with each other's double-press timing`() {
        detector.onKeyDown(keyIsVolumeUp = true, repeatCount = 0)
        scheduler.advanceTo(100)
        val consumed = detector.onKeyDown(keyIsVolumeUp = false, repeatCount = 0)
        assertEquals("a DOWN of the OTHER key must never complete this key's double", false, consumed)
        assertTrue(triggers.isEmpty())
    }
}
