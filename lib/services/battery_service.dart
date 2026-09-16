import 'dart:async';
import 'package:battery_plus/battery_plus.dart';

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

  Future<void> start({Duration pollInterval = const Duration(seconds: 45)}) async {
    await _refresh();
    _stateSub = _battery.onBatteryStateChanged.listen((state) {
      isCharging = state == BatteryState.charging || state == BatteryState.full;
    });
    _pollTimer = Timer.periodic(pollInterval, (_) => _refresh());
  }

  Future<void> _refresh() async {
    try {
      currentPercent = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      isCharging = state == BatteryState.charging || state == BatteryState.full;
    } catch (_) {
      // Platform read failed (rare, but some emulators/devices don't
      // implement BatteryManager fully) -- leave prior values in place
      // rather than reporting a guess.
    }
  }

  void stop() {
    _stateSub?.cancel();
    _pollTimer?.cancel();
  }
}
