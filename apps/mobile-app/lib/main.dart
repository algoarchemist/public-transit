import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/api_client.dart';
import 'core/app_scope.dart';
import 'core/connectivity_service.dart';
import 'core/fleet_socket.dart';
import 'driver/driver_shell.dart';
import 'driver/login_screen.dart';
import 'driver/on_trip_screen.dart';
import 'driver/route_selection_screen.dart';
import 'driver/schedule_start_screen.dart';
import 'driver/trip_start_screen.dart';
import 'driver/trip_updated_screen.dart';
import 'core/models.dart';
import 'passenger/passenger_login_screen.dart';
import 'passenger/passenger_shell.dart';
import 'role_selection_screen.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final theme = ThemeController();
  await theme.load();
  final connectivity = ConnectivityService();
  await connectivity.load();
  runApp(SetuTrackApp(themeController: theme, connectivityService: connectivity));
}

class SetuTrackApp extends StatefulWidget {
  const SetuTrackApp({super.key, required this.themeController, required this.connectivityService});

  final ThemeController themeController;
  final ConnectivityService connectivityService;

  @override
  State<SetuTrackApp> createState() => _SetuTrackAppState();
}

class _SetuTrackAppState extends State<SetuTrackApp> {
  late final ApiClient _api = ApiClient();

  /// One socket for the whole app, connected at startup. The passenger screens all
  /// read the same live fleet, so a per-screen connection would multiply server
  /// fan-out for identical data. The driver flow does not use it (it publishes over
  /// MQTT instead), but an idle socket costs nothing.
  late final FleetSocket _fleet = FleetSocket()..connect();

  @override
  void dispose() {
    _fleet.dispose();
    _api.dispose();
    widget.connectivityService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ThemeScope(
      notifier: widget.themeController,
      child: ConnectivityScope(
        notifier: widget.connectivityService,
        child: ApiScope(
          client: _api,
          child: FleetScope(
            notifier: _fleet,
            child: AnimatedBuilder(
              animation: widget.themeController,
              builder: (context, _) => MaterialApp(
                title: 'SetuTrack',
                debugShowCheckedModeBanner: false,
                theme: AppTheme.light(),
                darkTheme: AppTheme.dark(),
                themeMode: widget.themeController.mode,
                initialRoute: '/',
                routes: {
                  '/': (context) => const _StartupGate(),
                  '/role-selection': (context) => const RoleSelectionScreen(),
                  '/passenger/login': (context) => const PassengerLoginScreen(),
                  '/passenger/home': (context) {
                    final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
                    return PassengerShell(
                      phone: args?['phone'] as String?,
                      initialTab: (args?['initialTab'] as int?) ?? 1,
                    );
                  },
                  '/driver/login': (context) => const LoginScreen(),
                  '/driver/home': (context) {
                    final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
                    return DriverShell(
                      busId: (args?['busId'] as String?) ?? 'unknown-bus',
                      driverId: args?['driverId'] as String?,
                      initialTab: (args?['initialTab'] as int?) ?? 0,
                    );
                  },
                  '/driver/route-selection': (context) => const RouteSelectionScreen(),
                  '/driver/trip-start': (context) => const TripStartScreen(),
                  '/driver/schedule-start': (context) => const ScheduleStartScreen(),
                  '/driver/on-trip': (context) => const OnTripScreen(),
                  '/driver/trip-updated': (context) {
                    final args = ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>;
                    return TripUpdatedScreen(trip: args['trip'] as TripSession, route: args['route'] as BusRoute?);
                  },
                },
              ),
            ),
          ),
        ),
      ),
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
      // Neither login is persisted (same as the driver side always has been) —
      // a returning user skips role-selection but still verifies each launch.
      'passenger' => '/passenger/login',
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
