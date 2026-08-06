import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/app_scope.dart';
import '../core/models.dart';
import '../theme/app_theme.dart';
import '../ui/components.dart';
import 'location_transmitter.dart';

/// Current trip's live status: connection state, occupancy tally, and the driver's
/// end-trip control. Starts the divergence-triggered GPS transmitter
/// (location_transmitter.dart) only once the real trip has been created
/// server-side (`POST /api/trips`, via route_selection_screen.dart's picked
/// route), and reports `PATCH /api/trips/:id/end` on end/dispose — see
/// SIH25013_TrackMyRide_Solution.md §1.3/§4.2 and
/// docs/IMPLEMENTATION_ARCHITECTURE.md §7 for the transmit-trigger design this
/// still drives, and trips.controller.ts for the lifecycle endpoints now called.
class OnTripScreen extends StatefulWidget {
  const OnTripScreen({super.key});

  @override
  State<OnTripScreen> createState() => _OnTripScreenState();
}

enum _Phase { starting, running, ending, startFailed }

class _OnTripScreenState extends State<OnTripScreen> {
  bool _argsRead = false;
  late ApiClient _api;
  String _busId = 'unknown-bus';
  String? _driverId;
  String _directionId = '';
  String? _routeId;
  String? _routeName;
  BusRoute? _route;

  _Phase _phase = _Phase.starting;
  TripSession? _trip;
  String? _error;

  LocationTransmitter? _transmitter;
  Timer? _statusTimer;
  int _occupancy = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsRead) return;
    _argsRead = true;
    _api = ApiScope.of(context);
    final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    _busId = (args?['busId'] as String?) ?? _busId;
    _driverId = args?['driverId'] as String?;
    _directionId = (args?['directionId'] as String?) ?? '';
    _routeId = args?['routeId'] as String?;
    _routeName = args?['routeName'] as String?;
    _route = args?['route'] as BusRoute?;
    _startTrip();
  }

  Future<void> _startTrip() async {
    if (_directionId.isEmpty) {
      setState(() {
        _phase = _Phase.startFailed;
        _error = 'No route was selected';
      });
      return;
    }
    try {
      final trip = await _api.startTrip(busId: _busId, directionId: _directionId, driverId: _driverId);
      if (!mounted) return;

      final transmitter = LocationTransmitter(
        busId: _busId,
        routeId: _routeId ?? trip.routeId ?? _directionId,
        directionId: _directionId,
      );
      setState(() {
        _trip = trip;
        _transmitter = transmitter;
        _phase = _Phase.running;
      });

      unawaited(transmitter.start().catchError((Object e) {
        if (mounted) setState(() => _error = 'GPS transmitter failed to start: $e');
      }));
      _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (mounted) setState(() {});
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.startFailed;
        _error = e.message;
      });
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    unawaited(_transmitter?.stop());
    final trip = _trip;
    if (trip != null && _phase == _Phase.running) {
      // Best-effort: the driver navigating away without tapping "End trip" (killed
      // app, OS backgrounding) must still close the trip server-side rather than
      // leaving it 'running' in Postgres forever.
      unawaited(_api.endTrip(trip.tripId).catchError((Object _) => trip));
    }
    super.dispose();
  }

  void _adjustOccupancy(int delta) {
    final occupancy = (_occupancy + delta).clamp(0, 999);
    setState(() => _occupancy = occupancy);
    _transmitter?.updateOccupancy(occupancy);
    final trip = _trip;
    if (trip != null) {
      // Durable record for the crowd model (trips.service.ts's tally()) —
      // fire-and-forget, since the live occupancy badge already rides the next
      // GPS ping via the transmitter above; a failed POST here costs history, not
      // the live view.
      unawaited(_api.tally(trip.tripId, occupancy).catchError((Object _) {}));
    }
  }

  Future<void> _endTrip() async {
    final trip = _trip;
    if (trip == null) return;
    setState(() => _phase = _Phase.ending);
    try {
      await _transmitter?.stop();
      final ended = await _api.endTrip(trip.tripId);
      if (mounted) {
        Navigator.pushReplacementNamed(
          context,
          '/driver/trip-updated',
          arguments: {'trip': ended, 'route': _route},
        );
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _phase = _Phase.running);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not end trip: ${e.message}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_phase == _Phase.starting) {
      return AppScaffold(
        title: 'Starting Trip',
        child: Center(child: StateCard.loading(title: 'Starting trip', message: 'Bus $_busId')),
      );
    }
    if (_phase == _Phase.startFailed) {
      return AppScaffold(
        title: 'On Trip',
        child: Center(
          child: StateCard.error(
            message: _error ?? 'Could not start the trip',
            onRetry: () {
              setState(() => _phase = _Phase.starting);
              _startTrip();
            },
          ),
        ),
      );
    }

    final transmitter = _transmitter!;
    return AppScaffold(
      title: _routeName ?? _routeId ?? 'On Trip',
      subtitle: 'Bus $_busId${_trip != null ? ' · Trip #${_trip!.tripId}' : ''}',
      child: ListView(
        children: [
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                StatusPill(
                  label: transmitter.isConnected ? 'MQTT connected' : 'Offline — buffering',
                  color: transmitter.isConnected ? AppTheme.liveGreen : AppTheme.estimatedAmber,
                ),
                const SizedBox(height: 10),
                MetaRow(
                  icon: Icons.cloud_upload_outlined,
                  text: 'sent ${transmitter.sentCount} · buffered ${transmitter.bufferedCount}',
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: const TextStyle(color: AppTheme.crowded)),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppTheme.gap),
          SoftCard(
            child: Column(
              children: [
                Text('Occupancy', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 6),
                Text('$_occupancy', style: Theme.of(context).textTheme.displaySmall),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircleIconButton(icon: Icons.remove_rounded, onPressed: () => _adjustOccupancy(-1)),
                    const SizedBox(width: 24),
                    CircleIconButton(icon: Icons.add_rounded, filled: true, onPressed: () => _adjustOccupancy(1)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.gap),
          NestedCard(
            child: Text(
              'Delay-reason quick-tags — TODO',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: AppTheme.gapSection),
          PillButton(
            label: 'End Trip',
            icon: Icons.stop_circle_outlined,
            color: AppTheme.crowded,
            loading: _phase == _Phase.ending,
            onPressed: _phase == _Phase.ending ? null : _endTrip,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
