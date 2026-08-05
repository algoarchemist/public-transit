import 'package:flutter/material.dart';

/// Route/stop selection -> fare calc -> UPI pay -> offline-verifiable QR e-ticket.
/// TODO: call api-gateway POST /tickets/fare then /tickets, integrate Razorpay/UPI.
class TicketingScreen extends StatelessWidget {
  const TicketingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Buy Ticket')),
      body: const Center(child: Text('Ticketing — TODO')),
    );
  }
}
