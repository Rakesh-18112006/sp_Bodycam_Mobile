import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/network_alert_models.dart';
import 'api_client.dart';

enum AlertChannelStatus { stopped, connecting, connected, disconnected }

/// Network login + building alerts.
///
/// * Network login: the officer logs in to a network (a monitored site such as the Huawei building) with
///   POST /mobile/v1/network/login. The server only accepts sites the officer is assigned to and keeps the login state.
/// * Alerts: a dedicated authenticated WebSocket (/ws/control_room, the backend's single gateway) delivers `network.alert`
///   and `network.alert_cleared`. After every (re)connect, and every [pollInterval] as a fallback, the app also pulls
///   GET /mobile/v1/alerts/pending, so an alert raised while the phone was offline is still shown once it is back.
/// * Alerts are de-duplicated by alert id. The app reports `received`, and the person's ACKNOWLEDGE is sent to the server;
///   if that call fails the acknowledgement is retried on the next connect and the alert is not shown again meanwhile.
///
/// A WebSocket write by the server is not proof the person saw the alert; only `acknowledged` is.
class NetworkAlertService extends ChangeNotifier {
  NetworkAlertService._();
  static final NetworkAlertService instance = NetworkAlertService._();

  /// Test seams, same pattern as CommandListenerService. Production never overrides them.
  static WebSocketChannel Function(Uri uri) channelConnector = WebSocketChannel.connect;
  static Duration Function(int retryCount) reconnectDelayFor = (n) => Duration(seconds: (1 << n).clamp(1, 30)) + Duration(milliseconds: Random().nextInt(1000));
  static Duration pingInterval = const Duration(seconds: 25);
  static Duration pollInterval = const Duration(seconds: 30);

  AlertChannelStatus status = AlertChannelStatus.stopped;
  List<NetworkInfo> networks = const [];
  String? lastError;

  final Map<String, NetworkAlert> _active = {};
  final Set<String> _acked = {}; // acknowledged locally; stays hidden even if the server copy is not yet updated
  final Set<String> _ackFailed = {}; // acknowledgements still to be delivered to the server
  final Set<String> _receivedReported = {};

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  Timer? _pollTimer;
  int _retry = 0;
  int _generation = 0;
  bool _stopped = true;

  /// Alerts to show right now, newest first. Expired ones are never listed.
  List<NetworkAlert> get activeAlerts {
    final now = DateTime.now();
    final l = _active.values.where((a) => !a.isExpired(now) && !_acked.contains(a.alertId)).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return l;
  }

  bool get isLoggedInAnywhere => networks.any((n) => n.loggedIn);

