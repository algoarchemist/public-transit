import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../role_selection_screen.dart' show roleKey;
import '../role_switch.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../ui/components.dart';

/// Passenger dashboard's Profile tab, mirroring driver_profile_screen.dart's
/// shape. [phone] is the number verified at passenger_login_screen.dart — real
/// OTP-gated identity, same auth.service.ts flow the driver side uses. Still
/// thinner than the driver's profile by design: there is no passenger table
/// anywhere in this schema, so beyond the verified number there's genuinely
/// nothing else real to show (no name, no ticket history — ticketing is
/// descoped, docs §10).
class PassengerProfileScreen extends StatelessWidget {
  const PassengerProfileScreen({super.key, this.phone});

  final String? phone;

  Future<void> _signOut(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(roleKey);
    if (!context.mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, '/passenger/login', (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AppScaffold(
      title: 'Profile',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          SoftCard(
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(color: theme.colorScheme.primaryContainer, shape: BoxShape.circle),
                  child: Icon(Icons.person_rounded, color: theme.colorScheme.onPrimaryContainer, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(phone ?? 'Guest', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 3),
                      Text(
                        phone == null ? 'Not signed in' : 'Verified by SMS OTP (demo mode)',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SectionHeader('Preferences'),
          SoftCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                const _Row(icon: Icons.brightness_6_outlined, label: 'Appearance', trailing: ThemeToggleButton()),
                const Divider(height: 1, indent: 18, endIndent: 18),
                _Row(
                  icon: Icons.swap_horiz_rounded,
                  label: 'Switch to Driver / Conductor',
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => switchRole(context),
                ),
              ],
            ),
          ),
          const SectionHeader('About'),
          const SoftCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _Row(icon: Icons.directions_bus_filled_rounded, label: 'SetuTrack — SIH 2025 PS-25013'),
                Divider(height: 1, indent: 18, endIndent: 18),
                _Row(icon: Icons.map_outlined, label: 'Mohali Tricity · 103 real routes'),
              ],
            ),
          ),
          const SectionHeader('Session'),
          SoftCard(
            padding: EdgeInsets.zero,
            child: _Row(
              icon: Icons.logout_rounded,
              label: 'Sign out',
              labelColor: AppTheme.crowded,
              trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.crowded),
              onTap: () => _signOut(context),
            ),
          ),
          const NavClearance(),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.label, this.trailing, this.onTap, this.labelColor});
  final IconData icon;
  final String label;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? labelColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Row(
          children: [
            Icon(icon, size: 20, color: labelColor ?? theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 14),
            Expanded(child: Text(label, style: theme.textTheme.bodyLarge?.copyWith(color: labelColor))),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}
