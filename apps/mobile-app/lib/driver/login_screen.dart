import 'package:flutter/material.dart';

import '../role_switch.dart';
import '../theme/app_theme.dart';
import '../ui/components.dart';

/// Depot identity capture that feeds the real trip lifecycle (`POST /api/trips`'s
/// `busId`/`driverId` — see trips.service.ts and route_selection_screen.dart).
///
/// Full phone-OTP auth exists server-side (api-gateway's auth.controller.ts) but
/// issues no session token yet — nothing downstream checks one, so wiring an OTP
/// flow here would guard nothing. This stays a plain identity form until a real
/// token contract exists to justify it.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _busIdController = TextEditingController();
  final _driverNameController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _busIdController.dispose();
    _driverNameController.dispose();
    super.dispose();
  }

  void _continue() {
    final busId = _busIdController.text.trim();
    if (busId.isEmpty) {
      setState(() => _error = 'Enter the bus registration number');
      return;
    }
    final driverName = _driverNameController.text.trim();
    Navigator.pushReplacementNamed(
      context,
      '/driver/route-selection',
      arguments: {
        'busId': busId,
        'driverId': driverName.isEmpty ? null : driverName,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Driver Login',
      subtitle: 'Enter your bus to start a shift',
      actions: [
        CircleIconButton(
          icon: Icons.swap_horiz_rounded,
          tooltip: 'Switch role',
          onPressed: () => switchRole(context),
        ),
      ],
      child: Center(
        child: SingleChildScrollView(
          child: SoftCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Bus registration', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                SoftTextField(
                  controller: _busIdController,
                  hint: 'e.g. PB-65-A-1234',
                  icon: Icons.directions_bus_filled_rounded,
                  textCapitalization: TextCapitalization.characters,
                  autofocus: true,
                  onSubmitted: (_) => _continue(),
                ),
                const SizedBox(height: 16),
                Text('Driver name (optional)', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                SoftTextField(
                  controller: _driverNameController,
                  hint: 'Your name',
                  icon: Icons.badge_outlined,
                  onSubmitted: (_) => _continue(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: AppTheme.crowded, fontWeight: FontWeight.w600)),
                ],
                const SizedBox(height: 20),
                PillButton(label: 'Continue', icon: Icons.arrow_forward_rounded, onPressed: _continue),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
