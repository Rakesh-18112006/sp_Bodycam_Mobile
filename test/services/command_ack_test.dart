// Direct regression test for the original audit's other CRITICAL finding:
// `await ackCommand(...)` used to sit OUTSIDE the calling code's
// try/catch, so any failure -- including the backend's documented,
// expected 409 on a duplicate ack -- silently aborted the entire command
// flow with zero feedback to the constable or Control Room. ackCommand()
// now owns that distinction itself: a 409 is swallowed (per
// docs/FLUTTER_API_HANDOFF.md §M, "safe to ignore/treat as already-handled"),
// while every other failure still propagates so a genuine problem is never
// silently lost.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:police_body_cam/services/api_client.dart';
import 'package:police_body_cam/services/command_listener_service.dart';

class _FakeStore implements TokenStore {
  @override
  Future<void> delete(String key) async {}
  @override
  Future<String?> read(String key) async => 'test-token';
  @override
  Future<void> write(String key, String value) async {}
}

void main() {
  setUp(() {
    ApiClient.tokenStore = _FakeStore();
  });

  test('ackCommand() swallows a 409 (duplicate ack) instead of throwing', () async {
    ApiClient.httpClient = MockClient((request) async {
      expect(request.url.path, '/commands/cmd-1/ack');
      return http.Response(jsonEncode({'detail': 'Cannot acknowledge a command in status acknowledged'}), 409);
    });

    final listener = CommandListenerService(deviceId: 'device-1', onCommand: (_, _) {}, onUnknownCommand: (_) {});
    // Must complete without throwing.
    await listener.ackCommand('cmd-1');
  });

  test('ackCommand() still propagates a genuine failure (e.g. 404)', () async {
    ApiClient.httpClient = MockClient((request) async {
      return http.Response(jsonEncode({'detail': 'Command not found'}), 404);
    });

    final listener = CommandListenerService(deviceId: 'device-1', onCommand: (_, _) {}, onUnknownCommand: (_) {});
    await expectLater(
      () => listener.ackCommand('cmd-missing'),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404)),
    );
  });

  test('reportResult() sends success:true only when the caller says so', () async {
    late Map body;
    ApiClient.httpClient = MockClient((request) async {
      body = jsonDecode(request.body) as Map;
      return http.Response(jsonEncode({
        'id': 'cmd-1',
        'device_id': 'device-1',
        'issued_by': 'user-1',
        'command_type': 'start_live_stream',
        'status': 'failed',
        'created_at': '2026-01-01T00:00:00Z',
        'sent_at': null,
        'acknowledged_at': null,
        'executed_at': null,
        'failure_reason': 'camera permission denied',
      }), 200);
    });

    final listener = CommandListenerService(deviceId: 'device-1', onCommand: (_, _) {}, onUnknownCommand: (_) {});
    await listener.reportResult('cmd-1', success: false, failureReason: 'camera permission denied');
    expect(body['success'], false);
    expect(body['failure_reason'], 'camera permission denied');
  });
}
