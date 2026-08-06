import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../config.dart';
import 'models.dart';

/// Live fleet feed from `services/stream-processor/src/gateway.ts`.
///
/// Every connected client is joined to the all-fleet room server-side, so buses
/// start arriving on connect with no subscribe round-trip. `subscribeRoute` adds
/// the per-route room on top, which is what the passenger's route view wants.
///
/// State is kept as a `busId -> LiveBus` map rather than an event stream the UI
/// replays: a bus emits roughly once a second, and widgets want "everything I know
/// right now", not a log. [ChangeNotifier] so a single `AnimatedBuilder` can drive
/// the map and the list from one source.
///
/// Note the degradation ladder is *already applied server-side* — a bus that has
/// gone quiet keeps arriving here, with `confidenceTier` downgraded and `updatedAt`
/// still pointing at its last real ping. The app must render that difference rather
/// than treating every update as equally fresh.
class FleetSocket extends ChangeNotifier {
  io.Socket? _socket;
  final Map<String, LiveBus> _buses = {};
  Timer? _ageTicker;

  bool _connected = false;
  String? _error;

  Map<String, LiveBus> get buses => Map.unmodifiable(_buses);
  List<LiveBus> get busList => _buses.values.toList();
  bool get isConnected => _connected;
  String? get error => _error;
  bool get hasData => _buses.isNotEmpty;

  void connect() {
    if (_socket != null) return;

    final socket = io.io(
      AppConfig.socketUrl,
      io.OptionBuilder()
          // Websocket only: the default starts on HTTP long-polling and upgrades,
          // which on a weak connection means a slow first paint of the map.
          .setTransports(['websocket'])
          .enableReconnection()
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(5000)
          .build(),
    );

    socket.onConnect((_) {
      _connected = true;
      _error = null;
      notifyListeners();
    });
    socket.onDisconnect((_) {
      _connected = false;
      notifyListeners();
    });
    socket.onConnectError((err) {
      _connected = false;
      _error = 'Cannot reach the live feed at ${AppConfig.socketUrl}';
      notifyListeners();
    });

    socket.on('bus:update', (data) {
      if (data is! Map) return;
      try {
        final bus = LiveBus.fromJson(Map<String, dynamic>.from(data));
        _buses[bus.busId] = bus;
        notifyListeners();
      } catch (_) {
        // A malformed frame must never take the map down. Skip it; the next
        // update for that bus (about a second away) will replace it anyway.
      }
    });

    _socket = socket;

    // "Signal lost 40s ago" has to keep counting up even when nothing new arrives —
    // that is the entire point of the staleness badge. One 5s repaint is enough;
    // the labels are second- and minute-grained.
    _ageTicker = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_buses.isNotEmpty) notifyListeners();
    });
  }

  void subscribeRoute(String routeId) => _socket?.emit('subscribe:route', routeId);
  void unsubscribeRoute(String routeId) => _socket?.emit('unsubscribe:route', routeId);
  void subscribeBus(String busId) => _socket?.emit('subscribe:bus', busId);
  void unsubscribeBus(String busId) => _socket?.emit('unsubscribe:bus', busId);

  /// Buses currently running one direction of a route.
  List<LiveBus> busesOnDirection(String directionId) =>
      _buses.values.where((b) => b.directionId == directionId).toList();

  /// Buses on either direction of a route number (e.g. every "20A" bus).
  List<LiveBus> busesOnRoute(String routeId) =>
      _buses.values.where((b) => b.routeId == routeId).toList();

  /// Buses whose route passes a given stop, soonest arrival first. Backs the
  /// passenger's "when is my bus getting to my stop" view — the ETA comes from the
  /// ML batch scorer, already attached to each update.
  List<({LiveBus bus, int? etaSeconds})> busesApproachingStop(int osmNodeId) {
    final results = <({LiveBus bus, int? etaSeconds})>[];
    for (final bus in _buses.values) {
      final eta = bus.etaToStop(osmNodeId);
      if (eta != null) results.add((bus: bus, etaSeconds: eta));
    }
    results.sort((a, b) => (a.etaSeconds ?? 1 << 30).compareTo(b.etaSeconds ?? 1 << 30));
    return results;
  }

  @override
  void dispose() {
    _ageTicker?.cancel();
    _socket?.dispose();
    _socket = null;
    super.dispose();
  }
}

/// Single app-wide socket. One connection serves the map, the nearby list and the
/// stop view at once — opening one per screen would multiply fan-out for no gain.
class FleetScope extends InheritedNotifier<FleetSocket> {
  const FleetScope({super.key, required FleetSocket super.notifier, required super.child});

  static FleetSocket of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<FleetScope>();
    assert(scope?.notifier != null, 'No FleetScope above this widget');
    return scope!.notifier!;
  }

  /// For callers that want the instance without subscribing to every rebuild.
  static FleetSocket read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<FleetScope>();
    assert(scope?.notifier != null, 'No FleetScope above this widget');
    return scope!.notifier!;
  }
}
