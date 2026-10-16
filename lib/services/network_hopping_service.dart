import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'api_client.dart';
import 'grant_verifier.dart';

/// DEVELOPMENT ONLY. `--dart-define=ALLOW_INSECURE_RECEIVER=true` lets a debug build use a plain-http receiver on a
/// loopback/private address (an isolated lab). It is a compile-time constant, off by default, and never a runtime
/// fallback: a release build without the define cannot talk plain http to a receiver, whatever the network looks like.
const bool kAllowInsecureReceiver = bool.fromEnvironment('ALLOW_INSECURE_RECEIVER');

/// How the phone ships recorded video.
///  - [online]: the existing behaviour. Video goes straight to the control
///    room over the internet. This is the default and is never changed by
///    anything in this file unless the officer turns Network Hopping on.
///  - [networkHopping]: video goes to a receiver on the site LAN (which keeps
///    it durably and forwards it when the site's backhaul returns). Falls back
///    to the control room directly if the receiver cannot be reached but the
///    control room can (a policy the officer can switch off).
enum TransportMode { online, networkHopping }

class NhReceiver {
  final String id;
  final String code;
  final String name;
  final String endpointUrl; // always a usable, validated address: unconfigured receivers are never kept
  final bool localLiveEnabled;
  const NhReceiver({required this.id, required this.code, required this.name, required this.endpointUrl, required this.localLiveEnabled});

  /// Null when the record is unusable (no address, or an address that fails validation). One bad receiver never
  /// prevents the others from being read.
  static NhReceiver? tryParse(Map<String, dynamic> j) {
    final raw = j['endpoint_url'];
    if (raw is! String || raw.trim().isEmpty || (j['configured'] == false)) return null;
    final url = raw.trim().replaceAll(RegExp(r'/+$'), '');
    if (NetworkHoppingService.validateReceiverUrl(url) != null) return null;
    final id = j['id'];
    if (id is! String) return null;
    return NhReceiver(id: id, code: (j['code'] as String?) ?? '', name: (j['name'] as String?) ?? '', endpointUrl: url, localLiveEnabled: (j['local_live_enabled'] as bool?) ?? false);
  }

  Map<String, dynamic> toJson() => {'id': id, 'code': code, 'name': name, 'endpoint_url': endpointUrl, 'local_live_enabled': localLiveEnabled};
}

class NhSite {
  final String siteId;
  final String siteCode;
  final String siteName;
  final bool eligible;
  final String? reason;
  final String? grant;
  final String? grantId;
  final DateTime? grantExpiresAt;
  final List<NhReceiver> receivers; // usable receivers only
  final int unusableReceivers; // listed by the control room but without a valid address
  // Set when the phone's own verification of the grant failed (the grant is then dropped and never presented).
  final String? grantProblem;
  const NhSite({
    required this.siteId,
    required this.siteCode,
    required this.siteName,
    required this.eligible,
    required this.reason,
    required this.grant,
    required this.grantId,
    required this.grantExpiresAt,
    required this.receivers,
    this.unusableReceivers = 0,
    this.grantProblem,
  });

  bool get grantValid => eligible && grant != null && grantProblem == null && grantExpiresAt != null && grantExpiresAt!.isAfter(DateTime.now());

  NhSite withGrantProblem(String problem) => NhSite(
        siteId: siteId,
        siteCode: siteCode,
        siteName: siteName,
        eligible: false,
        reason: 'grant_$problem',
        grant: null,
        grantId: grantId,
        grantExpiresAt: null,
        receivers: receivers,
        unusableReceivers: unusableReceivers,
        grantProblem: problem,
      );

