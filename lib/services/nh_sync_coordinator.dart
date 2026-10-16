import 'dart:async';
import 'package:flutter/foundation.dart';
import 'chunk_uploader.dart';
import 'network_hopping_service.dart';
import 'offline_queue_service.dart';
import 'storage_status_service.dart';

/// Background loop that keeps Network Hopping moving without an active
/// recording: it renews the offline grant while the control room is
/// reachable, sends anything still waiting for a route, and confirms
/// receiver-held chunks with the control room so the phone can finally free
/// their local files. Cheap when idle (one local query per tick).
///
/// Online mode with nothing awaiting central confirmation is left entirely
/// to the existing RecordingService pump / startup recovery; this loop does
/// not change that behaviour.
class NhSyncCoordinator extends ChangeNotifier {
  NhSyncCoordinator._();
  static final NhSyncCoordinator instance = NhSyncCoordinator._();

  static const interval = Duration(seconds: 30);
  Timer? _timer;
  bool _running = false;
  DateTime? lastRun;
  StorageStatus? storage;

  /// Off by default. When ON, and the phone is critically short of space, the
  /// oldest chunks a site receiver already holds durably may be deleted from
  /// the phone before the control room confirms them. See
  /// ChunkUploader.purgeReceiverAckedForSpace and the documentation.
  bool lowStoragePurgeEnabled = false;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => tick());
    unawaited(tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> tick() async {
    if (_running) return;
    _running = true;
    try {
      final nh = NetworkHoppingService.instance;
      await nh.load();
      storage = await StorageStatusService.read();
      final awaiting = await OfflineQueueService.awaitingCentralChunks();
      if (nh.enabled) await nh.maybeRefreshConfig();
      if (nh.enabled || awaiting.isNotEmpty) {
        final unsent = await OfflineQueueService.unsentChunks();
        if (unsent.isNotEmpty || awaiting.isNotEmpty) await ChunkUploader().drain();
      }
      if (lowStoragePurgeEnabled && storage!.level == StorageLevel.critical) {
        final removed = await ChunkUploader().purgeReceiverAckedForSpace(maxFiles: 5);
        if (removed > 0) debugPrint('[bodycam] low storage: removed $removed receiver-held local copies');
      }
    } catch (e) {
      debugPrint('[bodycam] sync tick failed (${e.runtimeType}); will retry');
    } finally {
      _running = false;
      lastRun = DateTime.now();
      notifyListeners();
    }
  }
}
