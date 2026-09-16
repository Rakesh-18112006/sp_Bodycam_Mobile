import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'api_client.dart';
import '../models/command_models.dart';

enum CommandChannelStatus { disconnected, connecting, connected }

/// Listens on the backend's single authenticated WebSocket gateway
/// (GET /ws/control_room?token=... -- path name is historical, every role
/// including constable connects here; see docs/FLUTTER_API_HANDOFF.md §L)
/// for `command.sent` events targeting this device, and reconnects with
/// exponential backoff on drop -- mirrors web_dashboard's useOpsSocket.js
/// reference implementation.
///
/// Reacts to every RemoteCommandType the backend defines
/// (start_recording/stop_recording/start_live_stream/stop_live_stream) --
/// unlike the original implementation, which deliberately ignored the
/// recording commands. An unrecognized future command_type is reported via
/// [onUnknownCommand] rather than silently dropped or guessed at.
class CommandListenerService {
  /// Swappable for tests (see test/services/command_listener_reconnect_test.dart)
  /// so the reconnect state machine can be exercised against a fake/failing
  /// channel without a real network connection. Production never overrides
  /// this -- it always opens a genuine WebSocketChannel.
  static WebSocketChannel Function(Uri uri) channelConnector = WebSocketChannel.connect;

  /// Swappable for tests -- the real backoff formula (1s, 2s, 4s, 8s, 15s,
  /// 15s, ...), expressed as a function of retryCount so tests can shrink
  /// it to milliseconds and actually observe the sequence without waiting
  /// out real seconds. Production never overrides this.
  static Duration Function(int retryCount) reconnectDelayFor =
      (retryCount) => Duration(seconds: (1 << retryCount).clamp(1, 15));

  final String deviceId; // backend Device.id (UUID) -- needed for GET /devices/{id}/commands
  WebSocketChannel? _channel;
  StreamSubscription? _channelSub;
  Timer? _reconnectTimer;
  int _retryCount = 0;
  bool _stopped = true;
  CommandChannelStatus status = CommandChannelStatus.disconnected;

  /// Bumped every time a brand-new connection attempt starts (including
  /// each reconnect) and captured by that attempt's onDone/onError
  /// closures. A callback whose captured generation no longer matches
  /// [_connectionGeneration] belongs to a connection this service has
  /// already superseded/torn down -- it must be ignored rather than acted
  /// on. This is the fix for a real physical-device-reproduced bug
  /// (Redmi/OPPO, Wi-Fi toggled off then on): a single dropped connection
  /// could previously have its failure reported through BOTH the stream's
  /// onDone/onError AND the outer catch block, and neither path checked
  /// whether it was still talking about the most recent attempt. Each
  /// report independently called _scheduleReconnect(), which itself
  /// overwrote _reconnectTimer without cancelling the previous one, so
  /// every real failure could spawn multiple live timers, each of which
  /// went on to open its own new socket without ever closing the one(s)
  /// opened by its siblings. Confirmed on real hardware: 16-32 concurrent
  /// WebSocket connections from a single phone within ~5 seconds,
  /// exhausting the backend's SQLAlchemy connection pool
  /// (QueuePool limit of size 5 overflow 10 reached) and making the
  /// backend unresponsive to every other client until manually restarted.
  int _connectionGeneration = 0;

  /// Commands currently being acted on or already resolved this session --
  /// prevents double-execution when the same command arrives twice (a
  /// live WebSocket delivery racing a missed-command poll after reconnect,
  /// per §15 of the implementation brief).
  final Set<String> _handledCommandIds = {};

  final void Function(String commandId, RemoteCommandType commandType) onCommand;
  final void Function(CommandChannelStatus status)? onStatusChanged;
  final void Function(String rawCommandType) onUnknownCommand;

  CommandListenerService({
    required this.deviceId,
    required this.onCommand,
    this.onStatusChanged,
    void Function(String rawCommandType)? onUnknownCommand,
  }) : onUnknownCommand = onUnknownCommand ?? ((_) {});

  Future<void> start() async {
    // Idempotent: a second start() call while already connected/connecting
    // must never spin up a competing connection attempt (race F).
    if (!_stopped && status != CommandChannelStatus.disconnected) return;
    _stopped = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _retryCount = 0;
    await _connect();
  }

