import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'api_client.dart';
import '../models/location_models.dart';

enum LocationAvailability {
  unknown,
  available,
  permissionRequired,
  permissionDeniedForever,
  serviceDisabled,
  unavailable,
}

/// Real GPS location reporting via `geolocator` (backed by Android's
/// FusedLocationProvider). Never sends a fabricated or default coordinate
/// -- POST /constables/me/location is only ever called with an actual
/// `Position` the OS returned. If permission is denied/unavailable, this
/// simply stops reporting and exposes [availability] so the UI can show an
/// honest status instead of silently pretending location works.
class LocationService {
  StreamSubscription<Position>? _positionSub;
  Timer? _periodicResendTimer;
  LocationAvailability availability = LocationAvailability.unknown;
  GpsFix? lastFix;

  final void Function(LocationAvailability availability)? onAvailabilityChanged;
  final void Function(Object error)? onError;

  LocationService({this.onAvailabilityChanged, this.onError});

  void _setAvailability(LocationAvailability a) {
    availability = a;
    onAvailabilityChanged?.call(a);
  }

  /// Requests permission (fine, falling back to coarse) and, if granted,
  /// starts a distance/time-filtered position stream. Returns true if
  /// reporting actually started.
  Future<bool> start() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _setAvailability(LocationAvailability.serviceDisabled);
      return false;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      _setAvailability(LocationAvailability.permissionDeniedForever);
      return false;
    }
    if (permission == LocationPermission.denied) {
      _setAvailability(LocationAvailability.permissionRequired);
      return false;
    }

    _setAvailability(LocationAvailability.available);
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        // Balances Control Room freshness against battery/data use (no
        // interval is mandated by the backend -- see handoff doc §F,
        // "CLIENT RESPONSIBILITY"): report on a real movement of 25m+,
        // but never let a stationary constable's location go silent --
        // the periodic re-send below covers that.
        distanceFilter: 25,
      ),
    ).listen(_handlePosition, onError: (e) {
      onError?.call(e);
    });

    // geolocator's distanceFilter means a stationary device produces no
    // stream events at all -- without this, Control Room would see
    // location_updated_at go stale the moment a constable stops moving,
    // which is exactly the false impression the handoff doc warns against.
    _periodicResendTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      if (_positionSub == null) return;
      try {
        final pos = await Geolocator.getLastKnownPosition();
        if (pos != null) await _handlePosition(pos);
      } catch (e) {
        onError?.call(e);
      }
    });

    return true;
  }

  Future<void> _handlePosition(Position position) async {
    final fix = GpsFix(
      latitude: position.latitude,
      longitude: position.longitude,
      accuracy: position.accuracy,
      capturedAt: DateTime.now(),
    );
    lastFix = fix;
    try {
      await ApiClient.post('/constables/me/location', body: {
        'latitude': fix.latitude,
        'longitude': fix.longitude,
        if (fix.accuracy != null) 'accuracy': fix.accuracy,
      });
    } catch (e) {
      onError?.call(e);
    }
  }

  void stop() {
    _positionSub?.cancel();
    _positionSub = null;
    _periodicResendTimer?.cancel();
    _periodicResendTimer = null;
  }
}
