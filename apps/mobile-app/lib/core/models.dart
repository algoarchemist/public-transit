import 'package:latlong2/latlong.dart';

/// Wire models for the api-gateway REST surface and the stream-processor's
/// Socket.IO `bus:update` feed. Field names mirror the server payloads exactly so
/// there is one contract to check when something looks wrong.

/// Tolerant int parse.
///
/// Not defensive programming for its own sake: the live feed genuinely sends OSM
/// stop ids both ways in the *same* message — `bus:update.nextStopId` is a JSON
/// number while each `upcomingStops[].stopId` is a string, because they are
/// produced by two different paths in the stream-processor (the map-matcher vs.
/// the ETA batch scorer). A strict `as num` cast throws on the string form, and
/// since FleetSocket swallows malformed frames to protect the map, the symptom is
/// an empty map with no error — very expensive to debug from the app side.
int? _asInt(dynamic value) => switch (value) {
      null => null,
      num n => n.round(),
      String s => int.tryParse(s) ?? double.tryParse(s)?.round(),
      _ => null,
    };

double? _asDouble(dynamic value) => switch (value) {
      null => null,
      num n => n.toDouble(),
      String s => double.tryParse(s),
      _ => null,
    };

/// One direction of one real ingested route (`GET /api/routes`).
class BusRoute {
  final String directionId; // "r" + OSM relation id — what the live pipeline speaks
  final String? routeId; // GTFS ref, e.g. "20A" — shared by both directions
  final String? name;
  final String? operator;
  final double? lengthM;
  final int stopCount;

  const BusRoute({
    required this.directionId,
    this.routeId,
    this.name,
    this.operator,
    this.lengthM,
    this.stopCount = 0,
  });

  factory BusRoute.fromJson(Map<String, dynamic> json) => BusRoute(
        directionId: json['directionId'] as String,
        routeId: json['routeId'] as String?,
        name: json['name'] as String?,
        operator: json['operator'] as String?,
        lengthM: (json['lengthM'] as num?)?.toDouble(),
        stopCount: (json['stopCount'] as num?)?.toInt() ?? 0,
      );

  /// "Bus 20A: ISBT-17 => Kharar" -> ("ISBT-17", "Kharar"). Route names come
  /// straight from OSM and overwhelmingly follow this shape; anything that doesn't
  /// falls back to the raw name rather than being mangled.
  (String, String)? get endpoints {
    final n = name;
    if (n == null) return null;
    final afterColon = n.contains(':') ? n.split(':').sublist(1).join(':') : n;
    final parts = afterColon.split('=>');
    if (parts.length != 2) return null;
    return (parts[0].trim(), parts[1].trim());
  }

  String get displayName {
    final e = endpoints;
    return e == null ? (name ?? directionId) : '${e.$1} → ${e.$2}';
  }

  String get shortLabel => routeId ?? directionId;

  /// Free-text match over route number, name and endpoints — powers the search bar.
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return (routeId ?? '').toLowerCase().contains(q) ||
        (name ?? '').toLowerCase().contains(q) ||
        directionId.toLowerCase().contains(q);
  }
}

/// A stop along a route (`GET /api/routes/:id/stops`).
class RouteStop {
  final int sequence;
  final int osmNodeId;
  final String? name;
  final double lat;
  final double lon;

  const RouteStop({
    required this.sequence,
    required this.osmNodeId,
    this.name,
    required this.lat,
    required this.lon,
  });

  factory RouteStop.fromJson(Map<String, dynamic> json) => RouteStop(
        sequence: (json['sequence'] as num).toInt(),
        osmNodeId: (json['osmNodeId'] as num).toInt(),
        name: json['name'] as String?,
        lat: (json['lat'] as num).toDouble(),
        lon: (json['lon'] as num).toDouble(),
      );

  LatLng get latLng => LatLng(lat, lon);

  /// Only ~30 of the tricity's real OSM stop nodes carry a name (see
  /// services/geo-ingest/README.md) — the rest are genuinely unnamed in OSM. Show
  /// a stable positional label rather than inventing a name.
  String get displayName => (name != null && name!.isNotEmpty) ? name! : 'Stop ${sequence + 1}';
}

