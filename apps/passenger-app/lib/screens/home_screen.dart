import 'package:flutter/material.dart';

/// Nearby stops, route/destination search, "Track my bus" quick action.
/// See SIH25013_TrackMyRide_Solution.md section 4.1.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SetuTrack')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Nearby stops & route search — TODO'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pushNamed(context, '/live-map'),
              child: const Text('Track my bus'),
            ),
            TextButton(
              onPressed: () => Navigator.pushNamed(context, '/ticketing'),
              child: const Text('Buy a ticket'),
            ),
            TextButton(
              onPressed: () => Navigator.pushNamed(context, '/voice-assistant'),
              child: const Text('Ask Amigo'),
            ),
          ],
        ),
      ),
    );
  }
}
