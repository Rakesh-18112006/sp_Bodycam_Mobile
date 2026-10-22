/// A network (building/site) the officer may log in to, from GET /mobile/v1/networks.
class NetworkInfo {
  final String siteId;
  final String siteCode;
  final String siteName;
  final String? organization;
  final bool loggedIn;
  final DateTime? loggedInAt;

  const NetworkInfo({
    required this.siteId,
    required this.siteCode,
    required this.siteName,
    this.organization,
    required this.loggedIn,
    this.loggedInAt,
  });

  factory NetworkInfo.fromJson(Map<String, dynamic> j) => NetworkInfo(
        siteId: j['site_id'] as String,
        siteCode: j['site_code'] as String,
        siteName: j['site_name'] as String,
        organization: j['organization'] as String?,
        loggedIn: j['logged_in'] as bool? ?? false,
        loggedInAt: j['logged_in_at'] == null ? null : DateTime.tryParse(j['logged_in_at'] as String),
      );
}

/// An alert raised by the control room for a network the officer is logged in to.
class NetworkAlert {
  final String alertId;
  final String siteId;
  final String? siteName;
  final String title;
  final String message;
  final String severity; // info | warning | critical | emergency
  final DateTime createdAt;
  final DateTime? expiresAt;

  const NetworkAlert({
    required this.alertId,
    required this.siteId,
    this.siteName,
    required this.title,
    required this.message,
    required this.severity,
    required this.createdAt,
    this.expiresAt,
  });

  factory NetworkAlert.fromJson(Map<String, dynamic> j) => NetworkAlert(
        alertId: j['alert_id'] as String,
        siteId: j['site_id'] as String,
        siteName: j['site_name'] as String?,
        title: j['title'] as String,
        message: (j['message'] as String?) ?? '',
        severity: (j['severity'] as String?) ?? 'critical',
        createdAt: DateTime.tryParse((j['created_at'] as String?) ?? '') ?? DateTime.now(),
        expiresAt: j['expires_at'] == null ? null : DateTime.tryParse(j['expires_at'] as String),
      );

  bool isExpired(DateTime now) => expiresAt != null && !expiresAt!.isAfter(now);
}
