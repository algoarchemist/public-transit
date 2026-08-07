import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../core/app_scope.dart';
import '../core/models.dart';
import '../theme/app_theme.dart';
import '../ui/bus_illustration.dart';
import '../ui/components.dart';
import 'schedule_start_screen.dart' show StartTimeReason;

enum _Phase { locating, acquired, failed }

/// GPS auto-detect: acquires a real fix via [Geolocator], reports the device's
/// own reported accuracy, and checks how far that fix actually sits from the
/// picked route's real polyline (a second, more meaningful accuracy signal than
/// the raw device number — "close to the road you're about to drive" is what
/// actually matters to a dispatcher). Falls back to
/// [ScheduleStartScreen]'s manual-entry mode on denial/timeout, or on request.
class TripStartScreen extends StatefulWidget {
  const TripStartScreen({super.key});

  @override
  State<TripStartScreen> createState() => _TripStartScreenState();
}

class _TripStartScreenState extends State<TripStartScreen> {
  static const _timeout = Duration(seconds: 12);
  static const _goodAccuracyM = 20.0;
  static const _fairAccuracyM = 50.0;
  static const _onRouteM = 80.0; // how close to the polyline counts as "on route"

  bool _argsRead = false;
  String _busId = 'unknown-bus';
  String? _driverId;
  String _directionId = '';
  String? _routeId;
  String? _routeName;
  BusRoute? _route;
  DateTime? _scheduledStart;

