import 'dart:convert';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

/// A public key the phone may use to verify offline grants (PEM, SubjectPublicKeyInfo).
class GrantKey {
  final String? kid;
  final String pem;
  const GrantKey({this.kid, required this.pem});

  factory GrantKey.fromJson(Map<String, dynamic> j) => GrantKey(kid: j['kid'] as String?, pem: j['pem'] as String);
  Map<String, dynamic> toJson() => {'kid': kid, 'pem': pem};
}

class GrantCheck {
  final bool ok;
  final String? reason; // stable code when !ok
  final Map<String, dynamic>? claims;
  const GrantCheck.valid(Map<String, dynamic> this.claims)
      : ok = true,
        reason = null;
  const GrantCheck.invalid(String this.reason)
      : ok = false,
        claims = null;
}

/// Optional build-time pin: `--dart-define=GRANT_PUBLIC_KEY_PEM="-----BEGIN PUBLIC KEY-----\n...\n-----END PUBLIC KEY-----"`
/// (write line breaks as \n). When set, ONLY this key is trusted and keys delivered at provisioning are ignored, so
/// a compromised provisioning response cannot substitute a key. Rotating a pinned key needs a new app build.
const String kPinnedGrantPublicKeyPem = String.fromEnvironment('GRANT_PUBLIC_KEY_PEM');

/// Accepted difference between this phone's clock and the control room's clock when checking iat/exp.
const Duration kGrantClockSkew = Duration(minutes: 2);

/// Independent client-side check of an offline grant: the same ES256 JWS the control room signs and receivers verify.
/// It does NOT replace the receiver's checks (the receiver stays the authority for acceptance); it makes sure the phone
/// never presents, stores or trusts a grant that is unsigned, signed by an unknown key, expired, or issued for another
/// site, device or officer. Grants and signatures are never logged.
class GrantVerifier {
  static GrantCheck verify(
    String token, {
    required List<GrantKey> provisionedKeys,
    required String siteId,
    String? expectedIssuer,
    String? deviceId,
    String? constableId,
    DateTime? now,
  }) {
    final parts = token.split('.');
    if (parts.length != 3) return const GrantCheck.invalid('malformed');
    Map<String, dynamic> header;
    try {
      header = jsonDecode(utf8.decode(base64Url.decode(base64.normalize(parts[0])))) as Map<String, dynamic>;
    } catch (_) {
      return const GrantCheck.invalid('malformed');
    }
    // Explicit allow-list: never let the token pick the algorithm ("none", HS256 with the public key as secret, ...).
    if (header['alg'] != 'ES256') return const GrantCheck.invalid('algorithm_not_allowed');

    final pinned = kPinnedGrantPublicKeyPem.trim();
    final keys = pinned.isNotEmpty ? [GrantKey(pem: pinned.replaceAll(r'\n', '\n'))] : provisionedKeys;
    final kid = header['kid'] as String?;
    final candidates = keys.where((k) => kid == null || k.kid == null || k.kid == kid).toList();
    if (candidates.isEmpty) return const GrantCheck.invalid('no_trusted_key');

    JWT? jwt;
    for (final key in candidates) {
      try {
        // Expiry is checked below with an explicit clock-skew policy, not by the library.
        jwt = JWT.verify(token, ECPublicKey(key.pem), checkHeaderType: false, checkExpiresIn: false, checkNotBefore: false);
        break;
      } catch (_) {
        continue;
      }
    }
    if (jwt == null) return const GrantCheck.invalid('signature_invalid');

    final payload = jwt.payload;
    if (payload is! Map<String, dynamic>) return const GrantCheck.invalid('malformed');
    if (expectedIssuer != null && payload['iss'] != expectedIssuer) return const GrantCheck.invalid('wrong_issuer');
    if (payload['site'] != siteId) return const GrantCheck.invalid('wrong_site');
    if (deviceId != null && payload['dev'] != deviceId) return const GrantCheck.invalid('wrong_device');
    if (constableId != null && payload['sub'] != constableId) return const GrantCheck.invalid('wrong_officer');
    final ops = payload['ops'];
    if (ops is! List || !ops.contains('upload') || !ops.contains('session')) return const GrantCheck.invalid('operation_not_permitted');
    if (payload['jti'] == null) return const GrantCheck.invalid('malformed');

    final exp = payload['exp'];
    final iat = payload['iat'];
    if (exp is! num || iat is! num) return const GrantCheck.invalid('malformed');
    final t = (now ?? DateTime.now()).toUtc();
    if (t.isAfter(DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true).add(kGrantClockSkew))) return const GrantCheck.invalid('expired');
    if (DateTime.fromMillisecondsSinceEpoch(iat.toInt() * 1000, isUtc: true).isAfter(t.add(kGrantClockSkew))) return const GrantCheck.invalid('not_yet_valid');
    return GrantCheck.valid(payload);
  }
}
