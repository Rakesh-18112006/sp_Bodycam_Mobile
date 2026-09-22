import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import '../models/recording_models.dart';
import '../services/recording_api.dart';
import '../theme/app_theme.dart';
import '../widgets/status_chip.dart';

/// Reuses GET /recordings/{id} + GET /recordings/{id}/chunks -- the same
/// authorization-scoped endpoints the list screen uses, so a constable
/// cannot reach another constable's recording by guessing/editing an ID in
/// this screen: the backend's _authorize_recording_access still runs on
/// every request and returns 403 for a real-but-unowned recording (see
/// test_unrelated_constable_cannot_view_another_constables_recording),
/// which this screen surfaces as the normal error state below rather than
/// crashing or silently showing nothing.
///
/// Playback: GET /recordings/{id}/play serves a server-side, ffmpeg
/// stream-copy-concatenated file built from this recording's individual
/// chunks (see backend/app/routers/recordings.py::_try_build_playable_recording).
/// It only exists once `playable_status == "ready"` -- that same
/// authorization check runs on this endpoint too, so a 403 here is handled
/// exactly like a 403 on the metadata calls. When it's not ready yet (still
/// recording, still concatenating, or concatenation failed/skipped because
/// of missing chunks), this screen keeps showing the original chunk
/// manifest and the "not currently supported" note rather than a broken
/// player -- it is only replaced once a real, playable file exists.
class RecordingDetailsScreen extends StatefulWidget {
  final String recordingId;
  const RecordingDetailsScreen({super.key, required this.recordingId});

  @override
  State<RecordingDetailsScreen> createState() => _RecordingDetailsScreenState();
}