  factory NhSite.fromJson(Map<String, dynamic> j) {
    final all = ((j['receivers'] as List<dynamic>?) ?? const []).whereType<Map<String, dynamic>>().toList();
    final usable = all.map(NhReceiver.tryParse).whereType<NhReceiver>().toList();
    return NhSite(
      siteId: j['site_id'] as String,
      siteCode: (j['site_code'] as String?) ?? '',
      siteName: (j['site_name'] as String?) ?? '',
      eligible: (j['eligible'] as bool?) ?? false,
      reason: j['reason'] as String?,
      grant: j['grant'] as String?,
      grantId: j['grant_id'] as String?,
      grantExpiresAt: j['grant_expires_at'] == null ? null : DateTime.parse(j['grant_expires_at'] as String),
      receivers: usable,
      unusableReceivers: all.length - usable.length,
      grantProblem: j['grant_problem'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'site_id': siteId,
        'site_code': siteCode,
        'site_name': siteName,
        'eligible': eligible,
        'reason': reason,
        'grant': grant,
        'grant_id': grantId,
        'grant_expires_at': grantExpiresAt?.toUtc().toIso8601String(),
        'receivers': receivers.map((r) => r.toJson()).toList(),
        'grant_problem': grantProblem,
      };
}

/// A short-lived session with one receiver, obtained by presenting the
/// offline grant. Held in memory only.
class ReceiverSession {
  final String baseUrl;
  final String token;
  final DateTime expiresAt;
  final String siteId;
  const ReceiverSession({required this.baseUrl, required this.token, required this.expiresAt, required this.siteId});
}

/// Where the next upload should go.
class UploadTarget {
  static const central = 'central';
  static const receiver = 'receiver';
  static const none = 'none';
  final String kind;
  final ReceiverSession? session;
  final String? reason;
  const UploadTarget._(this.kind, this.session, this.reason);
  const UploadTarget.toCentral() : this._(central, null, null);
  const UploadTarget.toReceiver(ReceiverSession s) : this._(receiver, s, null);
  const UploadTarget.nowhere(String reason) : this._(none, null, reason);
}

/// Mode, site/receiver configuration, offline grant and connectivity-aware
/// endpoint selection for Network Hopping. Everything persisted here (the
/// grant is a credential) goes through the same platform secure storage as
/// the access token.
///
/// ENDPOINT TRUST MODEL. A receiver is trusted because (1) its address came from the control room's authenticated
/// provisioning response (or was typed in by the officer), (2) the address is https and passes validation EVERY
/// time it is used, whatever its source, and (3) the TLS handshake validates its certificate for that host name
/// against the phone's trust store (a private site CA must be installed on managed phones). The unauthenticated
/// /v1/health reply is only a readiness probe: anyone can serve it, so it is never treated as proof of identity.
/// Nothing is sent to an address that fails any of this, and the code never falls back from https to http.
/// Certificate/public-key pinning is NOT implemented (needs a provisioning and rotation design, see the docs).
class NetworkHoppingService extends ChangeNotifier {
  NetworkHoppingService._();
  static final NetworkHoppingService instance = NetworkHoppingService._();

  static const _modeKey = 'nh_mode';
  static const _configKey = 'nh_config';
  static const _siteKey = 'nh_site_id';
  static const _overrideKey = 'nh_receiver_override';
  static const _fallbackKey = 'nh_central_fallback';
  static const _probeTimeout = Duration(seconds: 4);
  static const _centralCacheFor = Duration(seconds: 15);

  TransportMode _mode = TransportMode.online;
  List<NhSite> _sites = const [];
  DateTime? _configFetchedAt;
  String? _activeSiteId;
  String? _receiverOverride;
  ReceiverSession? _session;
  bool _loaded = false;

  // Grant-verification context delivered by the control room at provisioning.
  List<GrantKey> _grantKeys = const [];
  String? _grantIssuer;
  String? _constableId;
  String? _deviceId;

  // Operational status shown on the Network Hopping screen.
  String receiverStatus = 'unknown'; // stable machine-readable code
  String centralStatus = 'unknown'; // reachable | unreachable | health_missing | health_invalid
  DateTime? lastReceiverContact;
  String? lastConfigError;
  bool? _centralReachable;
  DateTime? _centralCheckedAt;

  /// POLICY: when no receiver of the active site can be used, may NETWORK HOPPING chunks go straight to the
  /// control room if it is reachable? Default yes (evidence reaches the archive sooner); switch it off to keep
  /// site recordings strictly on the site path. Chunks recorded in Online mode always go to the control room.
  bool centralFallback = true;

  /// The control room rejected the access token while a valid offline grant let us carry on. Uploads to the
  /// receiver are unaffected, but the officer must sign in again while online (the screens say so).
  bool centralAuthExpired = false;

  /// Set when a receiver refused our grant (revoked, not permitted, ...). Uploads to receivers pause until
  /// this time instead of being retried like a network error; "Sync now" or a config refresh lifts it.
  DateTime? _receiverAuthBlockedUntil;
  static const _authBlockFor = Duration(minutes: 10);

  TransportMode get mode => _mode;
  bool get enabled => _mode == TransportMode.networkHopping;
  List<NhSite> get sites => _sites;
  DateTime? get configFetchedAt => _configFetchedAt;
  String? get receiverOverride => _receiverOverride;

  NhSite? get activeSite {
    if (_sites.isEmpty) return null;
    for (final s in _sites) {
      if (s.siteId == _activeSiteId) return s;
    }
    return _sites.first;
  }

  bool get grantValid => activeSite?.grantValid ?? false;
  DateTime? get grantExpiresAt => activeSite?.grantExpiresAt;

  /// True when the grant is missing or will expire within [within].
  bool grantNeedsRenewal({Duration within = const Duration(hours: 2)}) {
    final exp = grantExpiresAt;
    return exp == null || exp.isBefore(DateTime.now().add(within));
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    // A 401 from the control room must not log an officer out while they hold
    // a valid grant and have chosen Network Hopping.
    ApiClient.suppressUnauthorized = () {
      if (enabled && grantValid) {
        if (!centralAuthExpired) {
          centralAuthExpired = true;
          notifyListeners();
        }
        return true;
      }
      return false;
    };
    try {
      final store = ApiClient.tokenStore;
      _mode = (await store.read(_modeKey)) == 'network_hopping' ? TransportMode.networkHopping : TransportMode.online;
      _activeSiteId = await store.read(_siteKey);
      _receiverOverride = await store.read(_overrideKey);
      centralFallback = (await store.read(_fallbackKey)) != 'off';
      final raw = await store.read(_configKey);
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        _configFetchedAt = DateTime.tryParse((j['fetched_at'] as String?) ?? '');
        _grantKeys = ((j['grant_keys'] as List<dynamic>?) ?? const []).whereType<Map<String, dynamic>>().map(GrantKey.fromJson).toList();
        _grantIssuer = j['grant_issuer'] as String?;
        _constableId = j['constable_id'] as String?;
        _deviceId = j['device_id'] as String?;
        _sites = ((j['sites'] as List<dynamic>?) ?? const []).whereType<Map<String, dynamic>>().map(NhSite.fromJson).toList();
      }
    } catch (e) {
      debugPrint('[bodycam] NH config load failed (starting in Online mode): ${e.runtimeType}');
    }
    notifyListeners();
  }

  Future<void> setMode(TransportMode mode) async {
    _mode = mode;
    _session = null;
    receiverStatus = 'unknown';
    await ApiClient.tokenStore.write(_modeKey, mode == TransportMode.networkHopping ? 'network_hopping' : 'online');
    notifyListeners();
  }

  Future<void> setActiveSite(String siteId) async {
    _activeSiteId = siteId;
    _session = null;
    await ApiClient.tokenStore.write(_siteKey, siteId);
    notifyListeners();
  }

  Future<void> setCentralFallback(bool on) async {
    centralFallback = on;
    await ApiClient.tokenStore.write(_fallbackKey, on ? 'on' : 'off');
    notifyListeners();
  }

  static bool _isLabHost(String h) =>
      h == 'localhost' || h.endsWith('.local') || RegExp(r'^(10\.|127\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)').hasMatch(h);

  /// Why a receiver address is unacceptable, or null if it is fine. Applied to EVERY address before use, whether it came
  /// from provisioning, saved settings or the override box. https is required. Plain http passes only in a build made with
  /// ALLOW_INSECURE_RECEIVER=true and only for a loopback/private host; being on a private network never makes http
  /// acceptable by itself. Embedded credentials, queries, fragments and paths are rejected. Certificates are always validated.
  static String? validateReceiverUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return 'Enter a full address such as https://receiver.site.example:8443';
    if (uri.userInfo.isNotEmpty) return 'The address must not contain a user name or password';
    if (uri.hasQuery || uri.fragment.isNotEmpty || (uri.path.isNotEmpty && uri.path != '/')) return 'The address must be just scheme, host and port';
    if (uri.scheme == 'https') return null;
    if (uri.scheme == 'http' && kAllowInsecureReceiver && _isLabHost(uri.host)) return null;
    return 'Only https:// addresses are accepted';
  }

