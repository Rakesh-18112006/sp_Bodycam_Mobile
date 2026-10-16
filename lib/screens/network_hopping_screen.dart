import 'dart:async';
import 'package:flutter/material.dart';
import '../models/recording_models.dart';
import '../services/chunk_uploader.dart';
import '../services/network_hopping_service.dart';
import '../services/nh_sync_coordinator.dart';
import '../services/offline_queue_service.dart';
import '../services/storage_status_service.dart';
import '../theme/app_theme.dart';

/// Operational screen for Network Hopping: choose the transport mode, see
/// whether the site receiver is reachable and the offline grant valid, and
/// follow what has reached the site receiver versus the control room.
class NetworkHoppingScreen extends StatefulWidget {
  const NetworkHoppingScreen({super.key});
  @override
  State<NetworkHoppingScreen> createState() => _NetworkHoppingScreenState();
}

class _NetworkHoppingScreenState extends State<NetworkHoppingScreen> {
  final _nh = NetworkHoppingService.instance;
  final _sync = NhSyncCoordinator.instance;
  final _overrideCtl = TextEditingController();
  Map<String, int> _counts = const {};
  List<QueuedChunk> _failed = const [];
  StorageStatus? _storage;
  Timer? _timer;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _nh.load().then((_) {
      _overrideCtl.text = _nh.receiverOverride ?? '';
      _refresh();
    });
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _overrideCtl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final counts = await OfflineQueueService.countsByState();
    final failed = await OfflineQueueService.failedChunks();
    final storage = await StorageStatusService.read();
    if (!mounted) return;
    setState(() {
      _counts = counts;
      _failed = failed;
      _storage = storage;
    });
  }

  Future<void> _run(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final r = await action();
      if (mounted) setState(() => _message = r);
    } catch (e) {
      if (mounted) setState(() => _message = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  static const _statusText = {
    'connected': 'Connected to the site receiver',
    'unknown': 'Not checked yet',
    'receiver_unreachable': 'Site receiver not reachable. Connect to the site network. Recording continues and video waits on this phone.',
    'wrong_site': 'The receiver on this network belongs to a different site',
    'receiver_storage_full': 'The site receiver is out of space and is not accepting video',
    'no_receiver_configured': 'No receiver address is known for this site. Refresh from the control room or enter one below.',
    'not_provisioned': 'No site is assigned to you. Connect to the control room and refresh.',
    'no_grant': 'No offline grant yet. Connect to the control room and refresh.',
    'grant_expired': 'The offline grant has expired. Connect to the control room and refresh.',
    'grant_revoked': 'The offline grant was revoked. Contact the control room.',
    'grant_wrong_site': 'The grant is for a different site',
    'device_not_authorized': 'This phone is not authorized for the site',
    'no_active_assignment': 'You have no active assignment at this site',
    'operation_not_permitted': 'The offline grant does not allow this. Uploads to the receiver are paused; videos stay on this phone. Refresh from the control room.',
    'device_mismatch': 'The grant was issued for a different device. Refresh from the control room.',
    'grant_invalid': 'The offline grant is not valid. Refresh from the control room.',
    'grant_key_unknown': 'The grant was signed with a key this receiver does not know. Contact the control room.',
  };

  static const _problemText = {
    'local_file_corrupt': 'The video file on this phone no longer matches its recorded checksum. It is kept for diagnosis and cannot be uploaded; this part of the recording is missing.',
    'local_file_missing': 'The video file is no longer on this phone.',
    'receiver_quarantined': 'The site receiver quarantined this chunk. Keep it; the control room operator must resolve it.',
    'chunk_quarantined': 'The site receiver quarantined this chunk. Keep it; the control room operator must resolve it.',
    'hash_conflict': 'The server already holds different content for this chunk number. Needs an operator.',
    'identity_conflict': 'That chunk number is already used by a different chunk. Needs an operator.',
    'central_hash_mismatch': 'The control room holds different bytes for this chunk than this phone. Needs an operator.',
  };

  String _status(String code) => _statusText[code] ?? (code.startsWith('grant_') ? 'The offline grant failed the phone\'s own check ($code). Refresh from the control room.' : code);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Network Hopping')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([_nh, _sync]),
          builder: (context, _) {
            final site = _nh.activeSite;
            final storage = _storage;
            return ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                _section('Mode', [
                  SegmentedButton<TransportMode>(
                    segments: const [
                      ButtonSegment(value: TransportMode.online, label: Text('Online'), icon: Icon(Icons.cloud_outlined)),
                      ButtonSegment(value: TransportMode.networkHopping, label: Text('Network Hopping'), icon: Icon(Icons.cell_tower)),
                    ],
                    selected: {_nh.mode},
                    onSelectionChanged: _busy
                        ? null
                        : (s) => _run(() async {
                              await _nh.setMode(s.first);
                              if (s.first == TransportMode.networkHopping && _nh.sites.isEmpty) return await _nh.refreshConfig();
                              return null;
                            }),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    _nh.enabled
                        ? 'Video is sent to the receiver on the site network, which forwards it to the control room when the site internet returns. Your phone keeps every video until the control room confirms it.'
                        : 'Video is sent straight to the control room over the internet (the normal mode).',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ]),
                if (_nh.enabled && _nh.centralAuthExpired)
                  _warning('Your control-room sign-in has expired. Recording and uploads to the site receiver continue under the offline grant. Connect to the internet and sign in again to renew it.'),
                if (_nh.enabled && !_nh.grantValid)
                  _warning('Network Hopping is on but there is no valid offline grant, so new recordings use the normal online flow. ${_status(_nh.receiverStatus == 'unknown' ? (site?.reason ?? 'no_grant') : _nh.receiverStatus)}'),
                _section('Site and offline grant', [
                  if (site == null)
                    const Text('No site assigned. Connect to the control room and press Refresh.')
                  else ...[
                    if (_nh.sites.length > 1)
                      DropdownButton<String>(
                        isExpanded: true,
                        value: site.siteId,
                        items: [for (final s in _nh.sites) DropdownMenuItem(value: s.siteId, child: Text('${s.siteName} (${s.siteCode})'))],
                        onChanged: _busy ? null : (v) => v == null ? null : _run(() async {
                              await _nh.setActiveSite(v);
                              return null;
                            }),
                      )
                    else
                      Text('${site.siteName} (${site.siteCode})', style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(site.grantValid
                        ? 'Offline grant valid until ${_fmt(site.grantExpiresAt!)}'
                        : site.eligible
                            ? 'Offline grant expired. Refresh while connected to the control room.'
                            : 'Not eligible: ${_status(site.reason ?? 'unknown')}'),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  Text(_nh.configFetchedAt == null ? 'Never provisioned' : 'Provisioned ${_fmt(_nh.configFetchedAt!)}', style: Theme.of(context).textTheme.bodySmall),
                  if (_nh.lastConfigError != null) Text('Last refresh failed: ${_nh.lastConfigError}', style: const TextStyle(color: Colors.redAccent)),
                  const SizedBox(height: AppSpacing.sm),
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _run(() async => await _nh.refreshConfig() ?? 'Provisioning refreshed'),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh from control room'),
                  ),
                ]),
                _section('Site receiver', [
                  Row(children: [
                    Icon(_nh.receiverStatus == 'connected' ? Icons.check_circle : Icons.info_outline, size: 18, color: _nh.receiverStatus == 'connected' ? Colors.green : Colors.orange),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_status(_nh.receiverStatus))),
                  ]),
                  if (site != null)
                    for (final r in site.receivers) Padding(padding: const EdgeInsets.only(top: 4), child: Text('${r.name.isEmpty ? r.code : r.name}: ${r.endpointUrl}', style: Theme.of(context).textTheme.bodySmall)),
                  if (site != null && site.unusableReceivers > 0)
                    Padding(padding: const EdgeInsets.only(top: 4), child: Text('${site.unusableReceivers} receiver(s) have no valid https address yet and are not used.', style: Theme.of(context).textTheme.bodySmall)),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: _overrideCtl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(labelText: 'Receiver address override (optional)', hintText: 'https://receiver.site.example:8443', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(spacing: 8, children: [
                    OutlinedButton(onPressed: _busy ? null : () => _run(() async {
                          final problem = await _nh.setReceiverOverride(_overrideCtl.text);
                          return problem ?? 'Receiver address saved';
                        }), child: const Text('Save address')),
                    OutlinedButton(onPressed: _busy ? null : () => _run(() async {
                          final s = await _nh.receiverSession(forceNew: true);
                          return s == null ? _status(_nh.receiverStatus) : 'Connected to ${s.baseUrl}';
                        }), child: const Text('Test connection')),
                  ]),
                ]),
                _section('Fallback policy', [
                  Text('Control room health: ${_nh.centralStatus}', style: Theme.of(context).textTheme.bodySmall),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Send straight to the control room when the site receiver is unavailable'),
                    subtitle: const Text('On (default): site recordings go directly to the control room if it is reachable and no receiver is. Off: they wait for the site receiver.'),
                    value: _nh.centralFallback,
                    onChanged: (v) => _nh.setCentralFallback(v),
                  ),
                ]),
                _section('Video transfer', [
                  _row('Waiting to send', _counts[QueuedChunk.statePending], _counts[QueuedChunk.stateUploading]),
                  _row('Stored at site, awaiting control room', _counts[QueuedChunk.stateLocalAcked]),
                  _row('Confirmed by control room', _counts[QueuedChunk.stateUploaded]),
                  _row('Rejected (kept on phone)', _counts[QueuedChunk.stateFailed]),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(spacing: 8, children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : () => _run(() async {
                            await ChunkUploader().syncNow();
                            return 'Sync pass finished';
                          }),
                      icon: const Icon(Icons.sync),
                      label: const Text('Sync now'),
                    ),
                    if ((_counts[QueuedChunk.stateFailed] ?? 0) > 0)
                      OutlinedButton(
                        onPressed: _busy ? null : () => _run(() async => 'Re-queued ${await OfflineQueueService.requeueFailed()} chunk(s)'),
                        child: const Text('Retry rejected'),
                      ),
                  ]),
                ]),
                if (_failed.isNotEmpty)
                  _section('Needs attention (kept on this phone)', [
                    for (final c in _failed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text('Chunk ${c.chunkNumber} of recording ${c.localSessionId.substring(0, 8)}…: ${_problemText[c.lastError] ?? (c.lastError ?? 'rejected')}', style: Theme.of(context).textTheme.bodySmall),
                      ),
                  ]),
                _section('Phone storage', [
                  Text('Free: ${StorageStatusService.format(storage?.freeBytes)}    Not yet confirmed centrally: ${StorageStatusService.format(storage?.unconfirmedBytes)}'),
                  if (storage?.level == StorageLevel.low) _warning('Storage is getting low. Connect to the site network or the internet so video can be confirmed and freed.'),
                  if (storage?.level == StorageLevel.critical) _warning('Storage is critically low. Recording may stop. Move to the site network now.'),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Free space by removing video the site receiver already holds'),
                    subtitle: const Text('Off by default. Only when storage is critical: the oldest local copies already stored at the site receiver are deleted before the control room confirms them. That evidence then exists only on the receiver until it syncs.'),
                    value: _sync.lowStoragePurgeEnabled,
                    onChanged: (v) => setState(() => _sync.lowStoragePurgeEnabled = v),
                  ),
                ]),
                if (_message != null) Padding(padding: const EdgeInsets.only(top: AppSpacing.sm), child: Text(_message!)),
              ],
            );
          },
        ),
      ),
    );
  }

  static String _fmt(DateTime t) {
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  Widget _row(String label, int? a, [int? b]) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [Expanded(child: Text(label)), Text(((a ?? 0) + (b ?? 0)).toString(), style: const TextStyle(fontWeight: FontWeight.w700))]),
      );

  Widget _warning(String text) => Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(color: AppColors.dangerBg, borderRadius: BorderRadius.circular(AppRadii.sm)),
        child: Text(text),
      );

  Widget _section(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          ...children,
        ]),
      );
}
