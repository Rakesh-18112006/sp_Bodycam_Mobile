import 'dart:async';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// Real Android battery reporting via `battery_plus` (reads the OS
/// BatteryManager). Never fabricates a value -- if the platform read
/// fails, [currentPercent]/[isCharging] simply stay null and callers
/// (HeartbeatScheduler) omit those fields from the request rather than
/// invent a number.
class BatteryService {
  final Battery _battery = Battery();
  int? currentPercent;
  bool? isCharging;

  StreamSubscription<BatteryState>? _stateSub;
  Timer? _pollTimer;

  /// Fired only on a genuine NOT-CHARGING<->CHARGING transition -- never on
  /// a repeated report of the same state (e.g. the periodic poll below
  /// re-confirming a state the stream listener already reported, or a
  /// percentage-only update while still charging). Both [_stateSub] (event
  /// -based, fires promptly on a real OS power broadcast) and the poll
  /// timer (a defense-in-depth fallback already present before this field
  /// existed -- kept as-is, not something this feature added) funnel
  /// through the same [_updateCharging] edge-detector, so whichever notices
  /// the change first fires this exactly once and the other becomes a
  /// no-op. Used by home_screen.dart to play the charging-connected/
  /// disconnected audio feedback tones (see audio_feedback_service.dart) --
  /// this class has no knowledge of audio itself, it only reports the real
  /// transition.
  final void Function(bool isCharging)? onChargingChanged;

  BatteryService({this.onChargingChanged});

  Future<void> start({Duration pollInterval = const Duration(seconds: 45)}) async {
    await _refresh();
    _stateSub = _battery.onBatteryStateChanged.listen((state) {
      _updateCharging(state == BatteryState.charging || state == BatteryState.full);
    });
    _pollTimer = Timer.periodic(pollInterval, (_) => _refresh());
  }

  Future<void> _refresh() async {
    try {
      currentPercent = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      _updateCharging(state == BatteryState.charging || state == BatteryState.full);
    } catch (_) {
      // Platform read failed (rare, but some emulators/devices don't
      // implement BatteryManager fully) -- leave prior values in place
      // rather than reporting a guess.
    }
  }

  void _updateCharging(bool newValue) {
    // isCharging == null means this is the very first reading -- that's
    // establishing a baseline, not a transition, so it must never fire the
    // callback (there is nothing to distinguish it from "app just started
    // while already charging").
    final changed = isCharging != null && isCharging != newValue;
    isCharging = newValue;
    if (changed) onChargingChanged?.call(newValue);
  }

  /// Test-only seam: `battery_plus` has no platform implementation in the
  /// unit-test environment (its own calls always throw, which [_refresh]
  /// already catches), so tests exercise the actual edge-detection logic
  /// directly through this instead of trying to fake the plugin's stream.
  @visibleForTesting
  void simulateChargingReading(bool newValue) => _updateCharging(newValue);

  void stop() {
    _stateSub?.cancel();
    _pollTimer?.cancel();
  }
}