  /// Runtime receiver address (e.g. `https://receiver.site.example:8443`),
  /// tried before the addresses the control room provisioned. Empty clears it.
  /// Returns null on success or the reason the address was refused (nothing is saved then).
  Future<String?> setReceiverOverride(String? url) async {
    final v = url?.trim().replaceAll(RegExp(r'/+$'), '');
    if (v != null && v.isNotEmpty) {
      final problem = validateReceiverUrl(v);
      if (problem != null) return problem;
    }
    _receiverOverride = (v == null || v.isEmpty) ? null : v;
    _session = null;
    if (_receiverOverride == null) {
      await ApiClient.tokenStore.delete(_overrideKey);
    } else {
      await ApiClient.tokenStore.write(_overrideKey, _receiverOverride!);
    }
    notifyListeners();
    return null;
  }

  /// A receiver refused the grant. Uploads to receivers pause (the chunks stay queued) rather than being retried like
  /// a connectivity problem; the status code is shown to the officer.
  void blockReceiverAuth(String code) {
    _receiverAuthBlockedUntil = DateTime.now().add(_authBlockFor);
    receiverStatus = code;
    _session = null;
    notifyListeners();
  }

  void clearReceiverAuthBlock() => _receiverAuthBlockedUntil = null;

  /// The phone's own check of a site's grant: signature (ES256 only), trusted key, issuer, site, device, officer,
  /// permitted operations and validity window. Returns the site unchanged when it passes, or a copy with the grant
  /// removed and the reason recorded.
  NhSite _verified(NhSite site) {
    final grant = site.grant;
    if (grant == null) return site;
    final check = GrantVerifier.verify(
      grant,
      provisionedKeys: _grantKeys,
      siteId: site.siteId,
      expectedIssuer: _grantIssuer,
      deviceId: _deviceId,
      constableId: _constableId,
    );
    return check.ok ? site : site.withGrantProblem(check.reason ?? 'invalid');
  }

