import 'package:flutter/material.dart';

/// Bus marker moving on route polyline, ETA countdown, occupancy badge.
/// TODO: subscribe to the realtime gateway (Socket.IO "bus:update" event) and
/// render via flutter_map; fall back to text-only ETA under low bandwidth
/// (see solution doc section 1.3, "Degraded UI mode").
class LiveMapScreen extends StatelessWidget {
  const LiveMapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Live Map')),
      body: const Center(child: Text('Live map — TODO')),
    );
  }
}