  _Phase _phase = _Phase.locating;
  Position? _position;
  double? _distanceFromRouteM;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsRead) return;
    _argsRead = true;
    final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    _busId = (args?['busId'] as String?) ?? _busId;
    _driverId = args?['driverId'] as String?;
    _directionId = (args?['directionId'] as String?) ?? '';
    _routeId = args?['routeId'] as String?;
    _routeName = args?['routeName'] as String?;
    _route = args?['route'] as BusRoute?;
    _scheduledStart = args?['scheduledStart'] as DateTime?;
    _detect();
  }

  String get _routeLabel => _route?.displayName ?? _routeName ?? _routeId ?? _directionId;

  Future<void> _detect() async {
    setState(() {
      _phase = _Phase.locating;
      _error = null;
    });
    final api = ApiScope.of(context); // grabbed before any await — see note below

    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        throw StateError('Location permission denied');
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw StateError('Location services are disabled');
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(_timeout);

      double? distanceFromRoute;
      if (_directionId.isNotEmpty) {
        try {
          final geometry = await api.routeGeometry(_directionId);
          distanceFromRoute = _nearestVertexDistanceM(position, geometry);
        } catch (_) {
          // Route-relevance is a bonus signal on top of the raw GPS fix — a
          // failed geometry fetch (e.g. offline) must not fail the whole screen,
          // it just means only the device accuracy is shown.
        }
      }

      if (!mounted) return;
      setState(() {
        _position = position;
        _distanceFromRouteM = distanceFromRoute;
        _phase = _Phase.acquired;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = err is TimeoutException
            ? "Couldn't get a GPS fix in time."
            : err is StateError
                ? err.message
                : 'GPS error: $err';
      });
    }
  }

  /// Nearest-vertex distance to the route polyline — an approximation of true
  /// point-to-segment distance, cheap and honest about being one (real segment
  /// spacing in this snapshot is dense enough that the difference is a few
  /// metres, not enough to change the Good/Fair/Poor band this feeds).
  double _nearestVertexDistanceM(Position pos, List<LatLng> geometry) {
    double best = double.infinity;
    for (final point in geometry) {
      final d = Geolocator.distanceBetween(pos.latitude, pos.longitude, point.latitude, point.longitude);
      if (d < best) best = d;
    }
    return best;
  }

  void _enterManually() {
    Navigator.pushReplacementNamed(
      context,
      '/driver/schedule-start',
      arguments: {
        'busId': _busId,
        'driverId': _driverId,
        'directionId': _directionId,
        'routeId': _routeId,
        'routeName': _routeName,
        'route': _route,
        'reason': StartTimeReason.gpsUnavailable,
        'scheduledStart': _scheduledStart,
      },
    );
  }

  void _startTrip() {
    Navigator.pushReplacementNamed(
      context,
      '/driver/on-trip',
      arguments: {
        'busId': _busId,
        'driverId': _driverId,
        'directionId': _directionId,
        'routeId': _routeId,
        'routeName': _routeName,
        'route': _route,
        'scheduledStart': _scheduledStart,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.screenPadding),
          child: Column(
            children: [
              const SizedBox(height: 4),
              Row(
                children: [
                  CircleIconButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: 'Back',
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Text(_routeLabel, style: theme.textTheme.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text('Bus $_busId', style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  const SizedBox(width: 44),
                ],
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 24),
                      const Center(child: PunjabBusIllustration(width: 160, height: 92)),
                      const SizedBox(height: 24),
                      switch (_phase) {
                        _Phase.locating => const _LocatingBlock(),
                        _Phase.acquired => _AcquiredBlock(
                            position: _position!,
                            distanceFromRouteM: _distanceFromRouteM,
                            goodAccuracyM: _goodAccuracyM,
                            fairAccuracyM: _fairAccuracyM,
                            onRouteM: _onRouteM,
                          ),
                        _Phase.failed => _FailedBlock(message: _error ?? 'GPS unavailable'),
                      },
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
              if (_phase == _Phase.acquired)
                PillButton(label: 'Start Trip', icon: Icons.play_arrow_rounded, onPressed: _startTrip)
              else if (_phase == _Phase.failed)
                PillButton(label: 'Retry GPS', icon: Icons.refresh_rounded, onPressed: _detect),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _enterManually,
                child: Text(
                  'ENTER START TIME MANUALLY',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocatingBlock extends StatefulWidget {
  const _LocatingBlock();

  @override
  State<_LocatingBlock> createState() => _LocatingBlockState();
}

class _LocatingBlockState extends State<_LocatingBlock> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        SizedBox(
          width: 96,
          height: 96,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => Stack(
              alignment: Alignment.center,
              children: [
                for (final delay in [0.0, 0.33, 0.66])
                  Builder(builder: (context) {
                    final t = (_controller.value + delay) % 1.0;
                    return Opacity(
                      opacity: (1 - t).clamp(0, 1),
                      child: Container(
                        width: 96 * t,
                        height: 96 * t,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: theme.colorScheme.primary, width: 2),
                        ),
                      ),
                    );
                  }),
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(color: theme.colorScheme.primary, shape: BoxShape.circle),
                  child: const Icon(Icons.gps_fixed_rounded, color: Colors.white, size: 16),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text('Detecting your location…', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          'Checking GPS accuracy against your selected route.',
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _AcquiredBlock extends StatelessWidget {
  const _AcquiredBlock({
    required this.position,
    required this.distanceFromRouteM,
    required this.goodAccuracyM,
    required this.fairAccuracyM,
    required this.onRouteM,
  });

  final Position position;
  final double? distanceFromRouteM;
  final double goodAccuracyM;
  final double fairAccuracyM;
  final double onRouteM;

  (String, Color) _accuracyBand(double m) {
    if (m <= goodAccuracyM) return ('Good', AppTheme.liveGreen);
    if (m <= fairAccuracyM) return ('Fair', AppTheme.estimatedAmber);
    return ('Poor', AppTheme.crowded);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (accLabel, accColor) = _accuracyBand(position.accuracy);
    final distance = distanceFromRouteM;
    final onRoute = distance != null && distance <= onRouteM;

    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(color: AppTheme.liveGreen.withValues(alpha: 0.12), shape: BoxShape.circle),
          child: const Icon(Icons.check_circle_rounded, color: AppTheme.liveGreen, size: 34),
        ),
        const SizedBox(height: 16),
        Text('Location Acquired', style: theme.textTheme.titleMedium),
        const SizedBox(height: 16),
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.gps_fixed_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Expanded(child: Text('GPS accuracy', style: theme.textTheme.bodyMedium)),
                  StatusPill(label: '$accLabel · ±${position.accuracy.round()}m', color: accColor, compact: true),
                ],
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.route_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Expanded(child: Text('Distance from route', style: theme.textTheme.bodyMedium)),
                  StatusPill(
                    label: distance == null
                        ? 'Unknown'
                        : (onRoute ? 'On route · ${distance.round()}m' : '${distance.round()}m away'),
                    color: distance == null
                        ? AppTheme.staleGrey
                        : (onRoute ? AppTheme.liveGreen : AppTheme.estimatedAmber),
                    compact: true,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FailedBlock extends StatelessWidget {
  const _FailedBlock({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(color: AppTheme.crowded.withValues(alpha: 0.10), shape: BoxShape.circle),
          child: const Icon(Icons.location_off_rounded, color: AppTheme.crowded, size: 36),
        ),
        const SizedBox(height: 16),
        Text('GPS Signal Unavailable', style: theme.textTheme.headlineMedium, textAlign: TextAlign.center),
        const SizedBox(height: 6),
        Text(
          message,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
