import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/live_map_screen.dart';
import 'screens/ticketing_screen.dart';
import 'screens/voice_assistant_screen.dart';

void main() {
  runApp(const SetuTrackPassengerApp());
}

class SetuTrackPassengerApp extends StatelessWidget {
  const SetuTrackPassengerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SetuTrack',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      initialRoute: '/',
      routes: {
        '/': (context) => const HomeScreen(),
        '/live-map': (context) => const LiveMapScreen(),
        '/ticketing': (context) => const TicketingScreen(),
        '/voice-assistant': (context) => const VoiceAssistantScreen(),
      },
    );
  }
}