/// A route that serves a nearby stop (`GET /api/stops/nearby`).
class ServingRoute {
  final String directionId;
  final String? routeId;
  final String? routeName;
  final int sequence;

  const ServingRoute({
    required this.directionId,
    this.routeId,
    this.routeName,
    required this.sequence,
  });

  factory ServingRoute.fromJson(Map<String, dynamic> json) => ServingRoute(
        directionId: json['directionId'] as String,
        routeId: json['routeId'] as String?,
        routeName: json['routeName'] as String?,
        sequence: (json['sequence'] as num).toInt(),
      );
}

/// A real stop near the user, with every route that serves it.
class NearbyStop {
  final int osmNodeId;
  final String? name;
  final double lat;
  final double lon;
  final double distanceM;
  final List<ServingRoute> routes;

  const NearbyStop({
    required this.osmNodeId,
    this.name,
    required this.lat,
    required this.lon,
    required this.distanceM,
    required this.routes,
  });

  factory NearbyStop.fromJson(Map<String, dynamic> json) => NearbyStop(
        osmNodeId: (json['osmNodeId'] as num).toInt(),
        name: json['name'] as String?,
        lat: (json['lat'] as num).toDouble(),
        lon: (json['lon'] as num).toDouble(),
        distanceM: (json['distanceM'] as num).toDouble(),
        routes: (json['routes'] as List<dynamic>)
            .map((r) => ServingRoute.fromJson(r as Map<String, dynamic>))
            .toList(),
      );

  LatLng get latLng => LatLng(lat, lon);

  String get displayName => (name != null && name!.isNotEmpty) ? name! : 'Unnamed stop';

  String get distanceLabel =>
      distanceM < 1000 ? '${distanceM.round()} m' : '${(distanceM / 1000).toStringAsFixed(1)} km';
}

/// A real stop, anywhere in the city (`GET /api/stops`) — unlike [NearbyStop],
/// not filtered by the phone's current location. Backs the passenger app's
/// origin/destination picker (stop_picker_screen.dart), where "search by name"
/// is the whole point, not "search near me".
class SearchStop {
  final int osmNodeId;
  final String? name;
  final double lat;
  final double lon;
  final List<ServingRoute> routes;

  const SearchStop({required this.osmNodeId, this.name, required this.lat, required this.lon, required this.routes});

  factory SearchStop.fromJson(Map<String, dynamic> json) => SearchStop(
        osmNodeId: (json['osmNodeId'] as num).toInt(),
        name: json['name'] as String?,
        lat: (json['lat'] as num).toDouble(),
        lon: (json['lon'] as num).toDouble(),
        routes: (json['routes'] as List<dynamic>)
            .map((r) => ServingRoute.fromJson(r as Map<String, dynamic>))
            .toList(),
      );

  LatLng get latLng => LatLng(lat, lon);

  String get displayName => (name != null && name!.isNotEmpty) ? name! : 'Stop $osmNodeId';

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return displayName.toLowerCase().contains(q) ||
        routes.any((r) => (r.routeId ?? '').toLowerCase().contains(q));
  }
}

/// A real direct (no-transfer) route between two real stops
/// (`GET /api/routes/journeys`) — see routes.service.ts's `journeys()` for what
/// this deliberately does and doesn't claim: real distance always; real duration
/// only when every covered segment has an OSRM baseline (null otherwise, never
/// guessed); no fare, no frequency — neither exists anywhere in this system.
class JourneyOption {
  final String directionId;
  final String? routeId;
  final String? routeName;
  final int fromStopId;
  final int toStopId;
  final int stopsBetween;
  final double distanceM;
  final int? durationSec;

  const JourneyOption({
    required this.directionId,
    this.routeId,
    this.routeName,
    required this.fromStopId,
    required this.toStopId,
    required this.stopsBetween,
    required this.distanceM,
    this.durationSec,
  });

