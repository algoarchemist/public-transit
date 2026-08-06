import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/components.dart';

/// App-wide light/dark/system theme mode, persisted across launches.
///
/// A plain [ChangeNotifier] behind an [InheritedNotifier] rather than a state
/// management package: this is one enum, read by one [MaterialApp] and toggled from
/// two app bars.
class ThemeController extends ChangeNotifier {
  static const _key = 'setutrack_theme_mode';

  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = switch (prefs.getString(_key)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    notifyListeners();
  }

  Future<void> set(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }

  /// Toggles between light and dark. From [ThemeMode.system] it flips to whichever
  /// is the opposite of what the user is currently *seeing*, so the button always
  /// visibly does something.
  Future<void> toggle(BuildContext context) async {
    final showingDark = _mode == ThemeMode.dark ||
        (_mode == ThemeMode.system && MediaQuery.platformBrightnessOf(context) == Brightness.dark);
    await set(showingDark ? ThemeMode.light : ThemeMode.dark);
  }
}

class ThemeScope extends InheritedNotifier<ThemeController> {
  const ThemeScope({super.key, required ThemeController super.notifier, required super.child});

  static ThemeController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    assert(scope?.notifier != null, 'No ThemeScope above this widget');
    return scope!.notifier!;
  }
}

/// The light/dark toggle, dropped into any app bar's `actions`.
class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ThemeScope.of(context);
    final showingDark = controller.mode == ThemeMode.dark ||
        (controller.mode == ThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);

    return CircleIconButton(
      tooltip: showingDark ? 'Switch to light mode' : 'Switch to dark mode',
      icon: showingDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
      onPressed: () => controller.toggle(context),
    );
  }
}