  Future<void> start() async {
    if (!_stopped) return;
    _stopped = false;
    _retry = 0;
    unawaited(refreshNetworks());
    await _connect();
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) => unawaited(fetchPending()));
  }

  void stop() {
    _stopped = true;
    _generation++;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _pollTimer?.cancel();
    _reconnectTimer = _pingTimer = _pollTimer = null;
    _closeChannel();
    status = AlertChannelStatus.stopped;
    _active.clear();
    _acked.clear();
    _ackFailed.clear();
    _receivedReported.clear();
    networks = const [];
    notifyListeners();
  }

  // ---------------------------------------------------------------- network login

  Future<void> refreshNetworks() async {
    try {
      final r = await ApiClient.get('/mobile/v1/networks');
      networks = (r as List<dynamic>).map((e) => NetworkInfo.fromJson(e as Map<String, dynamic>)).toList();
      lastError = null;
    } catch (e) {
      lastError = e.toString();
    }
    notifyListeners();
  }

  /// Returns null on success, otherwise a message for the user.
  Future<String?> login(String siteCode) async {
    try {
      await ApiClient.post('/mobile/v1/network/login', body: {'site_code': siteCode.trim(), 'device_identifier': await ApiClient.getDeviceIdentifier()});
    } on ApiException catch (e) {
      return e.isNotFound ? 'That network was not found, or you are not assigned to it. Ask the control room.' : e.detail;
    } catch (_) {
      return 'Could not reach the server. Check the connection and try again.';
    }
    await refreshNetworks();
    await fetchPending();
    return null;
  }

  Future<String?> logout(String siteCode) async {
    try {
      await ApiClient.post('/mobile/v1/network/logout', body: {'site_code': siteCode});
    } on ApiException catch (e) {
      return e.detail;
    } catch (_) {
      return 'Could not reach the server. Check the connection and try again.';
    }
    _active.removeWhere((_, a) => networks.any((n) => n.siteId == a.siteId && n.siteCode == siteCode));
    await refreshNetworks();
    return null;
  }

  // ---------------------------------------------------------------- alerts

  Future<void> fetchPending() async {
    if (_stopped) return;
    try {
      await _flushAcks();
      final r = await ApiClient.get('/mobile/v1/alerts/pending');
      final fresh = (r as List<dynamic>).map((e) => NetworkAlert.fromJson(e as Map<String, dynamic>)).toList();
      final freshIds = fresh.map((a) => a.alertId).toSet();
      // Alerts the server no longer lists (cleared, expired, acknowledged elsewhere, logged out) leave the screen.
      _active.removeWhere((id, _) => !freshIds.contains(id));
      for (final a in fresh) {
        _add(a);
      }
      notifyListeners();
    } catch (_) {
      // Offline: the WebSocket reconnect or the next poll will retry.
    }
  }

  void _add(NetworkAlert a) {
    if (_acked.contains(a.alertId)) return;
    _active[a.alertId] = a;
    unawaited(_reportReceived(a.alertId));
  }

  /// Marked before the request goes out so two frames for the same alert cannot both send it; cleared on failure so a
  /// later frame or poll tries again.
  Future<void> _reportReceived(String id) async {
    if (!_receivedReported.add(id)) return;
    try {
      await ApiClient.post('/mobile/v1/alerts/$id/received');
    } catch (_) {
      _receivedReported.remove(id);
    }
  }

  /// The person pressed ACKNOWLEDGE. The alert disappears at once; delivery to the server is retried until it succeeds.
  Future<void> acknowledge(String alertId) async {
    _acked.add(alertId);
    _active.remove(alertId);
    notifyListeners();
    try {
      await ApiClient.post('/mobile/v1/alerts/$alertId/ack');
      _ackFailed.remove(alertId);
    } on ApiException catch (e) {
      if (!e.isNotFound) _ackFailed.add(alertId); // 404: the server no longer knows it, nothing to retry
    } catch (_) {
      _ackFailed.add(alertId);
    }
  }

  Future<void> _flushAcks() async {
    for (final id in _ackFailed.toList()) {
      try {
        await ApiClient.post('/mobile/v1/alerts/$id/ack');
        _ackFailed.remove(id);
      } on ApiException catch (e) {
        if (e.isNotFound) _ackFailed.remove(id);
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------- websocket

  Future<void> _connect() async {
    if (_stopped) return;
    if (status == AlertChannelStatus.connected || status == AlertChannelStatus.connecting) return;
    final token = await ApiClient.getToken();
    if (token == null || _stopped) return;

    final generation = ++_generation;
    _closeChannel();
    status = AlertChannelStatus.connecting;
    notifyListeners();
    try {
      final ws = kApiBaseUrl.replaceFirst('http', 'ws');
      final channel = channelConnector(Uri.parse('$ws/ws/control_room?token=$token'));
      _channel = channel;
      _sub = channel.stream.listen(
        (m) {
          if (generation == _generation) _onMessage(m);
        },
        onDone: () => _onDisconnect(generation),
        onError: (_) => _onDisconnect(generation),
      );
      await channel.ready;
      if (_stopped || generation != _generation) return;
      _retry = 0;
      status = AlertChannelStatus.connected;
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(pingInterval, (_) {
        try {
          _channel?.sink.add('ping'); // the server answers every client frame, which keeps proxies from idling the socket out
        } catch (_) {}
      });
      notifyListeners();
      unawaited(fetchPending()); // the socket only carries new alerts; catch up on anything raised while offline
    } catch (_) {
      _onDisconnect(generation);
    }
  }

  void _onDisconnect(int generation) {
    if (_stopped || generation != _generation) return;
    if (status == AlertChannelStatus.disconnected && _reconnectTimer != null) return;
    status = AlertChannelStatus.disconnected;
    _pingTimer?.cancel();
    notifyListeners();
    _reconnectTimer?.cancel();
    final delay = reconnectDelayFor(_retry);
    _retry = min(_retry + 1, 10);
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      status = AlertChannelStatus.disconnected;
      unawaited(_connect());
    });
  }

  void _closeChannel() {
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  void _onMessage(dynamic message) {
    try {
      final parsed = jsonDecode(message as String) as Map<String, dynamic>;
      final data = parsed['data'];
      switch (parsed['event']) {
        case 'network.alert':
          _add(NetworkAlert.fromJson(data as Map<String, dynamic>));
          notifyListeners();
          break;
        case 'network.alert_cleared':
          final id = (data as Map<String, dynamic>)['alert_id'] as String?;
          if (id != null && _active.remove(id) != null) notifyListeners();
          break;
      }
    } catch (_) {
      // Malformed frame: ignore rather than crash the listener.
    }
  }
}
