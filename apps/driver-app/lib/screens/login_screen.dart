import 'package:flutter/material.dart';

/// Phone OTP login linked to depot-issued ID (see solution doc section 4.2).
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Driver Login')),
      body: Center(
        child: FilledButton(
          onPressed: () => Navigator.pushReplacementNamed(context, '/route-selection'),
          child: const Text('Login — TODO'),
        ),
      ),
    );
  }
}
