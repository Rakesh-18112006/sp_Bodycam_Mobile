import 'dart:async';
import 'package:uuid/uuid.dart';
import 'api_client.dart';
import '../models/device_models.dart';

class DeviceService {
  /// A stable per-install identifier, generated once and persisted forever
  /// (see docs/FLUTTER_API_HANDOFF.md §C) -- never regenerated on
  /// subsequent launches.
  static Future<String> getOrCreateDeviceIdentifier() async {
    final existing = await ApiClient.getDeviceIdentifier();
    if (existing != null) return existing;
    final id = const Uuid().v4();
    await ApiClient.setDeviceIdentifier(id);
    return id;
  }

  static Future<DeviceResponse> register({required String deviceIdentifier, String? deviceModel}) async {
    final result = await ApiClient.post('/devices/register', body: {
      'device_identifier': deviceIdentifier,
      'platform': 'android',
      'app_version': '1.0.0',
      if (deviceModel != null) 'device_model': deviceModel,
    });
    return DeviceResponse.fromJson(result as Map<String, dynamic>);
  }

  static Future<DeviceResponse> heartbeat({required String deviceIdentifier, int? batteryPercent, bool? isCharging}) async {
    final result = await ApiClient.post('/devices/heartbeat', body: {
      'device_identifier': deviceIdentifier,
      if (batteryPercent != null) 'battery_percent': batteryPercent,
      if (isCharging != null) 'is_charging': isCharging,
    });
    return DeviceResponse.fromJson(result as Map<String, dynamic>);
  }

  static Future<void> reportBattery({required String deviceIdentifier, required int batteryPercent, bool? isCharging}) async {
    await ApiClient.post('/devices/battery', body: {
      'device_identifier': deviceIdentifier,
      'battery_percent': batteryPercent,
      if (isCharging != null) 'is_charging': isCharging,
    });
  }
}

/// Lifecycle-aware periodic heartbeat (docs/FLUTTER_API_HANDOFF.md §D: the
/// backend enforces no fixed interval, but recommends 30-60s against its
/// own device_stale_seconds=120s default so a single missed beat never
/// crosses the stale threshold). [batteryPercentProvider]/[isChargingProvider]
/// are pulled fresh on every tick (rather than captured once) so heartbeat
/// naturally carries the latest known battery reading without a second,
/// separate timer duplicating that work.
///
/// A failed heartbeat is logged (via [onError]) and simply retried on the
/// next scheduled tick -- per §D/§O this is the documented, correct
/// behavior; there is no special backend-side handling for a missed beat
/// beyond the device's effective status eventually degrading to
/// stale/offline, which is the backend's job to compute, not this client's.
class HeartbeatScheduler {
  final String deviceIdentifier;
  final Duration interval;
  final int? Function() batteryPercentProvider;
  final bool? Function() isChargingProvider;
  final void Function(DeviceResponse device)? onSuccess;
  final void Function(Object error)? onError;

  Timer? _timer;
  bool _inFlight = false;

  HeartbeatScheduler({
    required this.deviceIdentifier,
    this.interval = const Duration(seconds: 45),
    required this.batteryPercentProvider,
    required this.isChargingProvider,
    this.onSuccess,
    this.onError,
  });

  void start() {
    _timer?.cancel();
    _tick(); // send one immediately rather than waiting a full interval after login
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  Future<void> _tick() async {
    if (_inFlight) return; // never overlap two heartbeats if one is slow
    _inFlight = true;
    try {
      final device = await DeviceService.heartbeat(
        deviceIdentifier: deviceIdentifier,
        batteryPercent: batteryPercentProvider(),
        isCharging: isChargingProvider(),
      );
      onSuccess?.call(device);
    } catch (e) {
      onError?.call(e);
    } finally {
      _inFlight = false;
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