  void _setStatus(CommandChannelStatus s) {
    status = s;
    onStatusChanged?.call(s);
  }

  Future<void> _connect() async {
    if (_stopped) return;
    // Defense-in-depth for race E (a stale reconnect timer firing after
    // we're already connected/connecting via some other path): never let
    // a redundant call open a second live socket.
    if (status == CommandChannelStatus.connected || status == CommandChannelStatus.connecting) return;

    final token = await ApiClient.getToken();
    if (token == null || _stopped) return;

    // Every new attempt (initial connect or reconnect) supersedes
    // whatever came before it. Closing the old channel here guarantees
    // Property 1 (never more than one live channel), and bumping the
    // generation means any onDone/onError still in flight for the
    // now-superseded channel will recognize itself as stale and do
    // nothing instead of racing this new attempt (races A/D/E).
    final generation = ++_connectionGeneration;
    _closeChannel();

    _setStatus(CommandChannelStatus.connecting);
    final wsUrl = kApiBaseUrl.replaceFirst('http', 'ws');

    try {
      final channel = channelConnector(Uri.parse('$wsUrl/ws/control_room?token=$token'));
      _channel = channel;

      _channelSub = channel.stream.listen(
        (message) {
          if (generation != _connectionGeneration) return;
          _retryCount = 0;
          _handleMessage(message);
        },
        onDone: () => _handleDisconnect(generation),
        onError: (_) => _handleDisconnect(generation),
      );

      // `channel.ready` completes on the actual WebSocket handshake
      // (HTTP upgrade accepted by the server) succeeding, or throws if it
      // fails/is rejected (e.g. the server closes with 4401/4403/4404
      // before ever accepting -- see websocket.py). Physical-device
      // validation found the UI previously showed "connecting" forever
      // because CONNECTED was only ever set from the first inbound
      // *message*, and this channel is push-only from the server (nothing
      // is sent until a command actually arrives) -- so a perfectly
      // healthy, already-open socket looked indistinguishable from a
      // still-connecting one. This now reflects the real socket lifecycle
      // instead of waiting on traffic that may never come.
      await channel.ready;
      if (_stopped || generation != _connectionGeneration) return;

      // Property 5: a successful connect cancels any reconnect work still
      // pending from an earlier failure (there shouldn't be any left given
      // the generation guard above, but this is the authoritative point
      // where "we are connected" and "a reconnect is scheduled" must never
      // both be true at once).
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _retryCount = 0;
      _setStatus(CommandChannelStatus.connected);
      debugPrint('[bodycam] command channel connected');

      // The very first successful connect (and every reconnect) must catch
      // up on anything issued while we were disconnected -- the WebSocket
      // delivers only NEW events from the moment it connects; it does not
      // replay history (docs/FLUTTER_API_HANDOFF.md §L/§M/§O). Without
      // this, a command sent during a drop/kill window is permanently
      // missed until some unrelated future command happens to arrive.
      unawaited(_recoverMissedCommands());
    } catch (_) {
      debugPrint('[bodycam] command channel connect failed');
      _handleDisconnect(generation);
    }
  }

  /// The SINGLE convergence point for every failure/close path (stream
  /// onDone, stream onError, and a thrown connect()/ready failure) --
  /// this is what makes reconnect scheduling idempotent (Property 3).
  /// Ignores any callback whose [generation] no longer matches the current
  /// connection attempt (already superseded by a newer _connect() call --
  /// races A/D/E), and is a no-op if THIS generation's disconnect has
  /// already been handled (status already disconnected with a reconnect
  /// timer already pending -- race B/C, e.g. onError immediately followed
  /// by onDone for the same dead socket).
  void _handleDisconnect(int generation) {
    if (_stopped) return;
    if (generation != _connectionGeneration) return;
    if (status == CommandChannelStatus.disconnected && _reconnectTimer != null) return;
    _setStatus(CommandChannelStatus.disconnected);
    debugPrint('[bodycam] command channel disconnected');
    _scheduleReconnect();
  }

  void _closeChannel() {
    _channelSub?.cancel();
    _channelSub = null;
    _channel?.sink.close();
    _channel = null;
  }

