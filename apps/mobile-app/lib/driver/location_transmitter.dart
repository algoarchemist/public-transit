import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:geolocator/geolocator.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../config.dart';
import 'ping_buffer.dart';

/// Divergence-triggered GPS transmitter: publishes a ping only when the bus's real
/// position has actually diverged from where simple constant-velocity extrapolation
/// (from the last transmitted fix) would put it — plus a mandatory heartbeat so a
/// silent device still shows up. On a straight road at steady speed this sends
/// almost nothing; approaching a stop or stuck in traffic, it sends often — exactly
/// when a ping carries information. See SIH25013_TrackMyRide_Solution.md §1.3 and
/// docs/IMPLEMENTATION_ARCHITECTURE.md §7 for the full design this implements.
///
/// This predictor is deliberately simple (straight-line, no route awareness) and
/// does NOT need to match the server's route-aware dead-reckoning predictor
/// (services/stream-processor/src/deadReckoning.ts) — this one only decides *when*
/// to send; the server's decides *what to show the passenger* when nothing arrives.
/// The two can differ freely without desyncing anything.
///
/// Known gap: a real "foreground service that survives screen-off" (per the
/// solution doc's driver-app requirement) needs native Android/iOS configuration
/// that doesn't exist yet — this repo has no android/ or ios/ folder until
/// `flutter create .` is run (see mobile-app/README.md). The Dart-level logic
/// below is complete and testable; the platform wiring is a follow-up.
class LocationTransmitter {
  final String busId;
  final String routeId;
  final String directionId;

  static const divergenceThresholdM = 50.0;
  static const heartbeatMs = 60000;
  // Below this speed, GPS-reported heading is mostly noise (a parked/near-stationary
  // device's heading jitters), so we predict "no movement" instead of extrapolating
  // along a meaningless bearing.
  static const minSpeedForHeadingMps = 0.5;
  static const lateArrivalThresholdMs = 30000;

  final PingBuffer _buffer = PingBuffer();
  _LastFix? _lastTransmitted;
  StreamSubscription<Position>? _positionSub;
  MqttServerClient? _client;
  bool _connected = false;
  int _occupancy = 0;

  int _sentCount = 0;
  int _bufferedCount = 0;

  int get sentCount => _sentCount;
  int get bufferedCount => _bufferedCount;
  bool get isConnected => _connected;

  LocationTransmitter({required this.busId, required this.routeId, required this.directionId});

