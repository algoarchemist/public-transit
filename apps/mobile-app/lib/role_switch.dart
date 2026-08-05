import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'role_selection_screen.dart' show roleKey;

/// Clears the persisted role and returns to the startup role-selection screen.
/// Lets one phone demo both the passenger and driver flows without reinstalling
/// — useful when a single device has to show both sides during judging.
Future<void> switchRole(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(roleKey);
  if (!context.mounted) return;
  Navigator.pushNamedAndRemoveUntil(context, '/role-selection', (route) => false);
}
