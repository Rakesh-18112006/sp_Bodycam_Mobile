// Network Hopping provisioning, endpoint trust, central/receiver health and target selection, against mocked HTTP.
import 'dart:convert';
import 'dart:io';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:police_body_cam/services/api_client.dart';
import 'package:police_body_cam/services/network_hopping_service.dart';

import '../helpers/test_keys.dart';

const _site = '11111111-1111-1111-1111-111111111111';
const _dev = '22222222-2222-2222-2222-222222222222';
const _officer = '33333333-3333-3333-3333-333333333333';
const _central = 'https://bodycam-backend-qo1e.onrender.com'; // kApiBaseUrl default
const _recv = 'https://receiver.site.test:8443';

class _Store implements TokenStore {
  final m = <String, String>{};
  @override
  Future<void> delete(String key) async => m.remove(key);
  @override
  Future<String?> read(String key) async => m[key];
  @override
  Future<void> write(String key, String value) async => m[key] = value;
}

String _grant({String? key, int exp = 3600, String site = _site}) {
  final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  return JWT({'iss': 'sp-bodycam-control-room', 'sub': _officer, 'jti': 'g1', 'site': site, 'dev': _dev, 'ops': ['session', 'upload', 'live'], 'iat': now, 'exp': now + exp, 'ver': 1})
      .sign(ECPrivateKey(key ?? trustedPrivatePem), algorithm: JWTAlgorithm.ES256, noIssueAt: true);
}

Map<String, dynamic> _config({List<Map<String, dynamic>>? receivers, String? grant, bool eligible = true}) => {
      'server_time': DateTime.now().toUtc().toIso8601String(),
      'device_id': _dev,
      'constable_id': _officer,
      'grant_issuer': 'sp-bodycam-control-room',
      'grant_lifetime_hours': 8,
      'grant_public_keys': [
        {'kid': null, 'pem': trustedPublicPem}
      ],
      'sites': [
        {
          'site_id': _site,
          'site_code': 'S1',
          'site_name': 'Site One',
          'assignment_id': 'a1',
          'eligible': eligible,
          'receivers': receivers ??
              [
                {'id': 'r1', 'code': 'R1', 'name': 'Gate', 'endpoint_url': _recv, 'local_live_enabled': false, 'configured': true}
              ],
          'grant': grant ?? _grant(),
          'grant_id': 'g1',
          'grant_expires_at': DateTime.now().toUtc().add(const Duration(hours: 8)).toIso8601String(),
        }
      ],
    };

class _World {
  bool centralUp = true;
  Object? centralHealth; // body for /healthz; null => 200 correct body
  int centralHealthStatus = 200;
  bool receiverUp = true;
  Map<String, dynamic>? provisioning;
  int provisioningStatus = 200;
  String receiverServesSite = _site;
  String receiverService = 'sp-bodycam-receiver';
  final requests = <String>[];
  final bodies = <String, String>{};

  http.Client client() => MockClient((req) async {
        final key = '${req.method} ${req.url.origin}${req.url.path}';
        requests.add(key);
        bodies[key] = req.body;
        if (req.url.origin == _central) {
          if (!centralUp) throw const SocketException('central down');
          if (req.url.path == '/healthz') {
            if (centralHealthStatus != 200) return http.Response('nope', centralHealthStatus);
            return http.Response(jsonEncode(centralHealth ?? {'status': 'ok', 'service': 'sp-bodycam-central'}), 200);
          }
          if (req.url.path == '/mobile/v1/network-hopping/config') return http.Response(jsonEncode(provisioning), provisioningStatus);
        }
        if (req.url.origin == 'https://receiver.site.test:8443') {
          if (!receiverUp) throw const SocketException('receiver down');
          if (req.url.path == '/v1/health') return http.Response(jsonEncode({'status': 'ok', 'service': receiverService, 'api': 'v1', 'ready': true}), 200);
          if (req.url.path == '/v1/auth/session') {
            return http.Response(jsonEncode({'access_token': 'tok', 'expires_in': 900, 'receiver': {'site_id': receiverServesSite}}), 200);
          }
        }
        return http.Response('not found', 404);
      });
}

