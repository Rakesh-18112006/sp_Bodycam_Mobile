import 'package:flutter/material.dart';
import '../models/recording_models.dart';
import '../services/offline_queue_service.dart';
import '../services/recording_api.dart';
import '../theme/app_theme.dart';
import '../widgets/status_chip.dart';
import 'recording_details_screen.dart';

/// "What have I recorded/uploaded?" -- reuses GET /recordings/ (already
/// scoped server-side to the authenticated constable's own recordings
/// only, see RecordingApi's doc comment) for completed/server-known
/// recordings, plus the EXISTING local offline queue
/// (OfflineQueueService.unfinishedSessions) for recordings still local-only
/// (recording/offline/uploading) that haven't necessarily reached the
/// server as a distinct row yet. No new backend endpoint, no change to the
/// recording/upload pipeline itself.
class MyRecordingsScreen extends StatefulWidget {
  const MyRecordingsScreen({super.key});

  @override
  State<MyRecordingsScreen> createState() => _MyRecordingsScreenState();
}

class _MyRecordingsScreenState extends State<MyRecordingsScreen> {
  List<RecordingSessionResponse>? _serverRecordings;
  List<LocalRecordingSession> _localPending = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Local-only lookups never fail the whole screen (a bad sqflite read
      // isn't the user's problem if the server list itself is fine) --
      // only the server call's failure is treated as the page-level error.
      final local = await OfflineQueueService.unfinishedSessions().catchError((_) => <LocalRecordingSession>[]);
      final server = await RecordingApi.myRecordings();
      if (!mounted) return;
      setState(() {
        _localPending = local;
        _serverRecordings = server;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Recordings'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _loading ? null : _load, tooltip: 'Refresh')],
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading && _serverRecordings == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _serverRecordings == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 40, color: AppColors.textSecondary),
              const SizedBox(height: AppSpacing.md),
              const Text('Unable to load recordings.', style: AppTypography.cardTitle),
              const SizedBox(height: AppSpacing.xs),
              Text(_error!, textAlign: TextAlign.center, style: AppTypography.bodySecondary),
              const SizedBox(height: AppSpacing.lg),
              ElevatedButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final server = _serverRecordings ?? const [];
    // A local session already reflected by a server row (same backend id)
    // is shown once, as the server row -- otherwise a mid-upload recording
    // would appear twice for a few seconds.
    final serverIds = server.map((r) => r.id).toSet();
    final localOnly = _localPending.where((s) => s.backendSessionId == null || !serverIds.contains(s.backendSessionId)).toList();

    if (server.isEmpty && localOnly.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.video_library_outlined, size: 40, color: AppColors.textSecondary),
            SizedBox(height: AppSpacing.md),
            Text('No recordings yet.', style: AppTypography.body),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          for (final s in localOnly) ...[
            _LocalPendingTile(session: s),
            const SizedBox(height: AppSpacing.sm),
          ],
          for (final r in server) ...[
            _ServerRecordingTile(recording: r, onTap: () => _openDetails(r.id)),
            const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }

  void _openDetails(String recordingId) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => RecordingDetailsScreen(recordingId: recordingId)));
  }
}

class _LocalPendingTile extends StatelessWidget {
  final LocalRecordingSession session;
  const _LocalPendingTile({required this.session});

  String get _label => switch (session.lifecycleState) {
        'offline' => 'Waiting for connection',
        'recording' => 'Recording in progress',
        'uploading' => 'Uploading…',
        'completing' => 'Finishing…',
        _ => session.lifecycleState,
      };

  StatusChip get _chip => switch (session.lifecycleState) {
        'offline' => const StatusChip.warning(label: 'PENDING', icon: Icons.cloud_off_outlined),
        'recording' => const StatusChip.danger(label: 'RECORDING', icon: Icons.fiber_manual_record),
        'uploading' => const StatusChip.info(label: 'UPLOADING'),
        'completing' => const StatusChip.info(label: 'FINISHING', icon: Icons.hourglass_bottom_outlined),
        _ => const StatusChip.neutral(label: 'PENDING'),
      };

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(color: AppColors.warningBg, borderRadius: BorderRadius.circular(AppRadii.sm)),
              child: const Icon(Icons.cloud_upload_outlined, color: AppColors.warning),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Recording ${session.localSessionId.substring(0, 8)}', style: AppTypography.cardTitle),
                  const SizedBox(height: 3),
                  Text('$_label · Started ${_formatDate(session.startedAt)}', style: AppTypography.caption),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            _chip,
          ],
        ),
      ),
    );
  }
}

class _ServerRecordingTile extends StatelessWidget {
  final RecordingSessionResponse recording;
  final VoidCallback onTap;
  const _ServerRecordingTile({required this.recording, required this.onTap});

  StatusChip _statusChip() {
    if (recording.status == RecordingStatus.completed) {
      if (recording.missingChunkNumbers.isNotEmpty) {
        return const StatusChip.warning(label: 'INCOMPLETE');
      }
      return const StatusChip.success(label: 'COMPLETED');
    }
    if (recording.status == RecordingStatus.recording) {
      return const StatusChip.danger(label: 'RECORDING', icon: Icons.fiber_manual_record);
    }
    if (recording.status == RecordingStatus.failed) {
      return const StatusChip.danger(label: 'FAILED', icon: Icons.error_outline);
    }
    return const StatusChip.neutral(label: 'CANCELLED');
  }

  @override
  Widget build(BuildContext context) {
    final duration = recording.endedAt?.difference(recording.startedAt);
    final isEmergency = recording.triggerType == TriggerType.emergencyButton;
    final isFront = recording.cameraLensDirection.toLowerCase() == 'front';

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: isEmergency ? AppColors.emergencyBg : AppColors.infoBg,
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                ),
                child: Icon(
                  isEmergency ? Icons.emergency_outlined : Icons.videocam_outlined,
                  color: isEmergency ? AppColors.emergency : AppColors.info,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('Recording #${recording.id.substring(0, 8)}', style: AppTypography.cardTitle),
                        ),
                        if (isEmergency) const StatusChip.emergency(label: 'EMERGENCY'),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(_formatDate(recording.startedAt), style: AppTypography.caption),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        _metaChip(Icons.schedule_outlined, duration != null ? _formatDuration(duration) : '—'),
                        _metaChip(isFront ? Icons.camera_front_outlined : Icons.camera_rear_outlined, isFront ? 'Front' : 'Back'),
                        _metaChip(
                          Icons.layers_outlined,
                          '${recording.chunkCount} chunk${recording.chunkCount == 1 ? '' : 's'}'
                          '${recording.missingChunkNumbers.isNotEmpty ? ' (${recording.missingChunkNumbers.length} missing)' : ''}',
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _statusChip(),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              const Icon(Icons.chevron_right, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _metaChip(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: AppColors.textSecondary),
        const SizedBox(width: 3),
        Text(text, style: AppTypography.caption),
      ],
    );
  }
}

String _formatDate(DateTime dt) {
  final local = dt.toLocal();
  final d = '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')}/${local.year}';
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  return '$d $h:$m';
}

String _formatDuration(Duration d) {
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
