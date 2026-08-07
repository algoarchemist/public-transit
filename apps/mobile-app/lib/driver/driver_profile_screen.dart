import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../role_selection_screen.dart' show roleKey;
import '../role_switch.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../ui/components.dart';

/// Driver dashboard's Profile tab. Only shows what's real: the driver id and bus
/// id carried through from login (there's no driver profile record anywhere in
/// this system — auth.service.ts's OTP flow doesn't issue a session, so there's
/// nothing further to fetch), plus the app-wide theme toggle and the two real
/// navigation actions (switch role, sign out).
class DriverProfileScreen extends StatelessWidget {
  const DriverProfileScreen({super.key, required this.busId, required this.driverId});

  final String busId;
  final String? driverId;

  Future<void> _signOut(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(roleKey);
    if (!context.mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, '/driver/login', (route) => false);
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
                      Text(driverId ?? 'Driver', style: theme.textTheme.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 3),
                      MetaRow(icon: Icons.directions_bus_filled_rounded, text: 'Bus $busId'),
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
                const _Row(
                  icon: Icons.brightness_6_outlined,
                  label: 'Appearance',
                  trailing: ThemeToggleButton(),
                ),
                const Divider(height: 1, indent: 18, endIndent: 18),
                _Row(
                  icon: Icons.swap_horiz_rounded,
                  label: 'Switch role',
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => switchRole(context),
                ),
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
