import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config.dart';
import 'models.dart';

/// Thrown for anything the UI should show the user rather than crash on.
/// Carries a message already phrased for a person, not a stack trace.
class ApiException implements Exception {
  final String message;
  final int? statusCode;
  const ApiException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// REST client for the api-gateway (`services/api-gateway`).
///
/// The WebSocket feed is the primary path for anything live (see FleetSocket);
/// this covers the static reference data and the driver's trip lifecycle, which
/// are request/response by nature.
class ApiClient {
  ApiClient({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        _baseUrl = baseUrl ?? AppConfig.apiBaseUrl;

  final http.Client _client;
  final String _baseUrl;

  static const _timeout = Duration(seconds: 12);

  /// Route geometry is fetched once per route and never changes under a running
  /// app (it comes from a committed snapshot), so caching it means panning back to
  /// a route you already viewed costs nothing.
  final Map<String, List<LatLng>> _geometryCache = {};
  List<BusRoute>? _routesCache;

  Future<dynamic> _get(String path) async {
    final uri = Uri.parse('$_baseUrl$path');
    try {
      final response = await _client.get(uri).timeout(_timeout);
      return _decode(response);
    } on TimeoutException {
      throw const ApiException('The server took too long to respond. Check your connection.');
    } on http.ClientException {
      throw ApiException('Cannot reach the SetuTrack server at $_baseUrl.');
    }
  }

  Future<dynamic> _send(String method, String path, Map<String, dynamic> body) async {
    final uri = Uri.parse('$_baseUrl$path');
    final request = http.Request(method, uri)
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode(body);
    try {
      final streamed = await _client.send(request).timeout(_timeout);
      return _decode(await http.Response.fromStream(streamed));
    } on TimeoutException {
      throw const ApiException('The server took too long to respond. Check your connection.');
    } on http.ClientException {
      throw ApiException('Cannot reach the SetuTrack server at $_baseUrl.');
    }
  }

  dynamic _decode(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body);
    }
    // Nest's exception filter returns {message, error, statusCode}, where `message`
    // is a string for thrown HttpExceptions and a string[] for validation failures.
    String message = 'Request failed (${response.statusCode})';
    try {
      final decoded = jsonDecode(response.body);
      final raw = decoded is Map<String, dynamic> ? decoded['message'] : null;
      if (raw is String) {
        message = raw;
      } else if (raw is List && raw.isNotEmpty) {
        message = raw.join('\n');
      }
    } catch (_) {
      // Non-JSON error body (a proxy page, say) — keep the status-code message.
    }
    throw ApiException(message, statusCode: response.statusCode);
  }

  /// All 103 real ingested route directions. Cached — this is static reference data.
  Future<List<BusRoute>> routes({bool forceRefresh = false}) async {
    if (_routesCache != null && !forceRefresh) return _routesCache!;
    final data = await _get('/routes') as List<dynamic>;
    return _routesCache = data.map((r) => BusRoute.fromJson(r as Map<String, dynamic>)).toList();
  }

  Future<List<RouteStop>> routeStops(String directionId) async {
    final data = await _get('/routes/$directionId/stops') as Map<String, dynamic>;
    return (data['stops'] as List<dynamic>)
        .map((s) => RouteStop.fromJson(s as Map<String, dynamic>))
        .toList();
  }

  /// One route's real polyline, as map-drawable points.
  Future<List<LatLng>> routeGeometry(String directionId) async {
    final cached = _geometryCache[directionId];
    if (cached != null) return cached;

    final feature = await _get('/routes/$directionId/geometry') as Map<String, dynamic>;
    final coordinates = (feature['geometry'] as Map<String, dynamic>)['coordinates'] as List<dynamic>;
    // GeoJSON is [lon, lat]; LatLng is (lat, lon). Getting this backwards puts the
    // whole tricity in the Indian Ocean, so it is worth the explicit comment.
    final points = coordinates
        .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
        .toList();
    return _geometryCache[directionId] = points;
  }

