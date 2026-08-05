import 'package:flutter/material.dart';

import '../role_switch.dart';

/// Nearby stops, route/destination search, "Track my bus" quick action.
/// See SIH25013_TrackMyRide_Solution.md section 4.1.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SetuTrack'),
        actions: [
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            tooltip: 'Switch role',
            onPressed: () => switchRole(context),
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Nearby stops & route search — TODO'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pushNamed(context, '/passenger/live-map'),
              child: const Text('Track my bus'),
            ),
            TextButton(
              onPressed: () => Navigator.pushNamed(context, '/passenger/ticketing'),
              child: const Text('Buy a ticket'),
            ),
            TextButton(
              onPressed: () => Navigator.pushNamed(context, '/passenger/voice-assistant'),
              child: const Text('Ask Amigo'),
            ),
          ],
        ),
      ),
    );
  }
}
