/// Mirrors backend/app/models.py::RemoteCommandType exactly.
enum RemoteCommandType {
  startRecording('start_recording'),
  stopRecording('stop_recording'),
  startLiveStream('start_live_stream'),
  stopLiveStream('stop_live_stream'),
  switchCameraFront('switch_camera_front'),
  switchCameraBack('switch_camera_back');

  final String wire;
  const RemoteCommandType(this.wire);
  static RemoteCommandType? fromWire(String value) {
    for (final v in values) {
      if (v.wire == value) return v;
    }
    return null; // unknown command_type -- never guess/invent a value
  }
}

/// Mirrors backend/app/models.py::RemoteCommandStatus exactly.
enum RemoteCommandStatus {
  pending('pending'),
  sent('sent'),
  acknowledged('acknowledged'),
  executed('executed'),
  failed('failed'),
  cancelled('cancelled'),
  timeout('timeout');

  final String wire;
  const RemoteCommandStatus(this.wire);
  static RemoteCommandStatus fromWire(String value) => values.firstWhere((v) => v.wire == value, orElse: () => RemoteCommandStatus.failed);
}

/// Mirrors backend/app/schemas.py::RemoteCommandResponse exactly.
class RemoteCommandResponse {
  final String id;
  final String deviceId;
  final String issuedBy;
  final RemoteCommandType? commandType;
  final RemoteCommandStatus status;
  final DateTime createdAt;
  final DateTime? sentAt;
  final DateTime? acknowledgedAt;
  final DateTime? executedAt;
  final String? failureReason;

  RemoteCommandResponse({
    required this.id,
    required this.deviceId,
    required this.issuedBy,
    required this.commandType,
    required this.status,
    required this.createdAt,
    required this.sentAt,
    required this.acknowledgedAt,
    required this.executedAt,
    required this.failureReason,
  });

  factory RemoteCommandResponse.fromJson(Map<String, dynamic> json) => RemoteCommandResponse(
        id: json['id'] as String,
        deviceId: json['device_id'] as String,
        issuedBy: json['issued_by'] as String,
        commandType: RemoteCommandType.fromWire(json['command_type'] as String),
        status: RemoteCommandStatus.fromWire(json['status'] as String),
        createdAt: DateTime.parse(json['created_at'] as String),
        sentAt: json['sent_at'] == null ? null : DateTime.parse(json['sent_at'] as String),
        acknowledgedAt: json['acknowledged_at'] == null ? null : DateTime.parse(json['acknowledged_at'] as String),
        executedAt: json['executed_at'] == null ? null : DateTime.parse(json['executed_at'] as String),
        failureReason: json['failure_reason'] as String?,
      );
}
