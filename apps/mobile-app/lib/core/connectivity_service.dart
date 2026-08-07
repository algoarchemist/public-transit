import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How the passenger has chosen to trade live-map fidelity for bandwidth.
///
/// `auto` is the default and makes the actual "if bandwidth is very low, ETA
/// text-only view replaces live map rendering" call
/// (SIH25013_TrackMyRide_Solution.md §1.3) based on the OS-reported connection
/// type — the honest, portable proxy for "this link is probably slow/metered",
/// since Flutter has no cross-platform equivalent of Android's TelephonyManager
/// signal-strength API (that stays Android-only and out of scope here). `dataSaver`
/// and `fullMap` are explicit passenger overrides for when the heuristic guesses
/// wrong (fast mobile data, or deliberately slow wifi).
enum DataSaverMode { auto, dataSaver, fullMap }

/// Tracks the device's real connection type and the passenger's data-saver
/// preference, and combines them into the one decision every live screen needs:
/// render map tiles, or the text-only fallback. Closes the item
/// docs/IMPLEMENTATION_ARCHITECTURE.md §7.4 lists under "Not yet built": "Low-
/// bandwidth passenger-app fallbacks (text-only ETA...)".
///
/// Deliberately does not try to measure throughput or signal strength — connection
/// *type* (wifi/ethernet vs cellular vs none) is what's actually portable, and
/// cellular is exactly the case a passenger is most likely paying per-MB for and
/// most likely to have a weak signal on: the SIH25013 "low-bandwidth Punjab
/// tier-3 town" scenario this whole project is scoped around.
class ConnectivityService extends ChangeNotifier {
  static const _modeKey = 'setutrack_data_saver_mode';

  final Connectivity _connectivity;
  StreamSubscription<List<ConnectivityResult>>? _sub;

  DataSaverMode _mode = DataSaverMode.auto;
  List<ConnectivityResult> _results = const [ConnectivityResult.none];

  ConnectivityService({Connectivity? connectivity}) : _connectivity = connectivity ?? Connectivity();

  DataSaverMode get mode => _mode;

  bool get isOffline => _results.every((r) => r == ConnectivityResult.none);

  bool get isOnCellular =>
      _results.contains(ConnectivityResult.mobile) &&
      !_results.any((r) => r == ConnectivityResult.wifi || r == ConnectivityResult.ethernet);

  /// The single call every live screen actually needs. `auto` degrades on
  /// cellular — and once genuinely offline, where a map has nothing new to draw
  /// anyway — and shows the full map on wifi/ethernet.
  bool get shouldShowTextOnly => switch (_mode) {
        DataSaverMode.dataSaver => true,
        DataSaverMode.fullMap => false,
        DataSaverMode.auto => isOnCellular || isOffline,
      };

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = switch (prefs.getString(_modeKey)) {
      'dataSaver' => DataSaverMode.dataSaver,
      'fullMap' => DataSaverMode.fullMap,
      _ => DataSaverMode.auto,
    };

    try {
      _results = await _connectivity.checkConnectivity();
    } catch (_) {
      // connectivity_plus can throw on targets with no platform channel wired up
      // (some emulator/desktop configurations) — fail to "no signal", the safer
      // default for a low-bandwidth-first app, rather than crash startup on it.
      _results = const [ConnectivityResult.none];
    }
    notifyListeners();

    _sub = _connectivity.onConnectivityChanged.listen((results) {
      _results = results;
      notifyListeners();
    });
  }

  Future<void> setMode(DataSaverMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, mode.name);
  }

  /// auto -> data saver -> full map -> auto, for one tappable toggle.
  Future<void> cycleMode() => setMode(switch (_mode) {
        DataSaverMode.auto => DataSaverMode.dataSaver,
        DataSaverMode.dataSaver => DataSaverMode.fullMap,
        DataSaverMode.fullMap => DataSaverMode.auto,
      });

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

class ConnectivityScope extends InheritedNotifier<ConnectivityService> {
  const ConnectivityScope({super.key, required ConnectivityService super.notifier, required super.child});

  static ConnectivityService of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ConnectivityScope>();
    assert(scope?.notifier != null, 'No ConnectivityScope above this widget');
    return scope!.notifier!;
  }
}
