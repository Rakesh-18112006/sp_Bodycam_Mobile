"""
Generates the four short, locally-synthesized UI feedback tones used by
AudioFeedbackService (see lib/services/audio_feedback_service.dart). Pure
sine-wave synthesis via Python's stdlib only (wave/struct/math) -- no
external audio libraries, no downloaded/copyrighted material. Re-run this
script (`python generate_tones.py`) if the tones ever need to be
regenerated; the .wav outputs are what actually ships in the app.

Design (see the feature's own doc comment in audio_feedback_service.dart
for why these specific shapes were chosen):
  remote_start.wav          -- two short ASCENDING notes (prompting)
  remote_stop.wav           -- two short DESCENDING notes (clearly distinct
                                from start: opposite direction + lower
                                second note)
  charging_connected.wav    -- a soft upward frequency sweep (subtle,
                                mobile-style "connected" cue)
  charging_disconnected.wav -- a soft downward frequency sweep (mirror of
                                the above)
"""
import math
import struct
import wave

SAMPLE_RATE = 44100
PEAK_AMPLITUDE = 0.35  # of full scale -- deliberately not loud/full-volume


def _envelope(i, n, fade_samples):
    """Linear fade-in/out to avoid audible clicks at note boundaries."""
    fade_samples = min(fade_samples, n // 2) or 1
    if i < fade_samples:
        return i / fade_samples
    if i > n - fade_samples:
        return max(0.0, (n - i) / fade_samples)
    return 1.0


def _tone(freq_start, freq_end, duration_s, amplitude=PEAK_AMPLITUDE, fade_ms=8):
    n = int(SAMPLE_RATE * duration_s)
    fade_samples = int(SAMPLE_RATE * fade_ms / 1000)
    samples = []
    for i in range(n):
        t = i / SAMPLE_RATE
        # Linear frequency sweep from freq_start to freq_end over the note's
        # own duration (freq_start == freq_end for a plain fixed-pitch note).
        freq = freq_start + (freq_end - freq_start) * (i / n)
        env = _envelope(i, n, fade_samples)
        samples.append(amplitude * env * math.sin(2 * math.pi * freq * t))
    return samples


def _silence(duration_s):
    return [0.0] * int(SAMPLE_RATE * duration_s)


def _write_wav(path, samples):
    with wave.open(path, "w") as f:
        f.setnchannels(1)
        f.setsampwidth(2)  # 16-bit PCM
        f.setframerate(SAMPLE_RATE)
        frames = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples)
        f.writeframes(frames)


def build_remote_start():
    # Two short ascending notes -- a brisk, prompting "go" cue.
    return _tone(700, 700, 0.09) + _silence(0.02) + _tone(1000, 1000, 0.12)


def build_remote_stop():
    # Two short descending notes -- opposite contour and lower final pitch
    # than start, so the two are never confusable even in a noisy room.
    return _tone(900, 900, 0.09) + _silence(0.02) + _tone(550, 550, 0.15)


def build_charging_connected():
    # A single soft upward sweep -- distinct in TIMBRE (sweep, not discrete
    # notes) from the remote-command beeps, and quieter/subtler.
    return _tone(500, 900, 0.22, amplitude=0.22, fade_ms=15)


def build_charging_disconnected():
    # Mirror of the connected sweep.
    return _tone(900, 500, 0.22, amplitude=0.22, fade_ms=15)


if __name__ == "__main__":
    _write_wav("remote_start.wav", build_remote_start())
    _write_wav("remote_stop.wav", build_remote_stop())
    _write_wav("charging_connected.wav", build_charging_connected())
    _write_wav("charging_disconnected.wav", build_charging_disconnected())
    print("Generated remote_start.wav, remote_stop.wav, charging_connected.wav, charging_disconnected.wav")
