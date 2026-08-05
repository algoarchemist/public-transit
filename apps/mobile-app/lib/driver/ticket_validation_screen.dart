import 'package:flutter/material.dart';

/// Camera QR scan (works offline, syncs on reconnect) or manual ticket entry fallback.
class TicketValidationScreen extends StatelessWidget {
  const TicketValidationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Validate Ticket')),
      body: const Center(child: Text('QR scan — TODO')),
    );
  }
}
