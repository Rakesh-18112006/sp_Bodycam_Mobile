import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import '../services/auth_service.dart';
import '../services/device_service.dart';
import '../services/live_stream_service.dart';
import '../services/command_listener_service.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _liveStream = LiveStreamService();
  CommandListenerService? _commandListener;

  String? _deviceId;
  bool _initializing = true;
  bool _busy = false;
  bool _live = false;
  String? _error;
  VideoTrack? _localVideoTrack;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final identifier = await DeviceService.getOrCreateDeviceIdentifier();
      final device = await DeviceService.register(deviceIdentifier: identifier);
      _deviceId = device['id'];

      // Reacts to a remote start_live_stream/stop_live_stream command even
      // while this screen is backgrounded, as long as the app process is
      // still alive (see mobile_app/README.md for the current limitation:
      // there is no native Android foreground service yet, so a fully
      // killed app will not receive this until reopened).
      _commandListener = CommandListenerService(onLiveStreamCommand: _handleRemoteCommand);
      await _commandListener!.start();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  Future<void> _handleRemoteCommand(String commandId, String commandType) async {
    await _commandListener!.ackCommand(commandId);
    try {
      if (commandType == 'start_live_stream' && !_liveStream.isLive) {
        await _goLive(triggeringCommandId: commandId);
      } else if (commandType == 'stop_live_stream' && _liveStream.isLive) {
        await _stopLive();
      }
      await _commandListener!.reportResult(commandId, success: true);
    } catch (e) {
      await _commandListener!.reportResult(commandId, success: false, failureReason: e.toString());
    }
  }

  Future<void> _goLive({String? triggeringCommandId}) async {
    if (_deviceId == null || _liveStream.isLive) return;
    setState(() => _busy = true);
    try {
      final room = await _liveStream.start(deviceId: _deviceId!, triggeringCommandId: triggeringCommandId);
      final videoTrack = room.localParticipant?.videoTrackPublications.firstOrNull?.track as VideoTrack?;
      setState(() {
        _live = true;
        _localVideoTrack = videoTrack;
      });
    } catch (e) {
      setState(() => _error = e.toString());
      rethrow;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopLive() async {
    setState(() => _busy = true);
    try {
      await _liveStream.stop();
      setState(() {
        _live = false;
        _localVideoTrack = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    _commandListener?.stop();
    if (_liveStream.isLive) await _liveStream.stop();
    await AuthService.logout();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  @override
  void dispose() {
    _commandListener?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Body Camera'),
        actions: [IconButton(icon: const Icon(Icons.logout), onPressed: _logout)],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!, style: const TextStyle(color: Colors.red)),
                ),
              // Mandatory visible indicator whenever the camera is live --
              // whether self-triggered or remote-triggered. This must
              // never be silent (see plan: transparency requirement).
              if (_live)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  color: Colors.red.shade700,
                  child: const Text(
                    '● Camera is LIVE -- being viewed by Control Room',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                ),
              const SizedBox(height: 16),
              Expanded(
                child: _live && _localVideoTrack != null
                    ? VideoTrackRenderer(_localVideoTrack!)
                    : const Center(child: Text('Not live')),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _busy ? null : (_live ? _stopLive : _goLive),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _live ? Colors.grey : Colors.red,
                  minimumSize: const Size.fromHeight(50),
                ),
                child: _busy
                    ? const CircularProgressIndicator()
                    : Text(_live ? 'Stop Live Stream' : 'Go Live', style: const TextStyle(fontSize: 18)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
