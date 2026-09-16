/// A single real GPS fix read from the device (via `geolocator`). Never
/// constructed with fabricated/default coordinates -- LocationService only
/// ever produces this from an actual `Position` returned by the OS.
class GpsFix {
  final double latitude;
  final double longitude;
  final double? accuracy;
  final DateTime capturedAt;

  GpsFix({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.capturedAt,
  });
}
