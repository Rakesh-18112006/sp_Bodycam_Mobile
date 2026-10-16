import 'package:livekit_client/livekit_client.dart';
import 'api_client.dart';
import 'network_hopping_service.dart';
import 'receiver_client.dart';

/// Live view cannot be provided right now (Network Hopping with no site-local
/// live service and no route to the control room). Recording and chunk upload
/// are NOT affected by this; the message says so.
class LiveUnavailableException implements Exception {
  final String message;
  LiveUnavailableException(this.message);
  @override
  String toString() => message;
}

/// Ephemeral, publish-only live camera streaming -- nothing here is ever
/// recorded or written to disk. Wraps the two backend endpoints
/// (POST /devices/{id}/live-stream/start, POST /live-stream/{id}/stop) plus
/// the actual LiveKit publish connection.
class LiveStreamService {
  Room? _room;
  String? sessionId;
  CameraPosition _cameraPosition = CameraPosition.back;
  // True when this live view is published to a site-local LiveKit through a
  // receiver (no control-room session exists to stop afterwards).
  bool _siteLocal = false;

  bool get isLive => _room != null;
  CameraPosition get cameraPosition => _cameraPosition;

  /// [triggeringCommandId] is set only for the remote-triggered flow (see
  /// CommandListenerService) -- self-triggered "Go Live" leaves it null.
  /// [cameraPosition] defaults to the back/outward-facing camera --
  /// matching the body-camera recording convention -- rather than
  /// livekit_client's own default of [CameraPosition.front], which is why
  /// "Go Live" previously always started on the front camera with no way
  /// to choose otherwise.
  Future<Room> start({
    required String deviceId,
    String? triggeringCommandId,
    CameraPosition cameraPosition = CameraPosition.back,
  }) async {
    final nh = NetworkHoppingService.instance;
    await nh.load();
    Map<String, dynamic>? result;
    _siteLocal = false;
    if (nh.enabled && nh.grantValid) {
      // Network Hopping: prefer the site-local live service the receiver
      // fronts. It is only as live as the site LAN; nothing is routed to the
      // control room that cannot be reached.
      final session = await nh.receiverSession();
      if (session != null) {
        try {
          final r = await ReceiverClient.liveStart(session);
          result = {'livekit_url': r['livekit_url'], 'token': r['token']};
          _siteLocal = true;
        } on ReceiverException catch (e) {
          if (e.code != 'local_live_not_configured') {
            throw LiveUnavailableException('Site live view refused: ${e.message}. Recording is unaffected.');
          }
        }
      }
      if (result == null && !await nh.centralReachable()) {
        throw LiveUnavailableException(
            'Live view is unavailable: this site has no local live service and the control room cannot be reached. Recording and upload to the site receiver continue normally.');
      }
    }
    if (result == null) {
      final central = await ApiClient.post(
        '/devices/$deviceId/live-stream/start',
        body: {if (triggeringCommandId != null) 'triggering_command_id': triggeringCommandId},
      );
      sessionId = central['session']['id'];
      result = {'livekit_url': central['livekit_url'], 'token': central['token']};
    }
    _cameraPosition = cameraPosition;

    final room = Room();
    // Real physical-device testing (Docker Desktop/WSL2 host + a phone on
    // the host's own mobile hotspot) found the underlying ICE/PeerConnection
    // negotiation genuinely succeeding -- confirmed via livekit-server logs
    // showing a healthy, low-RTT connection -- but only ~20-30s after
    // connect() was called, well past livekit_client's own default 10s
    // ConnectOptions.timeouts.connection (see engine.dart's
    // "Timed out waiting for PeerConnection to connect" check). The Dart
    // call was throwing MediaConnectException before the real, working
    // connection had a chance to finish, discarding a Room the SDK's own
    // native layer had already connected. Raising just this timeout (still
    // the SDK's own documented, public ConnectOptions knob -- nothing about
    // ICE/STUN/TURN behavior itself is changed) gives slower real-world
    // networks enough time without masking a genuine failure indefinitely.
    await room.connect(
      result['livekit_url'] as String,
      result['token'] as String,
      connectOptions: const ConnectOptions(
        timeouts: Timeouts(
          connection: Duration(seconds: 30),
          debounce: Duration(milliseconds: 20),
          publish: Duration(seconds: 10),
          subscribe: Duration(seconds: 10),
          peerConnection: Duration(seconds: 10),
          iceRestart: Duration(seconds: 10),
        ),
      ),
    );
    // Publishes the camera (and requests the OS camera/mic permission the
    // first time) -- this is the ONLY thing being sent; nothing is written
    // to local storage. Deliberately NOT passing cameraCaptureOptions here
    // -- real physical-device testing found that publishing the FIRST
    // track with an explicit CameraPosition (rather than the SDK's own
    // default, unqualified setCameraEnabled(true) call) resulted in the
    // local camera preview working but the track never actually reaching
    // the LiveKit server (0 video tracks server-side across a clean 3-
    // minute test, no exceptions thrown). The plain, options-less call is
    // the one path with direct proof of actually publishing to a real
    // Control Room viewer. If a non-default starting camera is wanted,
    // switch to it via the SAME restartTrack-based path as [switchCamera]
    // immediately after this succeeds, rather than through the initial
    // publish call.
    await room.localParticipant?.setCameraEnabled(true);
    _room = room;
    _cameraPosition = CameraPosition.front; // the SDK's own unqualified default
    if (cameraPosition != CameraPosition.front) {
      await switchCamera();
    }
    return room;
  }

  /// Switches the published camera without leaving the LiveKit room or
  /// interrupting the session -- uses livekit_client's own
  /// LocalVideoTrack.setCameraPosition, which restarts just the capture
  /// track in place (same published track ID) rather than
  /// unpublish+republish, so the Control Room viewer never sees the
  /// participant disappear.
  Future<void> switchCamera() async {
    final room = _room;
    if (room == null) return;
    final newPosition = _cameraPosition == CameraPosition.back ? CameraPosition.front : CameraPosition.back;
    final track = room.localParticipant?.videoTrackPublications.firstOrNull?.track;
    if (track is LocalVideoTrack) {
      await track.setCameraPosition(newPosition);
      _cameraPosition = newPosition;
    }
  }

  Future<void> stop() async {
    final id = sessionId;
    await _room?.disconnect();
    _room = null;
    if (id != null && !_siteLocal) {
      await ApiClient.post('/live-stream/$id/stop');
    }
    _siteLocal = false;
    sessionId = null;
  }
}