  void _handleMessage(dynamic message) {
    try {
      final parsed = jsonDecode(message as String);
      if (parsed['event'] == 'command.sent') {
        final data = parsed['data'];
        _dispatch(data['command_id'] as String, data['command_type'] as String);
      } else if (parsed['event'] == 'command.cancelled') {
        // A command we already ack'd/are acting on may be cancelled by
        // Control Room mid-flight -- we cannot un-perform a physical
        // camera action already taken, but we can at least stop treating
        // a not-yet-started one as pending so a stale "sent" doesn't get
        // acted on later by a delayed retry path.
        final data = parsed['data'];
        final id = data['command_id'] as String?;
        if (id != null) _handledCommandIds.add(id);
      }
    } catch (_) {
      // Ignore malformed frames rather than crashing the listener.
    }
  }

  void _dispatch(String commandId, String rawCommandType) {
    if (_handledCommandIds.contains(commandId)) return; // already handled via WS or the missed-command poll
    final type = RemoteCommandType.fromWire(rawCommandType);
    if (type == null) {
      onUnknownCommand(rawCommandType);
      return;
    }
    _handledCommandIds.add(commandId);
    onCommand(commandId, type);
  }

  /// GET /devices/{device_id}/commands, replayed through the SAME
  /// dispatch path (and therefore the same de-duplication) as a live
  /// WebSocket delivery -- per §15, "use the same command execution
  /// handler for both". Only `pending`/`sent` commands are actionable; a
  /// command already `acknowledged`/`executed`/`failed`/`cancelled` is
  /// history, not work to redo.
  Future<void> _recoverMissedCommands() async {
    try {
      final result = await ApiClient.get('/devices/$deviceId/commands');
      final commands = (result as List<dynamic>).map((e) => RemoteCommandResponse.fromJson(e as Map<String, dynamic>));
      for (final command in commands) {
        if (command.status == RemoteCommandStatus.pending || command.status == RemoteCommandStatus.sent) {
          if (command.commandType == null) {
            onUnknownCommand('(unrecognized command_type on ${command.id})');
            continue;
          }
          if (_handledCommandIds.contains(command.id)) continue;
          _handledCommandIds.add(command.id);
          onCommand(command.id, command.commandType!);
        }
      }
    } catch (_) {
      // Offline/auth failure -- this will be retried on the next
      // reconnect; never crashes the listener over a missed poll.
    }
  }

  void _scheduleReconnect() {
    if (_stopped) return;
    // Property 2: never let more than one reconnect timer be alive --
    // cancel any previous one before creating its replacement. Combined
    // with _handleDisconnect's idempotency this should already be
    // unreachable with a non-null _reconnectTimer, but this is the actual
    // guarantee, not just a hopeful side effect of the caller behaving.
    _reconnectTimer?.cancel();
    final delay = reconnectDelayFor(_retryCount);
    _retryCount++;
    _reconnectTimer = Timer(delay, _connect);
  }

  /// ACK a command. A 409 here means the backend already considers this
  /// command acknowledged (e.g. this exact command was already ack'd by an
  /// earlier delivery before this process restarted) -- per
  /// docs/FLUTTER_API_HANDOFF.md §M ("Duplicate /ack calls return 409 --
  /// safe to ignore/treat as already-handled, never retry indefinitely"),
  /// this is treated as success, not re-thrown, so a transient duplicate
  /// delivery can never silently abort the rest of the command-handling
  /// flow the way the original implementation's unguarded `await ack(...)`
  /// did.
  Future<void> ackCommand(String commandId) async {
    try {
      await ApiClient.post('/commands/$commandId/ack');
    } on ApiException catch (e) {
      if (!e.isConflict) rethrow;
    }
  }

  Future<void> reportResult(String commandId, {required bool success, String? failureReason}) {
    return ApiClient.post('/commands/$commandId/result', body: {
      'success': success,
      if (failureReason != null) 'failure_reason': failureReason,
    });
  }

  void stop() {
    _stopped = true;
    // Invalidates any in-flight onDone/onError/catch callback immediately,
    // even one already queued in the event loop before this call.
    _connectionGeneration++;
    _setStatus(CommandChannelStatus.disconnected);
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _closeChannel();
  }
}
