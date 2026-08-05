import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'driver/login_screen.dart';
import 'driver/on_trip_screen.dart';
import 'driver/route_selection_screen.dart';
import 'driver/ticket_validation_screen.dart';
import 'passenger/home_screen.dart';
import 'passenger/live_map_screen.dart';
import 'passenger/ticketing_screen.dart';
import 'passenger/voice_assistant_screen.dart';
import 'role_selection_screen.dart';

void main() {
  runApp(const SetuTrackApp());
}

class SetuTrackApp extends StatelessWidget {
  const SetuTrackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SetuTrack',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      initialRoute: '/',
      routes: {
        '/': (context) => const _StartupGate(),
        '/role-selection': (context) => const RoleSelectionScreen(),
        '/passenger/home': (context) => const HomeScreen(),
        '/passenger/live-map': (context) => const LiveMapScreen(),
        '/passenger/ticketing': (context) => const TicketingScreen(),
        '/passenger/voice-assistant': (context) => const VoiceAssistantScreen(),
        '/driver/login': (context) => const LoginScreen(),
        '/driver/route-selection': (context) => const RouteSelectionScreen(),
        '/driver/on-trip': (context) => const OnTripScreen(),
        '/driver/ticket-validation': (context) => const TicketValidationScreen(),
      },
    );
  }
}

/// Reads the persisted role choice and jumps straight into that flow; shows the
/// role-selection screen on first launch (or after `switchRole`, see role_switch.dart).
class _StartupGate extends StatefulWidget {
  const _StartupGate();

  @override
  State<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<_StartupGate> {
  @override
  void initState() {
    super.initState();
    _resolveStartRoute();
  }

  Future<void> _resolveStartRoute() async {
    final prefs = await SharedPreferences.getInstance();
    final role = prefs.getString(roleKey);
    if (!mounted) return;
    final route = switch (role) {
      'passenger' => '/passenger/home',
      'driver' => '/driver/login',
      _ => '/role-selection',
    };
    Navigator.pushReplacementNamed(context, route);
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
