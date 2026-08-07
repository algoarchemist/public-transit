import 'package:flutter/material.dart';

import '../ui/components.dart';
import 'driver_history_screen.dart';
import 'driver_home_screen.dart';
import 'driver_profile_screen.dart';

/// Driver dashboard's bottom-nav shell — Home / Trips / History / Profile, the
/// reference design's four-tab bar (built from the app's existing
/// [FloatingBottomNav], the same floating-pill pattern the passenger side never
/// needed a 4-tab version of until now).
///
/// "Trips" is deliberately not a fourth in-place tab body: starting a trip is a
/// linear wizard (pick route -> schedule/GPS -> on-trip), not a persistent view,
/// so tapping it pushes route_selection_screen.dart as a real navigation step
/// instead of swapping an IndexedStack page — that keeps `Navigator.popUntil`
/// (trip_updated_screen.dart's "back to home") and the back button behaving the
/// way a wizard should. Each tab body (`DriverHomeScreen` etc.) already carries
/// its own [AppScaffold]/[Scaffold], so this shell only stacks the floating nav
/// on top — the same "float above content" positioning every other screen in
/// this app uses, not `Scaffold.bottomNavigationBar`.
class DriverShell extends StatefulWidget {
  const DriverShell({super.key, required this.busId, required this.driverId, this.initialTab = 0});

  final String busId;
  final String? driverId;
  final int initialTab;

  @override
  State<DriverShell> createState() => _DriverShellState();
}

class _DriverShellState extends State<DriverShell> {
  late int _tab = widget.initialTab.clamp(0, 3);

  void _onNavTap(int index) {
    if (index == 1) {
      Navigator.pushNamed(
        context,
        '/driver/route-selection',
        arguments: {'busId': widget.busId, 'driverId': widget.driverId, 'flow': 'auto'},
      );
      return;
    }
    setState(() => _tab = index);
  }

  @override
  Widget build(BuildContext context) {
    // Index 1 ("Trips") never has a body of its own — pressing it navigates away
    // instead (see _onNavTap) — so the IndexedStack only ever shows 0, 2 or 3.
    final bodyIndex = switch (_tab) { 2 => 2, 3 => 3, _ => 0 };

    return Stack(
      children: [
        IndexedStack(
          index: bodyIndex,
          children: [
            DriverHomeScreen(busId: widget.busId, driverId: widget.driverId),
            const SizedBox.shrink(), // never shown; keeps IndexedStack indices stable
            DriverHistoryScreen(busId: widget.busId),
            DriverProfileScreen(busId: widget.busId, driverId: widget.driverId),
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
              onChanged: _onNavTap,
              items: const [
                NavItem(icon: Icons.home_rounded, label: 'Home'),
                NavItem(icon: Icons.directions_bus_filled_rounded, label: 'Trips'),
                NavItem(icon: Icons.history_rounded, label: 'History'),
                NavItem(icon: Icons.person_rounded, label: 'Profile'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
