import 'package:flutter/material.dart';

import '../role_switch.dart';

/// Phone OTP login linked to depot-issued ID (see solution doc section 4.2).
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Driver Login'),
        actions: [
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            tooltip: 'Switch role',
            onPressed: () => switchRole(context),
          ),
        ],
      ),
      body: Center(
        child: FilledButton(
          onPressed: () => Navigator.pushReplacementNamed(context, '/driver/route-selection'),
          child: const Text('Login — TODO'),
        ),
      ),
    );
  }
}