class _RecordingDetailsScreenState extends State<RecordingDetailsScreen> {
  RecordingSessionResponse? _recording;
  RecordingManifestResponse? _manifest;
  bool _loading = true;
  String? _error;

  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  bool _playerLoading = false;
  String? _playerError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _chewieController?.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final recording = await RecordingApi.getRecording(widget.recordingId);
      final manifest = await RecordingApi.getManifest(widget.recordingId);
      if (!mounted) return;
      setState(() {
        _recording = recording;
        _manifest = manifest;
      });
      if (recording.playableStatus == 'ready') {
        unawaited(_initPlayer());
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _initPlayer() async {
    setState(() {
      _playerLoading = true;
      _playerError = null;
    });
    try {
      final (uri, headers) = await RecordingApi.playInfo(widget.recordingId);
      final controller = VideoPlayerController.networkUrl(uri, httpHeaders: headers);
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      final chewie = ChewieController(
        videoPlayerController: controller,
        autoPlay: false,
        looping: false,
        allowFullScreen: true,
        materialProgressColors: ChewieProgressColors(
          playedColor: Theme.of(context).colorScheme.primary,
        ),
      );
      setState(() {
        _videoController = controller;
        _chewieController = chewie;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _playerError = e.toString());
    } finally {
      if (mounted) setState(() => _playerLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recording details')),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40, color: AppColors.textSecondary),
              const SizedBox(height: AppSpacing.md),
              const Text('Unable to load recording.', style: AppTypography.cardTitle),
              const SizedBox(height: AppSpacing.xs),
              Text(_error!, textAlign: TextAlign.center, style: AppTypography.bodySecondary),
              const SizedBox(height: AppSpacing.lg),
              ElevatedButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final r = _recording!;
    final m = _manifest;
    final isEmergency = r.triggerType == TriggerType.emergencyButton;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Recording #${r.id.substring(0, 8)}', style: AppTypography.screenTitle),
            ),
            if (isEmergency) const StatusChip.emergency(label: 'EMERGENCY'),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        const SectionHeader(title: 'Video'),
        _playbackSection(r),
        const SizedBox(height: AppSpacing.xl),
        const SectionHeader(title: 'Recording information'),
        _section([
          _row('Recording ID', r.id),
          _row('Device', r.deviceId),
          _row('Constable', r.constableId),
          _row('Trigger', r.triggerType.wire),
          _row('Camera', r.cameraLensDirection.toUpperCase()),
          _row('Started', r.startedAt.toLocal().toString()),
          _row('Ended', r.endedAt?.toLocal().toString() ?? '—'),
        ]),
        const SizedBox(height: AppSpacing.lg),
        const SectionHeader(title: 'Upload status'),
        _section([
          _rowWidget('Status', _statusChip(r)),
          _row('Chunks received', '${r.chunkCount}'),
          _row('Highest chunk', '${r.highestChunkNumber ?? '—'}'),
          _row('Missing chunks', r.missingChunkNumbers.isEmpty ? 'None' : r.missingChunkNumbers.join(', ')),
          _row('Complete', m?.isComplete == true ? 'Yes' : 'No'),
        ]),
        const SizedBox(height: AppSpacing.xl),
        SectionHeader(title: 'Chunks', trailing: m != null ? Text('${m.chunks.length} total', style: AppTypography.caption) : null),
        if (m == null || m.chunks.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Text('No chunk metadata available.', style: AppTypography.bodySecondary),
            ),
          )
        else
          for (final c in m.chunks) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 4),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: AppColors.neutralBg, borderRadius: BorderRadius.circular(AppRadii.sm)),
                      child: Text('${c.chunkNumber}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Chunk ${c.chunkNumber}${c.isLastChunk ? ' (last)' : ''}',
                            style: AppTypography.body.copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            '${c.fileSize != null ? _formatBytes(c.fileSize!) : '—'} · '
                            '${c.durationSeconds != null ? '${c.durationSeconds!.toStringAsFixed(1)}s' : '—'}',
                            style: AppTypography.caption,
                          ),
                        ],
                      ),
                    ),
                    _chunkUploadChip(c.uploadStatus),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
      ],
    );
  }

  Widget _statusChip(RecordingSessionResponse r) {
    switch (r.status) {
      case RecordingStatus.completed:
        return r.missingChunkNumbers.isNotEmpty
            ? const StatusChip.warning(label: 'INCOMPLETE')
            : const StatusChip.success(label: 'COMPLETED');
      case RecordingStatus.recording:
        return const StatusChip.danger(label: 'RECORDING', icon: Icons.fiber_manual_record);
      case RecordingStatus.failed:
        return const StatusChip.danger(label: 'FAILED', icon: Icons.error_outline);
      case RecordingStatus.cancelled:
        return const StatusChip.neutral(label: 'CANCELLED');
    }
  }

  Widget _chunkUploadChip(String uploadStatus) {
    switch (uploadStatus) {
      case 'uploaded':
        return const StatusChip.success(label: 'UPLOADED');
      case 'uploading':
        return const StatusChip.info(label: 'UPLOADING');
      case 'failed':
        return const StatusChip.danger(label: 'FAILED');
      default:
        return const StatusChip.warning(label: 'PENDING');
    }
  }

  Widget _playbackSection(RecordingSessionResponse r) {
    if (r.playableStatus == 'ready') {
      if (_playerLoading) {
        return const Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('Loading video…', style: AppTypography.bodySecondary),
            ])),
          ),
        );
      }
      if (_playerError != null) {
        return Card(
          color: AppColors.dangerBg,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Unable to play this recording.', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.danger)),
                const SizedBox(height: 4),
                Text(_playerError!, style: const TextStyle(color: AppColors.danger, fontSize: 12)),
                const SizedBox(height: AppSpacing.sm),
                ElevatedButton(onPressed: _initPlayer, child: const Text('Retry')),
              ],
            ),
          ),
        );
      }
      if (_chewieController != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.md),
          child: AspectRatio(
            aspectRatio: _videoController!.value.aspectRatio == 0 ? 16 / 9 : _videoController!.value.aspectRatio,
            child: Chewie(controller: _chewieController!),
          ),
        );
      }
      // playableStatus flipped to ready but the player hasn't been kicked
      // off yet (e.g. this recording was already ready on first load and
      // initState's _initPlayer() call is still pending its first frame).
      return const SizedBox.shrink();
    }

    if (r.playableStatus == 'building') {
      return Card(
        color: AppColors.infoBg,
        child: const Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: Row(children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.info)),
            SizedBox(width: AppSpacing.md),
            Expanded(child: Text('Preparing video for playback…', style: TextStyle(color: AppColors.info, fontWeight: FontWeight.w600))),
          ]),
        ),
      );
    }

    if (r.playableStatus == 'failed') {
      return const Card(
        color: AppColors.neutralBg,
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: Text(
            'Playback could not be prepared for this recording. Recordings are stored and uploaded as separate chunks; the list below shows each chunk actually received by the server.',
            style: AppTypography.bodySecondary,
          ),
        ),
      );
    }

    // not_ready: still recording, or completed with gaps that make
    // concatenation impossible/skipped (see missing chunks above).
    return const Card(
      color: AppColors.neutralBg,
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: Text(
          'Playback is not currently supported for this recording. Recordings are stored and uploaded as separate chunks; the list below shows each chunk actually received by the server.',
          style: AppTypography.bodySecondary,
        ),
      ),
    );
  }

  Widget _section(List<Widget> rows) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 130, child: Text(label, style: AppTypography.caption)),
          Expanded(child: Text(value, style: AppTypography.body)),
        ],
      ),
    );
  }

  Widget _rowWidget(String label, Widget value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(width: 130, child: Text(label, style: AppTypography.caption)),
          value,
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
}
