import 'package:flutter/material.dart';

/// Current stop, next-stop ETA, passenger tally +/- buttons, delay-reason quick-tags.
/// TODO: foreground GPS service publishing to MQTT every 5-20s (adaptive interval),
/// buffering to SQLite and batch-uploading on reconnect when offline
/// (solution doc section 1.3).
class OnTripScreen extends StatelessWidget {
  const OnTripScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('On Trip')),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('Passenger tally, delay tags — TODO'),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => Navigator.pushNamed(context, '/ticket-validation'),
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
