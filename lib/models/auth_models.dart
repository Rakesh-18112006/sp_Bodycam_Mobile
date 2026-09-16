/// Mirrors backend/app/schemas.py::UserPublic and TokenResponse exactly.
class UserPublic {
  final String id;
  final String phone;
  final String role;
  final bool isActive;
  final String? stationId;
  final DateTime createdAt;

  UserPublic({
    required this.id,
    required this.phone,
    required this.role,
    required this.isActive,
    required this.stationId,
    required this.createdAt,
  });

  factory UserPublic.fromJson(Map<String, dynamic> json) => UserPublic(
        id: json['id'] as String,
        phone: json['phone'] as String,
        role: json['role'] as String,
        isActive: json['is_active'] as bool,
        stationId: json['station_id'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

class TokenResponse {
  final String accessToken;
  final String tokenType;
  final int expiresIn;
  final UserPublic user;

  TokenResponse({
    required this.accessToken,
    required this.tokenType,
    required this.expiresIn,
    required this.user,
  });

  factory TokenResponse.fromJson(Map<String, dynamic> json) => TokenResponse(
        accessToken: json['access_token'] as String,
        tokenType: json['token_type'] as String? ?? 'bearer',
        expiresIn: json['expires_in'] as int,
        user: UserPublic.fromJson(json['user'] as Map<String, dynamic>),
      );
}
