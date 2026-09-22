import 'package:audioplayers/audioplayers.dart';

/// The four short local tones this feature plays. See
/// assets/audio/generate_tones.py for exactly how each .wav was
/// synthesized (pure sine waves, no downloaded/copyrighted audio) --
/// remoteStart/remoteStop are a deliberately DIFFERENT shape (ascending vs
/// descending two-note pattern) from chargingConnected/chargingDisconnected
/// (a single smooth frequency sweep, played quieter) so the two feature
/// categories are never confused with each other either.
enum AudioFeedbackSound {
  remoteStart,
  remoteStop,
  chargingConnected,
  chargingDisconnected,
}

/// Short, local, best-effort audio feedback for (1) a remote command that
/// has ACTUALLY, SUCCESSFULLY executed (see home_screen.dart's
/// _handleRemoteCommand -- this is called only after the real
/// start()/stop() call is confirmed to have taken effect, never merely
/// because a WebSocket message arrived) and (2) a genuine charging-state
/// transition (see BatteryService.onChargingChanged).
///
/// Deliberately uses Android's SONIFICATION content type +
/// ASSISTANCE_SONIFICATION usage with NO audio focus request
/// (AndroidAudioFocus.none): this is the standard Android audio attribute
/// combination for short UI feedback sounds (docs: "usage is sonification,
/// such as with user interface sounds"). Requesting no focus means this
/// playback never pauses/ducks anything else and never contends with the
/// RecordingEngine's own camera+microphone AVCaptureSession/MediaRecorder
/// audio session -- it does not touch the recording pipeline at all, is
/// not routed through the microphone, and does not change the user's
/// ringtone/notification/media volume sliders (the `volume` passed to
/// play() is this player's own output gain only). Physical devices can
/// still have the speaker's output acoustically picked up by the
/// microphone if a recording is genuinely in progress at that exact
/// moment -- that is normal physical acoustic coupling, not something any
/// software guarantee here claims to prevent.
class AudioFeedbackService {
  static const Map<AudioFeedbackSound, String> _assetFor = {
    AudioFeedbackSound.remoteStart: 'audio/remote_start.wav',
    AudioFeedbackSound.remoteStop: 'audio/remote_stop.wav',
    AudioFeedbackSound.chargingConnected: 'audio/charging_connected.wav',
    AudioFeedbackSound.chargingDisconnected: 'audio/charging_disconnected.wav',
  };

  // Not `const` -- AudioContext's own constructor has a body (it fills in
  // a default AudioContextIOS), so it isn't a const constructor.
  static final AudioContext _context = AudioContext(
    android: const AudioContextAndroid(
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.assistanceSonification,
      audioFocus: AndroidAudioFocus.none,
    ),
  );

  // One AudioPlayer per sound rather than a single shared instance -- a
  // remote STOP arriving right after a remote START (or a rapid
  // plug/unplug) must never have one play() call cancel/replace another's
  // in-flight playback.
  final Map<AudioFeedbackSound, AudioPlayer> _players = {};

  Future<void> play(AudioFeedbackSound sound) async {
    try {
      final player = _players.putIfAbsent(
        sound,
        () => AudioPlayer(playerId: 'bodycam_audio_feedback_${sound.name}'),
      );
      await player.play(
        AssetSource(_assetFor[sound]!),
        mode: PlayerMode.lowLatency,
        ctx: _context,
        volume: 0.6,
      );
    } catch (_) {
      // Best-effort UI polish only (silent profile, no audio output
      // hardware, etc.) -- must never affect command execution or
      // charging-state tracking, both of which have already completed
      // successfully by the time this is called.
    }
  }

  Future<void> dispose() async {
    for (final player in _players.values) {
      await player.dispose();
    }
    _players.clear();
  }
}
