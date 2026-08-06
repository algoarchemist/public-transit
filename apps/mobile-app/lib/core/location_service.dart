import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../config.dart';

/// Where the passenger is, with an honest answer when we do not know.
///
/// Location is requested, never demanded: a denied permission or a device with GPS
/// off still gets a working app centred on the real service area, just without the
/// "near me" ordering. A transit app that refuses to show anything until it gets a
/// fix is useless exactly when you need it — indoors at a bus station.
class LocationService {
  static const _fallback = LatLng(AppConfig.fallbackLat, AppConfig.fallbackLon);

  /// The device's position, or null if unavailable for any reason.
  static Future<LatLng?> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        return null;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          // A passenger standing still does not need a survey-grade fix, and waiting
          // for one on a cold start is the difference between a usable screen and a
          // spinner. Medium accuracy resolves in a couple of seconds.
          timeLimit: Duration(seconds: 8),
        ),
      );
      return LatLng(position.latitude, position.longitude);
    } catch (_) {
      // Timeouts, permission plugin errors, unsupported platforms — all mean the
      // same thing to the caller: no fix.
      return null;
    }
  }

  /// Position if we have one, otherwise the centre of the ingested network, so the
  /// map always opens on the real service area rather than null island.
  static Future<({LatLng point, bool isReal})> currentOrFallback() async {
    final fix = await current();
    return fix == null ? (point: _fallback, isReal: false) : (point: fix, isReal: true);
  }
}