  factory JourneyOption.fromJson(Map<String, dynamic> json) => JourneyOption(
        directionId: json['directionId'] as String,
        routeId: json['routeId'] as String?,
        routeName: json['routeName'] as String?,
        fromStopId: (json['fromStopId'] as num).toInt(),
        toStopId: (json['toStopId'] as num).toInt(),
        stopsBetween: (json['stopsBetween'] as num).toInt(),
        distanceM: (json['distanceM'] as num).toDouble(),
        durationSec: (json['durationSec'] as num?)?.toInt(),
      );

  String get displayName => BusRoute(directionId: directionId, routeId: routeId, name: routeName).displayName;

  String get durationLabel {
    final s = durationSec;
    if (s == null) return 'Duration unavailable';
    final minutes = (s / 60).round();
    if (minutes < 60) return '$minutes min';
    return '${minutes ~/ 60}h ${minutes % 60}m';
  }

  String get distanceLabel =>
      distanceM < 1000 ? '${distanceM.round()} m' : '${(distanceM / 1000).toStringAsFixed(1)} km';
}

/// A driver-raised or system-detected incident (`GET /api/alerts`,
/// alerts.controller.ts) — the same real feed the admin dashboard's Alerts panel
/// reads, re-labeled for a passenger audience in alerts_screen.dart. There is no
/// "delay" or "cancellation" alert type in this system (no schedule exists to be
/// delayed against, no cancellation concept in the trip model) — only the real
/// types below are ever actually raised.
class AlertItem {
  final int alertId;
  final String type;
  final String? busId;
  final int? tripId;
  final String? notes;
  final DateTime raisedAt;

  const AlertItem({
    required this.alertId,
    required this.type,
    this.busId,
    this.tripId,
    this.notes,
    required this.raisedAt,
  });

  factory AlertItem.fromJson(Map<String, dynamic> json) => AlertItem(
        alertId: (json['alertId'] as num).toInt(),
        type: json['type'] as String,
        busId: json['busId'] as String?,
        tripId: (json['tripId'] as num?)?.toInt(),
        notes: json['notes'] as String?,
        raisedAt: DateTime.parse(json['raisedAt'] as String),
      );
}

/// One upcoming-stop ETA, as computed by ml-service's `/eta/predict-batch` and
/// attached to every `bus:update` by the stream-processor's scoring loop.
class StopEta {
  final int? stopId;
  final String? stopName;
  final int? etaSeconds;
  final int? sequence;

  const StopEta({this.stopId, this.stopName, this.etaSeconds, this.sequence});

  factory StopEta.fromJson(Map<String, dynamic> json) => StopEta(
        stopId: _asInt(json['stopId']),
        stopName: json['stopName'] as String?,
        etaSeconds: _asInt(json['etaSeconds']),
        sequence: _asInt(json['sequence']),
      );

  String get displayName => (stopName != null && stopName!.isNotEmpty) ? stopName! : 'Stop';

  String get etaLabel => formatEta(etaSeconds);
}

/// Shared ETA formatting so the map sheet, the stop list and the bus list all
/// phrase "3 min" identically.
String formatEta(int? seconds) {
  if (seconds == null) return '—';
  if (seconds < 45) return 'Arriving';
  final minutes = (seconds / 60).round();
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  return '${hours}h ${minutes % 60}m';
}

/// A live bus, from the gateway's `bus:update` Socket.IO event.
///
/// `confidenceTier` is the degradation ladder (docs §7.4): 'live' is a real recent
/// ping, 'estimated' is dead-reckoned along real route geometry after signal loss,
/// 'stale' is a held last-known position. The UI must never render all three the
/// same way — that is the difference between honest and dishonest tracking.
class LiveBus {
  final String busId;
  final String? routeId;
  final String directionId;
  final double lat;
  final double lon;
  final int? occupancy;
  final int? etaSeconds;
  final List<StopEta> upcomingStops;
  final int? nextStopId;
  final String? nextStopName;
  final double? distanceToNextStopM;
  final String confidenceTier;
  final String? badge;
  final int updatedAt; // epoch ms of the last REAL ping, never the server's tick

