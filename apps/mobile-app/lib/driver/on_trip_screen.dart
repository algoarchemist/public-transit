import 'dart:async';

import 'package:flutter/material.dart';

import 'location_transmitter.dart';

/// Current stop, next-stop ETA, passenger tally +/- buttons, delay-reason quick-tags.
/// Starts the divergence-triggered GPS transmitter (location_transmitter.dart) on
/// entry and stops it on exit — see SIH25013_TrackMyRide_Solution.md §1.3/§4.2 and
/// docs/IMPLEMENTATION_ARCHITECTURE.md §7 for the transmit-trigger design.
class OnTripScreen extends StatefulWidget {
  const OnTripScreen({super.key});

  @override
  State<OnTripScreen> createState() => _OnTripScreenState();
}

class _OnTripScreenState extends State<OnTripScreen> {
  // TODO: source these from the trip-start API response (route/direction picked in
  // route_selection_screen.dart) instead of placeholders once that flow is real.
  late final LocationTransmitter _transmitter;
  Timer? _statusTimer;
  int _occupancy = 0;
  String? _startError;

  @override
  void initState() {
    super.initState();
    _transmitter = LocationTransmitter(busId: 'demo-bus-1', routeId: '2G', directionId: 'demo-2g-outbound');
    _transmitter.start().catchError((Object e) {
      if (mounted) setState(() => _startError = e.toString());
    });
    // Status readout only — the transmitter itself reacts to position updates, not
    // this timer; this just refreshes the on-screen counters periodically.
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _transmitter.stop();
    super.dispose();
  }

  void _adjustOccupancy(int delta) {
    setState(() {
      _occupancy = (_occupancy + delta).clamp(0, 999);
      _transmitter.updateOccupancy(_occupancy);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('On Trip')),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_startError != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('GPS transmitter failed to start: $_startError', style: const TextStyle(color: Colors.red)),
            ),
          Text(_transmitter.isConnected ? 'MQTT connected' : 'MQTT offline — buffering locally'),
          const SizedBox(height: 8),
          Text('sent: ${_transmitter.sentCount}   buffered: ${_transmitter.bufferedCount}'),
          const SizedBox(height: 24),
          Text('Occupancy: $_occupancy', style: Theme.of(context).textTheme.titleLarge),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: () => _adjustOccupancy(-1)),
              IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () => _adjustOccupancy(1)),
            ],
          ),
          const SizedBox(height: 24),
          const Text('Delay-reason quick-tags — TODO'),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => Navigator.pushNamed(context, '/driver/ticket-validation'),
            child: const Text('Validate ticket'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('End trip'),
          ),
        ],
      ),
    );
  }
}