  /// Downloads the officer's sites, receivers and a freshly signed grant. Only
  /// possible while the control room is reachable. Returns null on success or
  /// a short reason; never throws, and never discards the previous config on
  /// failure (an offline phone keeps working with the grant it already has).
  Future<String?> refreshConfig() async {
    final dev = await ApiClient.getDeviceIdentifier();
    if (dev == null) {
      lastConfigError = 'device_not_registered';
      return lastConfigError;
    }
    Map<String, dynamic> j;
    try {
      j = await ApiClient.get('/mobile/v1/network-hopping/config?device_identifier=${Uri.encodeQueryComponent(dev)}') as Map<String, dynamic>;
    } on ApiException catch (e) {
      lastConfigError = e.detail;
      notifyListeners();
      return lastConfigError;
    } catch (e) {
      lastConfigError = 'control_room_unreachable';
      notifyListeners();
      return lastConfigError;
    }
    // The response arrived: from here on a failure is a CONTRACT problem, reported as such (not as "unreachable").
    try {
      final keys = ((j['grant_public_keys'] as List<dynamic>?) ?? const []).whereType<Map<String, dynamic>>().map(GrantKey.fromJson).toList();
      final parsed = ((j['sites'] as List<dynamic>?) ?? const []).whereType<Map<String, dynamic>>().map(NhSite.fromJson).toList();
      _grantKeys = keys;
      _grantIssuer = j['grant_issuer'] as String?;
      _constableId = j['constable_id'] as String?;
      _deviceId = j['device_id'] as String?;
      _sites = parsed.map(_verified).toList();
      _configFetchedAt = DateTime.now();
      lastConfigError = null;
      centralAuthExpired = false;
      _receiverAuthBlockedUntil = null;
      _session = null;
      await ApiClient.tokenStore.write(
        _configKey,
        jsonEncode({
          'fetched_at': _configFetchedAt!.toUtc().toIso8601String(),
          'grant_keys': _grantKeys.map((k) => k.toJson()).toList(),
          'grant_issuer': _grantIssuer,
          'constable_id': _constableId,
          'device_id': _deviceId,
          'sites': _sites.map((s) => s.toJson()).toList(),
        }),
      );
      notifyListeners();
      return null;
    } catch (e) {
      lastConfigError = 'provisioning_response_invalid (${e.runtimeType})';
      notifyListeners();
      return lastConfigError;
    }
  }

