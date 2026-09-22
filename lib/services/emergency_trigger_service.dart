import 'package:flutter/services.dart';

/// Which hardware volume key produced a recognized gesture, as sent by
/// MainActivity.kt's `dispatchKeyEvent` override. See
/// home_screen.dart's `_handleEmergencyTrigger` for what each key means:
/// while idle, VOLUME_UP starts a FRONT-camera emergency recording and
/// VOLUME_DOWN starts a BACK-camera one; while a recording is active,
/// either key stops it.
enum VolumeButtonKey { up, down }

/// Which gesture was recognized -- a double press (two quick taps) or a
/// long press (a single held press, detected via a native Handler timer
/// independent of Android's own key-repeat events, never confused with
/// one). Both kinds drive identical behavior in `_handleEmergencyTrigger`;
/// this is kept distinct only for logging/testability, not because the
/// two kinds mean different things.
enum VolumeButtonKind { double_, long }

/// Bridges the native volume-button double-press/long-press detector in
/// MainActivity.kt (foreground-only -- see that file's doc comment for the
/// exact limitation) to Dart. This is the ONLY native trigger implemented;
/// there is no fake/simulated version of this -- if the native side never
/// invokes the method (e.g. because the platform channel failed to
/// register), [onTrigger] simply never fires, rather than something faking
/// a periodic trigger to look like it works.
class EmergencyTriggerService {
  static const _channel = MethodChannel('com.policebodycam.police_body_cam/volume_trigger');

  final void Function(VolumeButtonKey key, VolumeButtonKind kind) onTrigger;
  EmergencyTriggerService({required this.onTrigger}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'volumeButtonTrigger') return;
      final args = Map<Object?, Object?>.from(call.arguments as Map);
      final key = args['key'] == 'volume_up' ? VolumeButtonKey.up : VolumeButtonKey.down;
      final kind = args['kind'] == 'double' ? VolumeButtonKind.double_ : VolumeButtonKind.long;
      onTrigger(key, kind);
    });
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}
