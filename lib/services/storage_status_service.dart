import 'package:flutter/services.dart';
import 'offline_queue_service.dart';

enum StorageLevel { unknown, ok, low, critical }

class StorageStatus {
  final int? freeBytes;
  final int unconfirmedBytes; // video on the phone the control room has not confirmed yet
  final StorageLevel level;
  const StorageStatus(this.freeBytes, this.unconfirmedBytes, this.level);
}

/// Free-space check for the volume that holds recorded segments. At site,
/// with no backhaul, the phone may hold hours of video that the control room
/// does not yet have; running out of space would end the recording, so the
/// officer is warned early.
class StorageStatusService {
  static const _channel = MethodChannel('com.policebodycam.police_body_cam/storage');
  static const lowBytes = 1024 * 1024 * 1024; // warn below 1 GiB
  static const criticalBytes = 300 * 1024 * 1024; // act below 300 MiB

  static Future<int?> freeBytes() async {
    try {
      return (await _channel.invokeMethod<num>('freeBytes'))?.toInt();
    } catch (_) {
      return null; // not available (e.g. non-Android test environment)
    }
  }

  static Future<StorageStatus> read() async {
    final free = await freeBytes();
    final unconfirmed = await OfflineQueueService.unconfirmedBytes();
    final level = free == null
        ? StorageLevel.unknown
        : free < criticalBytes
            ? StorageLevel.critical
            : free < lowBytes
                ? StorageLevel.low
                : StorageLevel.ok;
    return StorageStatus(free, unconfirmed, level);
  }

  static String format(int? bytes) {
    if (bytes == null) return 'unknown';
    const gib = 1024 * 1024 * 1024;
    if (bytes >= gib) return '${(bytes / gib).toStringAsFixed(1)} GiB';
    return '${(bytes / (1024 * 1024)).round()} MiB';
  }
}
