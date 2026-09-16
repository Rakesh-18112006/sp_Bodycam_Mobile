import 'package:flutter/services.dart';

/// Bridges the native volume-button double-press detector in
/// MainActivity.kt (foreground-only -- see that file's doc comment for the
/// exact limitation) to Dart. This is the ONLY native trigger implemented;
/// there is no fake/simulated version of this -- if the native side never
/// invokes the method (e.g. because the platform channel failed to
/// register), [onTrigger] simply never fires, rather than something faking
/// a periodic trigger to look like it works.
class EmergencyTriggerService {
  static const _channel = MethodChannel('com.policebodycam.police_body_cam/volume_trigger');

  final void Function() onTrigger;
  EmergencyTriggerService({required this.onTrigger}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'volumeButtonDoublePress') {
        onTrigger();
      }
    });
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}