  Future<List<NearbyStop>> nearbyStops({
    required double lat,
    required double lon,
    double radiusM = 1500,
    int limit = 25,
  }) async {
    final data = await _get('/stops/nearby?lat=$lat&lon=$lon&radius_m=${radiusM.round()}&limit=$limit')
        as Map<String, dynamic>;
    return (data['stops'] as List<dynamic>)
        .map((s) => NearbyStop.fromJson(s as Map<String, dynamic>))
        .toList();
  }

  /// Resolves a bus number and destination name — typed, or pulled out of a
  /// spoken transcript by the voice search flow (`lib/passenger/voice/`) — into a
  /// route+stop match (`GET /api/search`, search.controller.ts).
  Future<SearchResult> search({required String bus, required String location}) async {
    final data = await _get(
      '/search?bus=${Uri.encodeQueryComponent(bus)}&location=${Uri.encodeQueryComponent(location)}',
    ) as Map<String, dynamic>;
    return SearchResult.fromJson(data);
  }

  // --- Driver trip lifecycle -------------------------------------------------

  Future<TripSession> startTrip({
    required String busId,
    required String directionId,
    String? driverId,
    int? initialOccupancy,
  }) async {
    final data = await _send('POST', '/trips', {
      'busId': busId,
      'directionId': directionId,
      if (driverId != null && driverId.isNotEmpty) 'driverId': driverId,
      if (initialOccupancy != null) 'initialOccupancy': initialOccupancy,
    }) as Map<String, dynamic>;
    return TripSession.fromJson(data);
  }

  Future<TripSession> endTrip(int tripId, {String status = 'completed'}) async {
    final data = await _send('PATCH', '/trips/$tripId/end', {'status': status}) as Map<String, dynamic>;
    return TripSession.fromJson(data);
  }

  /// Most recent trips first, optionally scoped to one bus — the driver app's
  /// "view all trips" screen after ending a trip.
  Future<List<TripSession>> trips({String? busId, int limit = 20}) async {
    final query = StringBuffer('/trips?limit=$limit');
    if (busId != null && busId.isNotEmpty) query.write('&busId=${Uri.encodeQueryComponent(busId)}');
    final data = await _get(query.toString()) as List<dynamic>;
    return data.map((t) => TripSession.fromJson(t as Map<String, dynamic>)).toList();
  }

  /// Durable conductor tally. Fire-and-forget from the UI's point of view: the same
  /// number also rides the next GPS ping, so a failed tally POST costs history, not
  /// the live occupancy badge.
  Future<void> tally(int tripId, int occupancy) async {
    await _send('POST', '/trips/$tripId/tally', {'occupancy': occupancy});
  }

  // --- Driver auth (demo-mode OTP, auth.controller.ts) -----------------------

  /// No SMS gateway is wired up server-side, so the response carries the code
  /// itself (`demoMode: true`) instead of it being delivered anywhere — see
  /// auth.service.ts's docstring. The UI shows it rather than pretending a text
  /// was sent.
  Future<Map<String, dynamic>> requestDriverOtp(String driverId) async {
    return await _send('POST', '/auth/otp/request', {'driverId': driverId}) as Map<String, dynamic>;
  }

  /// Throws [ApiException] (expired/incorrect/too-many-attempts) rather than
  /// returning false — the message is already phrased for the driver to read.
  Future<void> verifyDriverOtp(String driverId, String code) async {
    await _send('POST', '/auth/otp/verify', {'driverId': driverId, 'code': code});
  }

  /// Driver-raised incident (`alerts.controller.ts`'s `POST /alerts`) — traffic,
  /// road diversion, accident, breakdown, or SOS. `lat`/`lon` are best-effort: the
  /// backend records the alert either way rather than rejecting it.
  Future<void> raiseAlert({
    required String type,
    String? busId,
    int? tripId,
    double? lat,
    double? lon,
    String? notes,
  }) async {
    await _send('POST', '/alerts', {
      'type': type,
      if (busId != null) 'busId': busId,
      if (tripId != null) 'tripId': tripId,
      if (lat != null) 'lat': lat,
      if (lon != null) 'lon': lon,
      if (notes != null) 'notes': notes,
    });
  }

  void dispose() => _client.close();
}
