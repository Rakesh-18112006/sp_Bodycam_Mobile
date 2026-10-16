// Phone-side verification of offline grants (lib/services/grant_verifier.dart), with deterministic throw-away EC keys.
import 'dart:convert';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:police_body_cam/services/grant_verifier.dart';

import '../helpers/test_keys.dart';

const _site = '11111111-1111-1111-1111-111111111111';
const _dev = '22222222-2222-2222-2222-222222222222';
const _officer = '33333333-3333-3333-3333-333333333333';
const _issuer = 'sp-bodycam-control-room';

String grant({
  String? privateKey,
  Map<String, dynamic> override = const {},
  List<String> ops = const ['session', 'upload', 'live'],
  int expInSeconds = 3600,
  int iatOffsetSeconds = 0,
  String? kid,
  List<String> removeClaims = const [],
}) {
  final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  final claims = <String, dynamic>{
    'iss': _issuer,
    'sub': _officer,
    'jti': 'grant-1',
    'site': _site,
    'dev': _dev,
    'devid': 'device-ident',
    'ops': ops,
    'iat': now + iatOffsetSeconds,
    'exp': now + expInSeconds,
    'ver': 1,
    ...override,
  };
  for (final c in removeClaims) {
    claims.remove(c);
  }
  return JWT(claims, header: kid == null ? null : {'kid': kid}).sign(ECPrivateKey(privateKey ?? trustedPrivatePem), algorithm: JWTAlgorithm.ES256, noIssueAt: true);
}

GrantCheck check(String token, {List<GrantKey>? keys, String? issuer = _issuer, String? device = _dev, String? officer = _officer, String site = _site, DateTime? now}) =>
    GrantVerifier.verify(token, provisionedKeys: keys ?? [const GrantKey(pem: trustedPublicPem)], siteId: site, expectedIssuer: issuer, deviceId: device, constableId: officer, now: now);

String _b64(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');

void main() {
  test('a correctly signed grant for this site, device and officer verifies', () {
    final r = check(grant());
    expect(r.ok, isTrue, reason: r.reason);
    expect(r.claims!['jti'], 'grant-1');
  });

  test('a grant signed by a different key is rejected', () => expect(check(grant(privateKey: otherPrivatePem)).reason, 'signature_invalid'));

  test('malformed tokens are rejected', () {
    expect(check('not-a-jwt').reason, 'malformed');
    expect(check('a.b').reason, 'malformed');
    expect(check('@@@.@@@.@@@').reason, 'malformed');
  });

  test('alg none and HS256 are never accepted (the token cannot choose the algorithm)', () {
    final none = '${_b64({'alg': 'none', 'typ': 'JWT'})}.${_b64({'iss': _issuer, 'site': _site, 'dev': _dev, 'sub': _officer, 'jti': 'x', 'ops': ['session', 'upload'], 'iat': 1, 'exp': 9999999999})}.';
    expect(check(none).reason, 'algorithm_not_allowed');
    final hs = JWT({'iss': _issuer, 'site': _site, 'dev': _dev, 'sub': _officer, 'jti': 'x', 'ops': ['session', 'upload']}).sign(SecretKey(trustedPublicPem), algorithm: JWTAlgorithm.HS256);
    expect(check(hs).reason, 'algorithm_not_allowed');
  });

  test('wrong issuer, site, device and officer are each rejected', () {
    expect(check(grant(override: {'iss': 'someone-else'})).reason, 'wrong_issuer');
    expect(check(grant(override: {'site': '99999999-9999-9999-9999-999999999999'})).reason, 'wrong_site');
    expect(check(grant(override: {'dev': 'other-device'})).reason, 'wrong_device');
    expect(check(grant(override: {'sub': 'other-officer'})).reason, 'wrong_officer');
  });

  test('missing upload or session operation is rejected', () {
    expect(check(grant(ops: ['session'])).reason, 'operation_not_permitted');
    expect(check(grant(ops: ['upload'])).reason, 'operation_not_permitted');
    expect(check(grant(removeClaims: ['ops'])).reason, 'operation_not_permitted');
  });

  test('missing identity claims are rejected', () {
    expect(check(grant(removeClaims: ['jti'])).reason, 'malformed');
    expect(check(grant(removeClaims: ['exp'])).reason, 'malformed');
    expect(check(grant(removeClaims: ['iat'])).reason, 'malformed');
  });

  test('expiry with the two-minute skew allowance', () {
    expect(check(grant(expInSeconds: -60)).ok, isTrue, reason: 'expired 60 s ago is inside the skew allowance');
    expect(check(grant(expInSeconds: -300)).reason, 'expired');
  });

  test('a grant issued in the future beyond the skew is rejected; within it is accepted', () {
    expect(check(grant(iatOffsetSeconds: 60)).ok, isTrue);
    expect(check(grant(iatOffsetSeconds: 3600)).reason, 'not_yet_valid');
  });

  test('the key id selects among provisioned keys; an unknown key id with no usable key is rejected', () {
    final token = grant(kid: 'key-2');
    final keys = [const GrantKey(kid: 'key-1', pem: otherPublicPem), const GrantKey(kid: 'key-2', pem: trustedPublicPem)];
    expect(check(token, keys: keys).ok, isTrue, reason: 'rotation: the matching key id is used');
    expect(check(grant(kid: 'key-3'), keys: keys).reason, 'no_trusted_key');
    expect(check(token, keys: [const GrantKey(kid: 'key-2', pem: otherPublicPem)]).reason, 'signature_invalid');
    expect(check(token, keys: const []).reason, 'no_trusted_key');
  });

  test('no expected issuer / device / officer means those checks are skipped, signature and site are not', () {
    expect(check(grant(), issuer: null, device: null, officer: null).ok, isTrue);
    expect(check(grant(privateKey: otherPrivatePem), issuer: null, device: null, officer: null).ok, isFalse);
    expect(check(grant(), issuer: null, device: null, officer: null, site: 'other').reason, 'wrong_site');
  });

  test('without a build-time pin, provisioned keys are used (the pin constant is empty in tests)', () {
    expect(kPinnedGrantPublicKeyPem, isEmpty, reason: 'pin behaviour needs a separate build with --dart-define=GRANT_PUBLIC_KEY_PEM; see the test plan');
  });
}
