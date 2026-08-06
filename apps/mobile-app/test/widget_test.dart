import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:setutrack_mobile/main.dart';
import 'package:setutrack_mobile/theme/theme_controller.dart';

/// Smoke test: the app boots, and a first-launch user (no persisted role) lands on
/// the role picker rather than a blank screen or a crash.
///
/// Deliberately shallow. Every screen past this point talks to the api-gateway and
/// the live socket, so testing them properly needs a fake transport layer — worth
/// building when the demo is not the deadline.
void main() {
  testWidgets('first launch shows the role picker', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeController();
    await theme.load();

    await tester.pumpWidget(SetuTrackApp(themeController: theme));
    await tester.pumpAndSettle();

    expect(find.text("I'm a Passenger"), findsOneWidget);
    expect(find.text("I'm a Driver / Conductor"), findsOneWidget);
  });

  testWidgets('theme mode persists through the controller', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeController();
    await theme.load();
    expect(theme.mode, ThemeMode.system);

    await theme.set(ThemeMode.dark);
    expect(theme.mode, ThemeMode.dark);

    final reloaded = ThemeController();
    await reloaded.load();
    expect(reloaded.mode, ThemeMode.dark, reason: 'theme choice must survive a restart');
  });
}
