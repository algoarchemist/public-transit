import 'package:flutter/material.dart';

/// Pick assigned route/shift from the depot roster (or manual select in demo).
class RouteSelectionScreen extends StatelessWidget {
  const RouteSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select Route')),
      body: Center(
        child: FilledButton(
          onPressed: () => Navigator.pushNamed(context, '/on-trip'),
          child: const Text('Start Trip — TODO'),
        ),
      ),
    );
  }
}
