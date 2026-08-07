import 'package:flutter/material.dart';

import '../ui/components.dart';
import 'live_map_screen.dart';
import 'passenger_alerts_screen.dart';
import 'passenger_profile_screen.dart';
import 'route_search_screen.dart';

/// Passenger dashboard's bottom-nav shell — Tracking / Routes / Alerts /
/// Profile, the reference design's four-tab bar. All four are real, persistent
/// tab bodies (unlike driver_shell.dart's "Trips", nothing here is a wizard
/// step), so this is a plain [IndexedStack] under the floating nav — same
/// "float above content" positioning every screen in this app uses, not
/// `Scaffold.bottomNavigationBar`.
class PassengerShell extends StatefulWidget {
  const PassengerShell({super.key, this.initialTab = 1, this.phone});

  /// Defaults to Routes (index 1) — the reference design's search "front page"
  /// is where a passenger who hasn't picked a route yet actually starts.
  final int initialTab;

  /// The number verified at passenger_login_screen.dart, for the Profile tab.
  /// Null if this shell was somehow reached without going through login.
  final String? phone;

  @override
  State<PassengerShell> createState() => _PassengerShellState();
}

/// Reserves room below scrollable tab content for the floating nav overlaid on
/// top — mirrors [NavClearance]'s own height so nothing sits underneath it.
const double _navClearance = 108;

class _PassengerShellState extends State<PassengerShell> {
  late int _tab = widget.initialTab.clamp(0, 3);

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        IndexedStack(
          index: _tab,
          children: [
            const LiveMapScreen(bottomInset: _navClearance),
            const RouteSearchScreen(bottomInset: _navClearance),
            const PassengerAlertsScreen(bottomInset: _navClearance),
            PassengerProfileScreen(phone: widget.phone),
          ],
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: FloatingBottomNav(
              index: _tab,
              onChanged: (i) => setState(() => _tab = i),
              items: const [
                NavItem(icon: Icons.location_on_rounded, label: 'Tracking'),
                NavItem(icon: Icons.directions_bus_filled_rounded, label: 'Routes'),
                NavItem(icon: Icons.notifications_rounded, label: 'Alerts'),
                NavItem(icon: Icons.person_rounded, label: 'Profile'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
