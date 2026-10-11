import 'package:geolocator/geolocator.dart';

/// Round 10 — thin, testable wrapper around `geolocator` for the weather
/// icon's "use my precise location" flow.
///
/// Privacy rules (Vera):
/// - Location is requested ONLY on an explicit user tap of the weather
///   icon — never at startup, never in the background.
/// - Only while-in-use accuracy is used (`getCurrentPosition`);
///   `ACCESS_BACKGROUND_LOCATION` is never declared or requested.
/// - A position, once obtained, is used ONLY to build the Open-Meteo
///   request and is NEVER logged, stored, or sent anywhere else.
/// - Any failure (services off, denied, timeout) returns null and the
///   caller silently falls back to the IP-based weather — the user
///   never sees an error and never sees a fake reading.
///
/// This class exists so tests can fake the platform side without
/// touching `geolocator` statics.
class LocationService {
  /// True when the device's location services are switched on.
  Future<bool> isServiceEnabled() => Geolocator.isLocationServiceEnabled();

  /// Current permission state, without prompting.
  Future<LocationPermission> checkPermission() =>
      Geolocator.checkPermission();

  /// Shows the system permission dialog. Returns the resulting state.
  Future<LocationPermission> requestPermission() =>
      Geolocator.requestPermission();

  /// One-shot position fix. Medium accuracy is plenty for city-level
  /// weather; 10s cap so a tap never hangs the header.
  Future<Position?> getPosition() async {
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: const Duration(seconds: 10),
        ),
      );
    } catch (_) {
      // Timeout, services toggled mid-flight, anything else: treat as
      // unavailable and let the caller fall back to IP weather.
      return null;
    }
  }
}
