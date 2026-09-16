// Verifies DeviceService sends exactly the request shapes
// backend/app/schemas.py::DeviceRegisterRequest/DeviceHeartbeatRequest/
// DeviceBatteryReportRequest expect, and that HeartbeatScheduler actually
// calls the endpoint on a timer (this is the direct regression test for
// the original audit's #1 finding: heartbeat was implemented but never
// invoked anywhere).
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:police_body_cam/services/api_client.dart';
import 'package:police_body_cam/services/device_service.dart';

class _FakeStore implements TokenStore {
  final Map<String, String> values = {};
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

Map<String, dynamic> _deviceJson({String status = 'online'}) => {
      'id': 'device-1',
      'constable_id': 'constable-1',
      'device_identifier': 'uuid-1',
      'platform': 'android',
      'app_version': '1.0.0',
      'device_model': null,
      'status': status,
      'last_heartbeat_at': '2026-01-01T00:00:00Z',
      'last_seen_at': '2026-01-01T00:00:00Z',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': null,
      'battery_percent': 80,
      'is_charging': false,
      'latitude': null,
      'longitude': null,
      'location_updated_at': null,
    };

void main() {
  setUp(() async {
    final store = _FakeStore();
    await store.write('access_token', 't');
    ApiClient.tokenStore = store;
  });

  test('register() sends device_identifier/platform/app_version', () async {
    late Map body;
    ApiClient.httpClient = MockClient((request) async {
      expect(request.url.path, '/devices/register');
      body = jsonDecode(request.body) as Map;
      return http.Response(jsonEncode(_deviceJson()), 200);
    });

    await DeviceService.register(deviceIdentifier: 'uuid-1');
    expect(body['device_identifier'], 'uuid-1');
    expect(body['platform'], 'android');
    expect(body.containsKey('app_version'), isTrue);
  });

  test('heartbeat() omits battery fields when not supplied (both are optional server-side)', () async {
    late Map body;
    ApiClient.httpClient = MockClient((request) async {
      expect(request.url.path, '/devices/heartbeat');
      body = jsonDecode(request.body) as Map;
      return http.Response(jsonEncode(_deviceJson()), 200);
    });

    await DeviceService.heartbeat(deviceIdentifier: 'uuid-1');
    expect(body.containsKey('battery_percent'), isFalse);
    expect(body.containsKey('is_charging'), isFalse);
  });

  test('heartbeat() includes real battery data when supplied -- never fabricated', () async {
    late Map body;
    ApiClient.httpClient = MockClient((request) async {
      body = jsonDecode(request.body) as Map;
      return http.Response(jsonEncode(_deviceJson()), 200);
    });

    await DeviceService.heartbeat(deviceIdentifier: 'uuid-1', batteryPercent: 42, isCharging: true);
    expect(body['battery_percent'], 42);
    expect(body['is_charging'], true);
  });

  test('reportBattery() requires battery_percent (matches schemas.DeviceBatteryReportRequest)', () async {
    late Map body;
    ApiClient.httpClient = MockClient((request) async {
      expect(request.url.path, '/devices/battery');
      body = jsonDecode(request.body) as Map;
      return http.Response('', 200);
    });

    await DeviceService.reportBattery(deviceIdentifier: 'uuid-1', batteryPercent: 55);
    expect(body['battery_percent'], 55);
  });

  test('HeartbeatScheduler actually calls the endpoint -- the original audit found this wired up but never invoked', () async {
    var callCount = 0;
    ApiClient.httpClient = MockClient((request) async {
      if (request.url.path == '/devices/heartbeat') callCount++;
      return http.Response(jsonEncode(_deviceJson()), 200);
    });

    final scheduler = HeartbeatScheduler(
      deviceIdentifier: 'uuid-1',
      interval: const Duration(milliseconds: 20),
      batteryPercentProvider: () => 90,
      isChargingProvider: () => false,
    );
    scheduler.start();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    scheduler.stop();

    expect(callCount, greaterThanOrEqualTo(2), reason: 'an immediate beat plus at least one periodic tick should have fired');
  });
}