  /// Refreshes provisioning when it is stale or the grant is about to lapse
  /// and the control room is reachable. Cheap to call often.
  Future<void> maybeRefreshConfig() async {
    final stale = _configFetchedAt == null || DateTime.now().difference(_configFetchedAt!) > const Duration(hours: 1);
    if (!(stale || grantNeedsRenewal())) return;
    if (await centralReachable()) await refreshConfig();
  }

  // ---- connectivity-aware endpoint selection -------------------------------

  /// True only if the control room answers its defined health route (`GET /healthz`) with 200 and the expected body.
  /// A generic reply, a 404 from an old server or a proxy error page is NOT readiness; [centralStatus] says which case
  /// it was. Cached briefly so a burst of chunks does not probe once per chunk.
  Future<bool> centralReachable({bool force = false}) async {
    final now = DateTime.now();
    if (!force && _centralCheckedAt != null && now.difference(_centralCheckedAt!) < _centralCacheFor && _centralReachable != null) {
      return _centralReachable!;
    }
    var ok = false;
    var status = 'unreachable';
    try {
      final r = await ApiClient.httpClient.get(Uri.parse('$kApiBaseUrl/healthz')).timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        final body = jsonDecode(r.body);
        ok = body is Map && body['status'] == 'ok' && body['service'] == 'sp-bodycam-central';
        status = ok ? 'reachable' : 'health_invalid';
      } else {
        status = r.statusCode == 404 ? 'health_missing' : 'health_invalid';
      }
    } catch (_) {
      status = 'unreachable';
    }
    _centralReachable = ok;
    centralStatus = status;
    _centralCheckedAt = DateTime.now();
    return ok;
  }

  /// Readiness probe only (see the trust model above). Returns null when the service is unreachable or is not a receiver.
  Future<Map<String, dynamic>?> _health(String baseUrl) async {
    try {
      final r = await ApiClient.httpClient.get(Uri.parse('$baseUrl/v1/health')).timeout(_probeTimeout);
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body);
      if (j is! Map<String, dynamic> || j['status'] != 'ok' || j['service'] != 'sp-bodycam-receiver' || j['api'] != 'v1') return null;
      return j;
    } catch (_) {
      return null;
    }
  }

  /// A valid session with a reachable receiver of the active site, or null
  /// (with [receiverStatus] saying why). The grant is re-verified here, immediately before it would be sent, so a stored
  /// grant that no longer verifies is never presented; every address is re-validated; nothing is sent over plain http.
  Future<ReceiverSession?> receiverSession({bool forceNew = false}) async {
    var site = activeSite;
    if (site == null) {
      receiverStatus = 'not_provisioned';
      return null;
    }
    if (site.grant != null) site = _verified(site);
    if (!site.grantValid) {
      receiverStatus = site.grantProblem != null ? 'grant_${site.grantProblem}' : (site.grant == null ? (site.reason ?? 'no_grant') : 'grant_expired');
      return null;
    }
    if (forceNew) {
      _receiverAuthBlockedUntil = null;
    } else if (_receiverAuthBlockedUntil != null && _receiverAuthBlockedUntil!.isAfter(DateTime.now())) {
      return null; // receiverStatus already names the refusal
    }
    final cached = _session;
    if (!forceNew && cached != null && cached.siteId == site.siteId && cached.expiresAt.isAfter(DateTime.now().add(const Duration(seconds: 30)))) {
      return cached;
    }
    final candidates = <String>[if (_receiverOverride != null) _receiverOverride!, ...site.receivers.map((r) => r.endpointUrl)].toSet().toList();
    final urls = candidates.where((u) => validateReceiverUrl(u) == null).toList();
    if (urls.isEmpty) {
      receiverStatus = candidates.isEmpty ? 'no_receiver_configured' : 'receiver_address_invalid';
      return null;
    }
    final device = await ApiClient.getDeviceIdentifier();
    var status = 'receiver_unreachable';
    for (final url in urls) {
      final health = await _health(url);
      if (health == null) continue;
      if (health['ready'] == false) {
        status = 'receiver_storage_full';
        continue;
      }
      try {
        final r = await ApiClient.httpClient
            .post(Uri.parse('$url/v1/auth/session'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'grant': site.grant, if (device != null) 'device_identifier': device}))
            .timeout(const Duration(seconds: 10));
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          // The session reply is authenticated by the grant check the receiver just did; now the receiver tells us (inside
          // that reply) which site it serves. A mismatch discards the session.
          final served = (j['receiver'] as Map<String, dynamic>?)?['site_id'];
          if (served != site.siteId) {
            status = 'wrong_site';
            continue;
          }
          final session = ReceiverSession(
            baseUrl: url,
            token: j['access_token'] as String,
            expiresAt: DateTime.now().add(Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 600)),
            siteId: site.siteId,
          );
          _session = session;
          receiverStatus = 'connected';
          lastReceiverContact = DateTime.now();
          notifyListeners();
          return session;
        }
        // Definitive refusal (expired/revoked/wrong-site grant...): trying
        // another address would not help.
        try {
          final code = ((jsonDecode(r.body) as Map<String, dynamic>)['error'] as Map<String, dynamic>)['code'] as String?;
          receiverStatus = code ?? 'session_refused';
        } catch (_) {
          receiverStatus = 'session_refused';
        }
        notifyListeners();
        return null;
      } catch (_) {
        continue;
      }
    }
    receiverStatus = status;
    _session = null;
    notifyListeners();
    return null;
  }

  /// Called when the receiver rejected the session token (401).
  void invalidateSession() => _session = null;

  /// Chooses where the next chunk goes. Online mode always means the control
  /// room, exactly as before this feature existed.
  Future<UploadTarget> resolveTarget() async {
    if (!enabled) return const UploadTarget.toCentral();
    final session = await receiverSession();
    if (session != null) return UploadTarget.toReceiver(session);
    if (centralFallback && await centralReachable()) return const UploadTarget.toCentral();
    return UploadTarget.nowhere(receiverStatus);
  }
}
