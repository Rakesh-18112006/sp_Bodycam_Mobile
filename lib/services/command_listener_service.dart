import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'api_client.dart';

/// Listens on the backend's single authenticated WebSocket gateway
/// (GET /ws/control_room?token=... -- path name is historical, every role
/// including constable connects here; see docs/FLUTTER_API_HANDOFF.md §L)
/// for `command.sent` events targeting this device, and reconnects with
/// exponential backoff on drop -- mirrors web_dashboard's useOpsSocket.js
/// reference implementation.
///
/// Only reacts to `start_live_stream` / `stop_live_stream` command types;
/// every other command_type (e.g. the existing start_recording/
/// stop_recording) is deliberately ignored here -- this app only
/// implements the live-streaming half of the API contract.
class CommandListenerService {
  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  int _retryCount = 0;
  bool _stopped = false;

  final void Function(String commandId, String commandType) onLiveStreamCommand;

  CommandListenerService({required this.onLiveStreamCommand});

  Future<void> start() async {
    _stopped = false;
    await _connect();
  }

  Future<void> _connect() async {
    final token = await ApiClient.getToken();
    if (token == null || _stopped) return;

    final wsUrl = kApiBaseUrl.replaceFirst('http', 'ws');
    final channel = WebSocketChannel.connect(Uri.parse('$wsUrl/ws/control_room?token=$token'));
    _channel = channel;

    channel.stream.listen(
      (message) {
        _retryCount = 0;
        try {
          final parsed = jsonDecode(message);
          if (parsed['event'] == 'command.sent') {
            final data = parsed['data'];
            final commandType = data['command_type'];
            if (commandType == 'start_live_stream' || commandType == 'stop_live_stream') {
              onLiveStreamCommand(data['command_id'], commandType);
            }
          }
        } catch (_) {
          // Ignore malformed frames rather than crashing the listener.
        }
      },
      onDone: _scheduleReconnect,
      onError: (_) => _scheduleReconnect(),
    );
  }

  void _scheduleReconnect() {
    if (_stopped) return;
    final delaySeconds = (1 << _retryCount).clamp(1, 15);
    _retryCount++;
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), _connect);
  }

  Future<void> ackCommand(String commandId) => ApiClient.post('/commands/$commandId/ack');

  Future<void> reportResult(String commandId, {required bool success, String? failureReason}) {
    return ApiClient.post('/commands/$commandId/result', body: {
      'success': success,
      if (failureReason != null) 'failure_reason': failureReason,
    });
  }

  void stop() {
    _stopped = true;
    _reconnectTimer?.cancel();
    _channel?.sink.close();
  }
}