void main() {
  late _World w;
  final nh = NetworkHoppingService.instance;

  setUp(() async {
    w = _World()..provisioning = _config();
    ApiClient.tokenStore = _Store();
    await ApiClient.setToken('t');
    await ApiClient.setDeviceIdentifier('device-ident');
    ApiClient.httpClient = w.client();
    await nh.load();
    await nh.setMode(TransportMode.online);
    await nh.setCentralFallback(true);
    await nh.setReceiverOverride(null);
    nh.clearReceiverAuthBlock();
    nh.invalidateSession();
  });

  group('receiver address validation', () {
    test('accepts only plain https host[:port]', () {
      expect(NetworkHoppingService.validateReceiverUrl('https://receiver.site.test:8443'), isNull);
      expect(NetworkHoppingService.validateReceiverUrl('https://10.0.0.5:8443'), isNull);
      for (final bad in [
        'http://receiver.site.test',
        'http://10.0.0.5:8443', // a private address is not trust and not a reason for plain http
        'http://localhost:8443',
        'ftp://x.test',
        'https://user:pw@x.test',
        'https://x.test/path',
        'https://x.test/?q=1',
        'https://x.test/#frag',
        'receiver.site.test',
        '',
        'https://',
      ]) {
        expect(NetworkHoppingService.validateReceiverUrl(bad), isNotNull, reason: bad);
      }
    });

    test('a refused override is not saved', () async {
      expect(await nh.setReceiverOverride('http://10.0.0.5:8443'), isNotNull);
      expect(nh.receiverOverride, isNull);
      expect(await nh.setReceiverOverride('https://other.site.test:8443'), isNull);
      expect(nh.receiverOverride, 'https://other.site.test:8443');
    });
  });

  group('provisioning', () {
    test('an unconfigured receiver does not break the others', () async {
      w.provisioning = _config(receivers: [
        {'id': 'r0', 'code': 'R0', 'name': 'NoAddress', 'endpoint_url': null, 'local_live_enabled': false, 'configured': false},
        {'id': 'r1', 'code': 'R1', 'name': 'Gate', 'endpoint_url': _recv, 'local_live_enabled': false, 'configured': true},
        {'id': 'r2', 'code': 'R2', 'name': 'Plain', 'endpoint_url': 'http://10.0.0.9', 'local_live_enabled': false, 'configured': true},
      ]);
      expect(await nh.refreshConfig(), isNull);
      final site = nh.activeSite!;
      expect(site.receivers.map((r) => r.id), ['r1']);
      expect(site.unusableReceivers, 2);
      expect(site.grantValid, isTrue);
    });

    test('a grant signed by an unknown key is dropped and never usable', () async {
      w.provisioning = _config(grant: _grant(key: otherPrivatePem));
      expect(await nh.refreshConfig(), isNull);
      expect(nh.activeSite!.grant, isNull);
      expect(nh.activeSite!.grantProblem, 'signature_invalid');
      expect(nh.grantValid, isFalse);
    });

    test('an expired or wrong-site grant is dropped', () async {
      w.provisioning = _config(grant: _grant(exp: -600));
      await nh.refreshConfig();
      expect(nh.activeSite!.grantProblem, 'expired');
      w.provisioning = _config(grant: _grant(site: 'other-site'));
      await nh.refreshConfig();
      expect(nh.activeSite!.grantProblem, 'wrong_site');
    });

    test('a malformed provisioning body is reported as such, not as unreachable', () async {
      w.provisioning = {'sites': 'oops'};
      expect(await nh.refreshConfig(), startsWith('provisioning_response_invalid'));
    });

    test('an unreachable control room keeps the previous configuration', () async {
      expect(await nh.refreshConfig(), isNull);
      final before = nh.activeSite!.grant;
      w.centralUp = false;
      expect(await nh.refreshConfig(), 'control_room_unreachable');
      expect(nh.activeSite!.grant, before);
      expect(nh.grantValid, isTrue);
    });

    test('a server error is reported with its detail', () async {
      w.provisioning = {'detail': 'Device is not registered to this officer'};
      w.provisioningStatus = 404;
      expect(await nh.refreshConfig(), contains('not registered'));
    });
  });

  group('central health contract', () {
    test('only the defined /healthz body counts as reachable', () async {
      expect(await nh.centralReachable(force: true), isTrue);
      w.centralHealthStatus = 404;
      expect(await nh.centralReachable(force: true), isFalse);
      expect(nh.centralStatus, 'health_missing');
      w.centralHealthStatus = 200;
      w.centralHealth = {'status': 'ok', 'service': 'something-else'};
      expect(await nh.centralReachable(force: true), isFalse);
      expect(nh.centralStatus, 'health_invalid');
      w.centralHealth = null;
      w.centralUp = false;
      expect(await nh.centralReachable(force: true), isFalse);
      expect(nh.centralStatus, 'unreachable');
    });
  });

  group('receiver identity and sessions', () {
    Future<void> provision() async {
      await nh.refreshConfig();
      await nh.setMode(TransportMode.networkHopping);
    }

    test('a good receiver yields a session; the grant is sent only after the readiness probe', () async {
      await provision();
      final s = await nh.receiverSession(forceNew: true);
      expect(s, isNotNull);
      expect(nh.receiverStatus, 'connected');
      final health = w.requests.indexOf('GET $_recv/v1/health');
      final session = w.requests.indexOf('POST $_recv/v1/auth/session');
      expect(health, greaterThanOrEqualTo(0));
      expect(session, greaterThan(health));
    });

    test('a server that is not a receiver never gets the grant', () async {
      await provision();
      w.receiverService = 'some-other-service';
      expect(await nh.receiverSession(forceNew: true), isNull);
      expect(w.requests.any((r) => r.contains('/v1/auth/session')), isFalse);
      expect(nh.receiverStatus, 'receiver_unreachable');
    });

    test('a session for a different site is discarded', () async {
      await provision();
      w.receiverServesSite = 'another-site';
      expect(await nh.receiverSession(forceNew: true), isNull);
      expect(nh.receiverStatus, 'wrong_site');
    });

    test('a grant that no longer verifies is never presented to a receiver', () async {
      w.provisioning = _config(grant: _grant(key: otherPrivatePem));
      await provision();
      expect(await nh.receiverSession(forceNew: true), isNull);
      expect(nh.receiverStatus, 'grant_signature_invalid');
      expect(w.requests.any((r) => r.contains('/v1/auth/session')), isFalse);
    });

    test('a receiver refusal pauses receiver contact until "sync now" lifts it', () async {
      await provision();
      nh.blockReceiverAuth('grant_revoked');
      w.requests.clear();
      expect(await nh.receiverSession(), isNull);
      expect(w.requests, isEmpty, reason: 'paused: no request at all, chunks stay queued');
      expect(nh.receiverStatus, 'grant_revoked');
      nh.clearReceiverAuthBlock();
      expect(await nh.receiverSession(), isNotNull);
    });

    test('receiver unreachable', () async {
      await provision();
      w.receiverUp = false;
      expect(await nh.receiverSession(forceNew: true), isNull);
      expect(nh.receiverStatus, 'receiver_unreachable');
    });
  });

  group('target selection', () {
    Future<void> provision() async {
      await nh.refreshConfig();
      await nh.setMode(TransportMode.networkHopping);
    }

    test('Online mode is the control room with no probing at all', () async {
      w.requests.clear();
      expect((await nh.resolveTarget()).kind, UploadTarget.central);
      expect(w.requests, isEmpty);
    });

    test('Network Hopping prefers the receiver', () async {
      await provision();
      expect((await nh.resolveTarget()).kind, UploadTarget.receiver);
    });

    test('receiver down, fallback on, control room up -> control room', () async {
      await provision();
      w.receiverUp = false;
      await nh.centralReachable(force: true);
      expect((await nh.resolveTarget()).kind, UploadTarget.central);
    });

    test('receiver down, fallback off -> nowhere (chunks wait)', () async {
      await provision();
      await nh.setCentralFallback(false);
      w.receiverUp = false;
      final t = await nh.resolveTarget();
      expect(t.kind, UploadTarget.none);
      expect(t.reason, 'receiver_unreachable');
    });

    test('both down -> nowhere', () async {
      await provision();
      w.receiverUp = false;
      w.centralUp = false;
      await nh.centralReachable(force: true);
      expect((await nh.resolveTarget()).kind, UploadTarget.none);
    });
  });

  group('Android cleartext configuration', () {
    test('main manifest forbids cleartext; only the debug manifest allows it', () {
      final main = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      final debug = File('android/app/src/debug/AndroidManifest.xml').readAsStringSync();
      expect(main, contains('android:usesCleartextTraffic="false"'));
      expect(main, isNot(contains('usesCleartextTraffic="true"')));
      expect(debug, contains('android:usesCleartextTraffic="true"'));
    });
  });
}