  const LiveBus({
    required this.busId,
    this.routeId,
    required this.directionId,
    required this.lat,
    required this.lon,
    this.occupancy,
    this.etaSeconds,
    this.upcomingStops = const [],
    this.nextStopId,
    this.nextStopName,
    this.distanceToNextStopM,
    this.confidenceTier = 'live',
    this.badge,
    required this.updatedAt,
  });

  factory LiveBus.fromJson(Map<String, dynamic> json) => LiveBus(
        busId: json['busId'].toString(),
        routeId: json['routeId']?.toString(),
        directionId: json['directionId']?.toString() ?? '',
        lat: _asDouble(json['lat']) ?? 0,
        lon: _asDouble(json['lon']) ?? 0,
        occupancy: _asInt(json['occupancy']),
        etaSeconds: _asInt(json['etaSeconds']),
        upcomingStops: (json['upcomingStops'] as List<dynamic>? ?? [])
            .map((s) => StopEta.fromJson(Map<String, dynamic>.from(s as Map)))
            .toList(),
        nextStopId: _asInt(json['nextStopId']),
        nextStopName: json['nextStopName'] as String?,
        distanceToNextStopM: _asDouble(json['distanceToNextStopM']),
        confidenceTier: (json['confidenceTier'] as String?) ?? 'live',
        badge: json['badge'] as String?,
        updatedAt: _asInt(json['updatedAt']) ?? DateTime.now().millisecondsSinceEpoch,
      );

  LatLng get latLng => LatLng(lat, lon);

  Duration get age => Duration(milliseconds: DateTime.now().millisecondsSinceEpoch - updatedAt);

  bool get isLive => confidenceTier == 'live';

  /// Honest one-liner about how much to trust this position.
  String get freshnessLabel {
    final seconds = age.inSeconds;
    return switch (confidenceTier) {
      'live' => 'Live',
      'estimated' => 'Estimated · signal lost ${seconds}s ago',
      _ => 'Last seen ${(seconds / 60).round()} min ago',
    };
  }

  /// The ETA to a specific stop on this bus's route, if it is still upcoming.
  int? etaToStop(int osmNodeId) {
    for (final stop in upcomingStops) {
      if (stop.stopId == osmNodeId) return stop.etaSeconds;
    }
    return null;
  }
}

/// An active (or past) driver trip (`POST /api/trips`, `GET /api/trips`,
/// `PATCH /api/trips/:id/end`) — trips.controller.ts's `TripResponse`.
class TripSession {
  final int tripId;
  final String busId;
  final String directionId;
  final String? routeId;
  final String? routeName;
  final String status;
  final int stopCount;

  /// The driver's stated/expected start time (`trips.scheduled_start`) — distinct
  /// from [startedAt], which is when the trip was actually recorded as starting.
  /// Null for a trip started the plain "tap Start Trip, GPS acquired" way; set
  /// when the driver went through the schedule/predefined-timing flow
  /// (schedule_start_screen.dart) first.
  final DateTime? scheduledStart;
  final DateTime? startedAt;
  final DateTime? endedAt;

  const TripSession({
    required this.tripId,
    required this.busId,
    required this.directionId,
    this.routeId,
    this.routeName,
    required this.status,
    this.stopCount = 0,
    this.scheduledStart,
    this.startedAt,
    this.endedAt,
  });

  factory TripSession.fromJson(Map<String, dynamic> json) => TripSession(
        tripId: (json['tripId'] as num).toInt(),
        busId: json['busId'] as String,
        directionId: json['directionId'] as String,
        routeId: json['routeId'] as String?,
        routeName: json['routeName'] as String?,
        status: (json['status'] as String?) ?? 'running',
        stopCount: (json['stopCount'] as num?)?.toInt() ?? 0,
        scheduledStart: DateTime.tryParse((json['scheduledStart'] as String?) ?? ''),
        startedAt: DateTime.tryParse((json['startedAt'] as String?) ?? ''),
        endedAt: DateTime.tryParse((json['endedAt'] as String?) ?? ''),
      );

  /// Whether this trip's real recorded start ran later than what was scheduled —
  /// only meaningful when both are actually known.
  Duration? get startDelay =>
      (scheduledStart != null && startedAt != null) ? startedAt!.difference(scheduledStart!) : null;
}
