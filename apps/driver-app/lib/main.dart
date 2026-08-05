import 'package:flutter/material.dart';

import 'screens/login_screen.dart';
import 'screens/route_selection_screen.dart';
import 'screens/on_trip_screen.dart';
import 'screens/ticket_validation_screen.dart';

void main() {
  runApp(const SetuTrackDriverApp());
}

class SetuTrackDriverApp extends StatelessWidget {
  const SetuTrackDriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SetuTrack Driver',
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
        // Ruggedized/minimal-UI mode: large touch targets for budget devices
        // (solution doc section 1.2).
        textTheme: Typography.material2021().black.apply(fontSizeFactor: 1.15),
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const LoginScreen(),
        '/route-selection': (context) => const RouteSelectionScreen(),
        '/on-trip': (context) => const OnTripScreen(),
        '/ticket-validation': (context) => const TicketValidationScreen(),
      },
    );
  }
}
