import 'package:uuid/uuid.dart';
import 'api_client.dart';

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

  static Future<Map<String, dynamic>> register({required String deviceIdentifier}) async {
    return await ApiClient.post('/devices/register', body: {
      'device_identifier': deviceIdentifier,
      'platform': 'android',
      'app_version': '1.0.0',
    });
  }

  static Future<void> heartbeat({required String deviceIdentifier, int? batteryPercent, bool? isCharging}) async {
    await ApiClient.post('/devices/heartbeat', body: {
      'device_identifier': deviceIdentifier,
      if (batteryPercent != null) 'battery_percent': batteryPercent,
      if (isCharging != null) 'is_charging': isCharging,
    });
  }
}