  Future<void> start() async {
    await _ensureLocationPermission();
    await _buffer.open();
    await _connectMqtt();

    const settings = LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5);
    _positionSub = Geolocator.getPositionStream(locationSettings: settings).listen(_onPosition);
  }

  Future<void> stop() async {
    await _positionSub?.cancel();
    _positionSub = null;
    _client?.disconnect();
  }

  /// Called by the conductor's tally +/- buttons (see on_trip_screen.dart) — folded
  /// into the next transmitted ping rather than sent as a separate message.
  void updateOccupancy(int occupancy) {
    _occupancy = occupancy;
  }

  Future<void> _ensureLocationPermission() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      throw StateError('Location permission denied — cannot start GPS transmission');
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw StateError('Location services are disabled');
    }
  }

  Future<void> _connectMqtt() async {
    final client = MqttServerClient.withPort(
      AppConfig.mqttBrokerHost,
      'driver-$busId',
      AppConfig.mqttBrokerPort,
    );
    // Long keepalive: routine pings themselves reset it, and a full reconnect
    // handshake costs far more bytes than hours of position deltas would
    // (solution doc §1.3) — no reason to keep tearing the session down.
    client.keepAlivePeriod = 300;
    client.autoReconnect = true;
    client.onConnected = () {
      _connected = true;
      unawaited(_flushBuffer());
    };
    client.onDisconnected = () {
      _connected = false;
    };
    client.setProtocolV311();
    _client = client;

    try {
      await client.connect();
    } catch (_) {
      // No network right now. Not fatal: pings buffer to SQLite and flush once
      // autoReconnect succeeds (onConnected above).
      _connected = false;
    }
  }

  void _onPosition(Position position) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastTransmitted;

    final bool shouldSend;
    if (last == null) {
      shouldSend = true; // always send the first fix of a trip
    } else {
      final elapsedMs = now - last.timestampMs;
      final predicted = last.speedMps < minSpeedForHeadingMps
          ? _LatLon(last.lat, last.lon)
          : _destinationPoint(last.lat, last.lon, last.headingDeg, last.speedMps * elapsedMs / 1000);
      final divergenceM = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        predicted.lat,
        predicted.lon,
      );
      shouldSend = divergenceM > divergenceThresholdM || elapsedMs >= heartbeatMs;
    }

    if (!shouldSend) return;

    _lastTransmitted = _LastFix(
      lat: position.latitude,
      lon: position.longitude,
      speedMps: position.speed,
      headingDeg: position.heading,
      timestampMs: now,
    );
    unawaited(_sendOrBuffer(_buildPayload(position, now), now));
  }

  Map<String, dynamic> _buildPayload(Position position, int timestampMs) {
    return {
      'busId': busId,
      'routeId': routeId,
      'directionId': directionId,
      'lat': position.latitude,
      'lon': position.longitude,
      'speedKmh': position.speed * 3.6,
      'occupancy': _occupancy,
      'timestamp': timestampMs,
    };
  }

  Future<void> _sendOrBuffer(Map<String, dynamic> payload, int originalTimestampMs) async {
    if (_connected && await _publish(payload)) {
      _sentCount++;
      return;
    }
    await _buffer.enqueue(payload, originalTimestampMs);
    _bufferedCount++;
  }

  Future<bool> _publish(Map<String, dynamic> payload) async {
    final client = _client;
    if (client == null || client.connectionStatus?.state != MqttConnectionState.connected) {
      return false;
    }
    try {
      final builder = MqttClientPayloadBuilder();
      // TODO: swap for a compact protobuf encode (solution doc §1.3 — ~20-40
      // bytes/ping on the wire vs 200+ bytes JSON). stream-processor's consumer.ts
      // has the matching TODO on the decode side, so both ends change together.
      builder.addString(jsonEncode(payload));
      client.publishMessage('gps/$busId/ping', MqttQos.atMostOnce, builder.payload!);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Drains the offline backlog after reconnecting. Stops (rather than skipping)
  /// on the first failed publish, so a connection dropping mid-flush leaves the
  /// remaining backlog queued for next time instead of silently losing it.
  Future<void> _flushBuffer() async {
    final pending = await _buffer.peekAll();
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final buffered in pending) {
      if (!_connected) break;

      final isLate = now - buffered.originalTimestampMs > lateArrivalThresholdMs;
      final payload = {...buffered.payload, if (isLate) 'lateArrival': true};

      if (await _publish(payload)) {
        await _buffer.remove(buffered.id!);
        _bufferedCount--;
        _sentCount++;
      } else {
        break;
      }
    }
  }
}

class _LatLon {
  final double lat;
  final double lon;
  const _LatLon(this.lat, this.lon);
}

class _LastFix {
  final double lat;
  final double lon;
  final double speedMps;
  final double headingDeg;
  final int timestampMs;

  const _LastFix({
    required this.lat,
    required this.lon,
    required this.speedMps,
    required this.headingDeg,
    required this.timestampMs,
  });
}

const _earthRadiusM = 6371000.0;

/// Standard haversine "destination point given distance and bearing" — straight-line
/// projection, deliberately NOT route-aware (see class doc above).
_LatLon _destinationPoint(double lat, double lon, double bearingDeg, double distanceM) {
  final bearing = bearingDeg * pi / 180;
  final lat1 = lat * pi / 180;
  final lon1 = lon * pi / 180;
  final angularDist = distanceM / _earthRadiusM;

  final lat2 = asin(sin(lat1) * cos(angularDist) + cos(lat1) * sin(angularDist) * cos(bearing));
  final lon2 = lon1 +
      atan2(
        sin(bearing) * sin(angularDist) * cos(lat1),
        cos(angularDist) - sin(lat1) * sin(lat2),
      );

  return _LatLon(lat2 * 180 / pi, lon2 * 180 / pi);
}
