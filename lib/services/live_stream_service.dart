import 'package:livekit_client/livekit_client.dart';
import 'api_client.dart';

/// Ephemeral, publish-only live camera streaming -- nothing here is ever
/// recorded or written to disk. Wraps the two backend endpoints
/// (POST /devices/{id}/live-stream/start, POST /live-stream/{id}/stop) plus
/// the actual LiveKit publish connection.
class LiveStreamService {
  Room? _room;
  String? sessionId;

  bool get isLive => _room != null;

  /// [triggeringCommandId] is set only for the remote-triggered flow (see
  /// CommandListenerService) -- self-triggered "Go Live" leaves it null.
  Future<Room> start({required String deviceId, String? triggeringCommandId}) async {
    final result = await ApiClient.post(
      '/devices/$deviceId/live-stream/start',
      body: {if (triggeringCommandId != null) 'triggering_command_id': triggeringCommandId},
    );
    sessionId = result['session']['id'];

    final room = Room();
    await room.connect(result['livekit_url'], result['token']);
    // Publishes the camera (and requests the OS camera/mic permission the
    // first time) -- this is the ONLY thing being sent; nothing is written
    // to local storage.
    await room.localParticipant?.setCameraEnabled(true);
    _room = room;
    return room;
  }

  Future<void> stop() async {
    final id = sessionId;
    await _room?.disconnect();
    _room = null;
    if (id != null) {
      await ApiClient.post('/live-stream/$id/stop');
    }
    sessionId = null;
  }
}
