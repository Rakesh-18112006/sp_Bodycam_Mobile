import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:police_body_cam/services/api_client.dart';
import 'package:police_body_cam/services/network_alert_service.dart';

class _FakeStore implements TokenStore {
  @override
  Future<void> delete(String key) async {}
  @override
  Future<String?> read(String key) async => 'test-token';
  @override
  Future<void> write(String key, String value) async {}
}

class _FakeChannel with StreamChannelMixin implements WebSocketChannel {
  final controller = StreamController<dynamic>();
  final sent = <dynamic>[];
  @override
  Stream get stream => controller.stream;
  @override
  Future<void> get ready => Future.value();
  @override
  WebSocketSink get sink => _Sink(this);
  @override
  String? get protocol => null;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  void emit(Map<String, dynamic> m) => controller.add(jsonEncode(m));
}

class _Sink implements WebSocketSink {
  final _FakeChannel o;
  _Sink(this.o);
  @override
  Future close([int? c, String? r]) async {}
  @override
  void add(dynamic e) => o.sent.add(e);
  @override
  void addError(Object e, [StackTrace? s]) {}
  @override
  Future addStream(Stream s) async {}
  @override
  Future get done => Future.value();
}

Map<String, dynamic> alertJson(String id, {String title = 'FIRE', String severity = 'emergency', String? expires}) => {
      'alert_id': id,
      'site_id': 'site-1',
      'site_name': 'Huawei Building',
      'title': title,
      'message': 'Evacuate',
      'severity': severity,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'expires_at': expires,
      'state': 'sent',
    };

void main() {
  late _FakeChannel channel;
  late List<String> calls;
  late List<Map<String, dynamic>> pending;
  var ackStatus = 200;

  setUp(() {
    ApiClient.tokenStore = _FakeStore();
    channel = _FakeChannel();
    calls = [];
    pending = [];
    ackStatus = 200;
    NetworkAlertService.channelConnector = (_) => channel;
    NetworkAlertService.reconnectDelayFor = (n) => const Duration(milliseconds: 5);
    ApiClient.httpClient = MockClient((req) async {
      calls.add('${req.method} ${req.url.path}');
      if (req.url.path == '/mobile/v1/networks') return http.Response(jsonEncode([]), 200);
      if (req.url.path == '/mobile/v1/alerts/pending') return http.Response(jsonEncode(pending), 200);
      if (req.url.path.endsWith('/ack')) return http.Response(jsonEncode({'alert_id': 'x', 'state': 'acknowledged'}), ackStatus);
      if (req.url.path.endsWith('/received')) return http.Response(jsonEncode({'alert_id': 'x', 'state': 'received'}), 200);
      if (req.url.path == '/mobile/v1/network/login') return http.Response(jsonEncode({'detail': 'nope'}), 404);
      return http.Response('{}', 200);
    });
    NetworkAlertService.instance.stop();
  });

  tearDown(() {
    NetworkAlertService.instance.stop();
    NetworkAlertService.channelConnector = WebSocketChannel.connect;
  });

  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 40));

  test('a pushed alert is shown once, de-duplicated by id, and receipt is reported once', () async {
    final svc = NetworkAlertService.instance;
    await svc.start();
    await pump();
    expect(svc.status, AlertChannelStatus.connected);
    channel.emit({'event': 'network.alert', 'data': alertJson('a1')});
    channel.emit({'event': 'network.alert', 'data': alertJson('a1')});
    await pump();
    expect(svc.activeAlerts.map((a) => a.alertId), ['a1']);
    expect(calls.where((c) => c == 'POST /mobile/v1/alerts/a1/received').length, 1);
  });

  test('an alert raised while offline is fetched from /alerts/pending on connect', () async {
    pending = [alertJson('queued-1')];
    final svc = NetworkAlertService.instance;
    await svc.start();
    await pump();
    expect(svc.activeAlerts.single.alertId, 'queued-1');
  });

  test('alert_cleared removes the alert from the screen', () async {
    final svc = NetworkAlertService.instance;
    await svc.start();
    await pump();
    channel.emit({'event': 'network.alert', 'data': alertJson('a2')});
    await pump();
    expect(svc.activeAlerts, isNotEmpty);
    channel.emit({'event': 'network.alert_cleared', 'data': {'alert_id': 'a2', 'site_id': 'site-1'}});
    await pump();
    expect(svc.activeAlerts, isEmpty);
  });

  test('acknowledge hides the alert at once and posts the ack; a failed ack is retried and the alert stays hidden', () async {
    final svc = NetworkAlertService.instance;
    await svc.start();
    await pump();
    ackStatus = 503;
    channel.emit({'event': 'network.alert', 'data': alertJson('a3')});
    await pump();
    await svc.acknowledge('a3');
    expect(svc.activeAlerts, isEmpty);
    // The server still lists it as pending (the ack never arrived), but the phone keeps it hidden and retries the ack.
    pending = [alertJson('a3')];
    ackStatus = 200;
    await svc.fetchPending();
    expect(svc.activeAlerts, isEmpty);
    expect(calls.where((c) => c == 'POST /mobile/v1/alerts/a3/ack').length, 2);
  });

  test('expired alerts are never shown', () async {
    final svc = NetworkAlertService.instance;
    await svc.start();
    await pump();
    channel.emit({'event': 'network.alert', 'data': alertJson('old', expires: DateTime.now().toUtc().subtract(const Duration(minutes: 1)).toIso8601String())});
    await pump();
    expect(svc.activeAlerts, isEmpty);
  });

  test('login to a network the officer is not assigned to returns a readable message', () async {
    final svc = NetworkAlertService.instance;
    await svc.start();
    final msg = await svc.login('NOPE');
    expect(msg, contains('not assigned'));
  });
}
