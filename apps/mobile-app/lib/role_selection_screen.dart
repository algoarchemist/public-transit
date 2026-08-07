import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted role choice: 'passenger' | 'driver'. Kept as a single source of
/// truth here since both main.dart (startup routing) and role_switch.dart
/// (mid-session role change) need the same key.
const roleKey = 'setutrack_user_role';

/// Startup screen: one app binary serves both the passenger and driver/conductor
/// flows (see SIH25013_TrackMyRide_Solution.md sections 4.1/4.2). The choice is
/// persisted so a returning user skips straight to their flow next launch.
class RoleSelectionScreen extends StatelessWidget {
  const RoleSelectionScreen({super.key});

  Future<void> _selectRole(BuildContext context, String role) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(roleKey, role);
    if (!context.mounted) return;
    Navigator.pushReplacementNamed(
      context,
      role == 'passenger' ? '/passenger/login' : '/driver/login',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            // Stretch rather than the default center: FilledButton/OutlinedButton
            // size to their own label width, so "I'm a Passenger" and "I'm a Driver
            // / Conductor" would otherwise sit at different left/right edges even
            // though their centers technically line up — stretching both to the
            // full width is what actually reads as centered.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.directions_bus, size: 72),
              const SizedBox(height: 16),
              Text(
                'SetuTrack',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              const Text('How are you using the app?', textAlign: TextAlign.center),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: () => _selectRole(context, 'passenger'),
                icon: const Icon(Icons.person),
                label: const Text("I'm a Passenger"),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _selectRole(context, 'driver'),
                icon: const Icon(Icons.badge),
                label: const Text("I'm a Driver / Conductor"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
