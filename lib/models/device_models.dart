/// Mirrors backend/app/schemas.py::DeviceResponse exactly. `status` is the
/// backend's EFFECTIVE status (online/stale/offline/recording), computed
/// server-side at request time -- never recomputed or second-guessed here.
class DeviceResponse {
  final String id;
  final String? constableId;
  final String deviceIdentifier;
  final String? platform;
  final String? appVersion;
  final String? deviceModel;
  final String status;
  final DateTime? lastHeartbeatAt;
  final DateTime? lastSeenAt;
  final DateTime createdAt;
  final int? batteryPercent;
  final bool? isCharging;
  final double? latitude;
  final double? longitude;
  final DateTime? locationUpdatedAt;

  DeviceResponse({
    required this.id,
    required this.constableId,
    required this.deviceIdentifier,
    required this.platform,
    required this.appVersion,
    required this.deviceModel,
    required this.status,
    required this.lastHeartbeatAt,
    required this.lastSeenAt,
    required this.createdAt,
    required this.batteryPercent,
    required this.isCharging,
    required this.latitude,
    required this.longitude,
    required this.locationUpdatedAt,
  });

  factory DeviceResponse.fromJson(Map<String, dynamic> json) => DeviceResponse(
        id: json['id'] as String,
        constableId: json['constable_id'] as String?,
        deviceIdentifier: json['device_identifier'] as String,
        platform: json['platform'] as String?,
        appVersion: json['app_version'] as String?,
        deviceModel: json['device_model'] as String?,
        status: json['status'] as String,
        lastHeartbeatAt: json['last_heartbeat_at'] == null ? null : DateTime.parse(json['last_heartbeat_at'] as String),
        lastSeenAt: json['last_seen_at'] == null ? null : DateTime.parse(json['last_seen_at'] as String),
        createdAt: DateTime.parse(json['created_at'] as String),
        batteryPercent: json['battery_percent'] as int?,
        isCharging: json['is_charging'] as bool?,
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
        locationUpdatedAt: json['location_updated_at'] == null ? null : DateTime.parse(json['location_updated_at'] as String),
      );
}

/// Mirrors backend/app/schemas.py::ConstableLocationResponse (the response
/// of POST /constables/me/location).
class ConstableLocationResponse {
  final String status;
  final String constableId;
  final double latitude;
  final double longitude;
  final double? accuracy;
  final DateTime timestamp;

  ConstableLocationResponse({
    required this.status,
    required this.constableId,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.timestamp,
  });

  factory ConstableLocationResponse.fromJson(Map<String, dynamic> json) => ConstableLocationResponse(
        status: json['status'] as String,
        constableId: json['constable_id'] as String,
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        accuracy: (json['accuracy'] as num?)?.toDouble(),
        timestamp: DateTime.parse(json['timestamp'] as String),
      );
}
