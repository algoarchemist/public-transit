import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../config.dart';
import '../core/app_scope.dart';
import '../core/connectivity_service.dart';
import '../core/fleet_socket.dart';
import '../core/location_service.dart';
import '../core/models.dart';
import '../theme/app_theme.dart';
import '../ui/components.dart';
import 'degraded_eta_view.dart';
import 'route_number_picker_screen.dart';

String _formatDistance(double m) => m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(1)} km';

/// Passenger dashboard's Tracking tab. Two real modes:
///
/// - **Nearby** (default): every live bus city-wide — the gateway auto-joins
///   every socket to the `admin:fleet` room (gateway.ts), so [FleetSocket]
///   already has the whole live fleet with no extra subscription — sorted by
///   real distance from the device's own location (location_service.dart, with
///   an honest fallback to the city centre when no fix is available).
/// - **Route fleet**: every live bus running one route *number* (both
///   directions — route_number_picker_screen.dart's [RouteNumber], not a single
///   [BusRoute] direction), so searching "35A" shows the whole fleet running
///   that number, not just whichever direction happened to be picked first.
class LiveMapScreen extends StatefulWidget {
  const LiveMapScreen({super.key, this.bottomInset = 0});

  /// Extra bottom padding so persistent cards don't sit under the floating
  /// bottom nav this screen is embedded above (passenger_shell.dart's Tracking
  /// tab) — 0 when pushed standalone.
  final double bottomInset;

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
  RouteNumber? _routeNumber;

  @override
  Widget build(BuildContext context) {
    final routeNumber = _routeNumber;
    if (routeNumber == null) {
      return _NearbyBusesView(
        bottomInset: widget.bottomInset,
        onPickRoute: (rn) => setState(() => _routeNumber = rn),
      );
    }
    return RouteFleetView(
      key: ValueKey(routeNumber.routeId),
      routeNumber: routeNumber,
      bottomInset: widget.bottomInset,
      onBack: () => setState(() => _routeNumber = null),
    );
  }
}

// ---------------------------------------------------------------------------
// Nearby mode
// ---------------------------------------------------------------------------

class _NearbyBusesView extends StatefulWidget {
  const _NearbyBusesView({required this.onPickRoute, this.bottomInset = 0});
  final ValueChanged<RouteNumber> onPickRoute;
  final double bottomInset;

  @override
  State<_NearbyBusesView> createState() => _NearbyBusesViewState();
}

class _NearbyBusesViewState extends State<_NearbyBusesView> {
  final _mapController = MapController();
  bool _initialized = false;
  LatLng _center = const LatLng(AppConfig.fallbackLat, AppConfig.fallbackLon);
  bool _locationIsReal = false;
  bool _locating = true;
  bool _centeredOnce = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _loadLocation();
  }

  Future<void> _loadLocation() async {
    final result = await LocationService.currentOrFallback();
    if (!mounted) return;
    setState(() {
      _center = result.point;
      _locationIsReal = result.isReal;
      _locating = false;
    });
  }

  Future<void> _openRoutePicker() async {
    final picked = await Navigator.push<RouteNumber>(
      context,
      MaterialPageRoute(builder: (_) => const RouteNumberPickerScreen()),
    );
    if (picked != null) widget.onPickRoute(picked);
  }

  void _showBusDetails(LiveBus bus) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _BusDetailsSheet(bus: bus),
    );
  }

  List<({LiveBus bus, double distanceM})> _sortedByDistance(List<LiveBus> buses) {
    final withDistance = buses
        .map((b) => (bus: b, distanceM: Geolocator.distanceBetween(_center.latitude, _center.longitude, b.lat, b.lon)))
        .toList()
      ..sort((a, b) => a.distanceM.compareTo(b.distanceM));
    return withDistance;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connectivity = ConnectivityScope.of(context);

    return Scaffold(
      body: Stack(
        children: [
          AnimatedBuilder(
            animation: connectivity,
            builder: (context, _) => AnimatedBuilder(
              animation: FleetScope.of(context),
              builder: (context, _) {
                final fleet = FleetScope.of(context);
                final ranked = _sortedByDistance(fleet.busList);

                if (connectivity.shouldShowTextOnly) {
                  return TextOnlyRouteView(
                    buses: ranked.map((r) => r.bus).toList(),
                    emptyMessage: 'No buses are currently transmitting anywhere in the city.',
                  );
                }

                if (!_centeredOnce && !_locating) {
                  _centeredOnce = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _mapController.move(_center, 14);
                  });
                }

                return FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(initialCenter: _center, initialZoom: 14),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.setutrack.mobile_app',
                    ),
                    MarkerLayer(markers: [
                      Marker(
                        point: _center,
                        width: 22,
                        height: 22,
                        child: const _UserLocationDot(),
                      ),
                      for (final r in ranked)
                        Marker(
                          point: r.bus.latLng,
                          width: 40,
                          height: 40,
                          child: GestureDetector(
                            onTap: () => _showBusDetails(r.bus),
                            child: _BusMarker(bus: r.bus),
                          ),
                        ),
                    ]),
                  ],
                );
              },
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppTheme.screenPadding, 12, AppTheme.screenPadding, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: (theme.brightness == Brightness.dark ? AppTheme.cardDark : Colors.white)
                              .withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                          boxShadow: AppTheme.cardShadow(theme.brightness == Brightness.dark),
                        ),
                        child: AnimatedBuilder(
                          animation: FleetScope.of(context),
                          builder: (context, _) {
                            final count = FleetScope.of(context).busList.length;
                            return Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    count == 0 ? 'No buses live right now' : '$count bus${count == 1 ? '' : 'es'} live nearby',
                                    style: theme.textTheme.titleMedium,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (!_locationIsReal && !_locating) ...[
                                  const SizedBox(width: 8),
                                  Icon(Icons.location_off_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
                                ],
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    CircleIconButton(
                      icon: Icons.directions_bus_filled_rounded,
                      tooltip: 'Find a route by number',
                      onPressed: _openRoutePicker,
                    ),
                    const SizedBox(width: 12),
                    _DataModeButton(connectivity: connectivity),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              minimum: EdgeInsets.only(bottom: widget.bottomInset),
              child: AnimatedBuilder(
                animation: FleetScope.of(context),
                builder: (context, _) {
                  final ranked = _sortedByDistance(FleetScope.of(context).busList);
                  if (ranked.isEmpty) return const SizedBox.shrink();
                  return SizedBox(
                    height: 128,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(AppTheme.screenPadding, 0, AppTheme.screenPadding, 12),
                      itemCount: ranked.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 10),
                      itemBuilder: (context, i) => _NearbyBusCard(
                        bus: ranked[i].bus,
                        distanceM: ranked[i].distanceM,
                        onTap: () => _showBusDetails(ranked[i].bus),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UserLocationDot extends StatelessWidget {
  const _UserLocationDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.primary,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 6, offset: Offset(0, 2))],
      ),
    );
  }
}

/// Compact card for the nearby strip — bus + route badge, confidence tier, real
/// distance from the device. Deliberately smaller than [_PrimaryBusCard] since
/// several of these sit in one horizontally-scrolling row.
class _NearbyBusCard extends StatelessWidget {
  const _NearbyBusCard({required this.bus, required this.distanceM, required this.onTap});
  final LiveBus bus;
  final double distanceM;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 190,
      child: SoftCard(
        onTap: onTap,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Flexible, not a bare child: routeId falls back to the full
                // busId (e.g. "sim-bus-4") when a bus hasn't resolved to a
                // route number yet, which is far wider than a real route badge
                // — this card's fixed 190px width needs the badge able to
                // shrink instead of pushing the StatusPill off the right edge.
                Flexible(child: RouteBadge(label: bus.routeId ?? bus.busId)),
                const Spacer(),
                // Same reasoning as the badge above: 'estimated'/'stale' tier
                // freshness labels ("Estimated · signal lost 45s ago") run much
                // longer than "Live" and were the other half of this card's
                // right-edge overflow — Flexible lets it ellipsize instead.
                Flexible(
                  child: StatusPill(label: bus.freshnessLabel, color: AppTheme.tierColor(bus.confidenceTier), compact: true),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              switch ((bus.nextStopName, bus.nextStopId)) {
                (final name?, _) => 'Heading to $name',
                (null, final id?) => 'Heading to Stop $id',
                (null, null) => 'Bus ${bus.busId}',
              },
              style: theme.textTheme.bodyMedium,
              // One line, not two: this card sits in a height-constrained
              // horizontal strip (128px, see the ListView below) alongside a
              // Spacer and a MetaRow — a second wrapped line doesn't fit that
              // budget and was the bottom overflow.
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const Spacer(),
            MetaRow(icon: Icons.social_distance_rounded, text: '${_formatDistance(distanceM)} away'),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Route-fleet mode
// ---------------------------------------------------------------------------

/// Public (not file-private like most widgets in this file) because
/// route_search_screen.dart also pushes this directly — "tap a suggested
/// journey" needs the same live map + ETA + next-stop view "find a route by
/// number" already builds, just entered from a search result instead of the
/// route-number picker.
class RouteFleetView extends StatefulWidget {
  const RouteFleetView({
    super.key,
    required this.routeNumber,
    required this.onBack,
    this.bottomInset = 0,
  });
  final RouteNumber routeNumber;
  final VoidCallback onBack;
  final double bottomInset;

  @override
  State<RouteFleetView> createState() => _RouteFleetViewState();
}

class _DirectionGeometry {
  const _DirectionGeometry({required this.geometry, required this.stops});
  final List<LatLng> geometry;
  final List<RouteStop> stops;
}

class _RouteFleetViewState extends State<RouteFleetView> {
  final _mapController = MapController();
  late Future<List<_DirectionGeometry>> _routeDataFuture;
  bool _fitted = false;
  bool _initialized = false;

  // Captured once rather than looked up fresh in dispose() — an ancestor
  // InheritedWidget lookup from inside dispose() can crash if this screen and
  // its FleetScope ancestor unmount in the same pass (a real, previously-caught
  // bug on this exact pattern — see git history). Holding the reference avoids
  // the lookup entirely.
  late final FleetSocket _fleet;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _fleet = FleetScope.read(context);
    final api = ApiScope.of(context);
    _routeDataFuture = Future.wait(widget.routeNumber.directionIds.map((id) async {
      final geometry = await api.routeGeometry(id);
      final stops = await api.routeStops(id);
      return _DirectionGeometry(geometry: geometry, stops: stops);
    }));
    for (final id in widget.routeNumber.directionIds) {
      _fleet.subscribeRoute(id);
    }
  }

  @override
  void dispose() {
    for (final id in widget.routeNumber.directionIds) {
      _fleet.unsubscribeRoute(id);
    }
    super.dispose();
  }

  void _fitBounds(List<LatLng> points) {
    if (_fitted || points.isEmpty) return;
    _fitted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _mapController.fitCamera(CameraFit.coordinates(coordinates: points, padding: const EdgeInsets.all(48)));
    });
  }

  void _showBusDetails(LiveBus bus) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _BusDetailsSheet(bus: bus),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connectivity = ConnectivityScope.of(context);

    return Scaffold(
      body: Stack(
        children: [
          AnimatedBuilder(
            animation: connectivity,
            builder: (context, _) => FutureBuilder<List<_DirectionGeometry>>(
              future: _routeDataFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: StateCard.error(message: snapshot.error.toString()));
                }
                final directions = snapshot.data!;
                // One stop can appear on more than one direction (a shared
                // interchange) — dedupe by real osm_node_id so it isn't drawn twice.
                final stopsByNode = <int, RouteStop>{};
                for (final d in directions) {
                  for (final s in d.stops) {
                    stopsByNode[s.osmNodeId] = s;
                  }
                }
                final allPoints = [for (final d in directions) ...d.geometry];

                return AnimatedBuilder(
                  animation: FleetScope.of(context),
                  builder: (context, _) {
                    final buses = FleetScope.of(context).busesOnRoute(widget.routeNumber.routeId);

                    if (connectivity.shouldShowTextOnly) {
                      return TextOnlyRouteView(stops: stopsByNode.values.toList(), buses: buses);
                    }

                    _fitBounds(allPoints);
                    return FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter:
                            allPoints.isNotEmpty ? allPoints[allPoints.length ~/ 2] : const LatLng(AppConfig.fallbackLat, AppConfig.fallbackLon),
                        initialZoom: 13,
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.setutrack.mobile_app',
                        ),
                        PolylineLayer(polylines: [
                          for (final d in directions)
                            if (d.geometry.isNotEmpty)
                              Polyline(points: d.geometry, strokeWidth: 2.2, color: theme.colorScheme.primary),
                        ]),
                        MarkerLayer(markers: [
                          for (final stop in stopsByNode.values)
                            Marker(
                              point: stop.latLng,
                              width: 10,
                              height: 10,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: theme.scaffoldBackgroundColor,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: theme.colorScheme.onSurfaceVariant, width: 1.5),
                                ),
                              ),
                            ),
                          for (final bus in buses)
                            Marker(
                              point: bus.latLng,
                              width: 40,
                              height: 40,
                              child: GestureDetector(
                                onTap: () => _showBusDetails(bus),
                                child: _BusMarker(bus: bus),
                              ),
                            ),
                        ]),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppTheme.screenPadding, 12, AppTheme.screenPadding, 0),
                child: Row(
                  children: [
                    CircleIconButton(
                      icon: Icons.arrow_back_rounded,
                      tooltip: 'Back to nearby buses',
                      onPressed: widget.onBack,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: (theme.brightness == Brightness.dark ? AppTheme.cardDark : Colors.white)
                              .withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                          boxShadow: AppTheme.cardShadow(theme.brightness == Brightness.dark),
                        ),
                        child: AnimatedBuilder(
                          animation: FleetScope.of(context),
                          builder: (context, _) {
                            final count = FleetScope.of(context).busesOnRoute(widget.routeNumber.routeId).length;
                            return Text(
                              count == 0
                                  ? 'Route ${widget.routeNumber.routeId} · no buses live'
                                  : 'Route ${widget.routeNumber.routeId} · $count live',
                              style: theme.textTheme.titleMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _DataModeButton(connectivity: connectivity),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              minimum: EdgeInsets.only(bottom: widget.bottomInset),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppTheme.screenPadding, 0, AppTheme.screenPadding, 12),
                child: AnimatedBuilder(
                  animation: FleetScope.of(context),
                  builder: (context, _) {
                    final buses = FleetScope.of(context).busesOnRoute(widget.routeNumber.routeId);
                    return _PrimaryBusCard(buses: buses, onTapDetails: _showBusDetails);
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The persistent "ETA + next stop" card the passenger dashboard reference
/// always shows at the bottom of the tracking screen, rather than only on
/// tapping a marker (that stays available too — see [_BusDetailsSheet]). Picks
/// the soonest-ETA bus as the one worth surfacing without a tap when more than
/// one is live on this route. No "Buy Ticket" button: ticketing was descoped
/// from this build entirely (fare calc, QR, payment — see docs §10), and a
/// button that does nothing would be worse than one that isn't there.
class _PrimaryBusCard extends StatelessWidget {
  const _PrimaryBusCard({required this.buses, required this.onTapDetails});
  final List<LiveBus> buses;
  final ValueChanged<LiveBus> onTapDetails;

  LiveBus? get _primary {
    if (buses.isEmpty) return null;
    final withEta = buses.where((b) => b.etaSeconds != null).toList()
      ..sort((a, b) => a.etaSeconds!.compareTo(b.etaSeconds!));
    return withEta.isNotEmpty ? withEta.first : buses.first;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bus = _primary;

    if (bus == null) {
      return SoftCard(
        child: Row(
          children: [
            Icon(Icons.directions_bus_outlined, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text('No buses live on this route right now', style: theme.textTheme.bodyMedium),
            ),
          ],
        ),
      );
    }

    return SoftCard(
      onTap: () => onTapDetails(bus),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppTheme.tierColor(bus.confidenceTier),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.directions_bus_filled_rounded, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bus.routeId == null ? 'Bus ${bus.busId}' : '${bus.routeId} · ${bus.busId}',
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (bus.nextStopName != null)
                      Text(
                        'Heading to ${bus.nextStopName}',
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              // Same fix as _NearbyBusCard: an unbounded StatusPill next to an
              // Expanded sibling still overflows the Row on a long
              // "estimated"/"stale" freshness label, since Expanded shrinking
              // the other side doesn't cap this one.
              Flexible(
                child: StatusPill(label: bus.freshnessLabel, color: AppTheme.tierColor(bus.confidenceTier), compact: true),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const MetaRow(icon: Icons.schedule_rounded, text: 'ETA'),
                    const SizedBox(height: 3),
                    Text(
                      formatEta(bus.etaSeconds),
                      style: theme.textTheme.displaySmall?.copyWith(fontSize: 24, color: theme.colorScheme.primary),
                    ),
                  ],
                ),
              ),
              Container(width: 1, height: 36, color: theme.colorScheme.outlineVariant),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const MetaRow(icon: Icons.pin_drop_outlined, text: 'Next Stop'),
                    const SizedBox(height: 3),
                    Text(
                      bus.nextStopName ?? (bus.nextStopId != null ? 'Stop ${bus.nextStopId}' : '—'),
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if ((bus.distanceToNextStopM ?? 0) > 0)
                      Text(
                        '${_formatDistance(bus.distanceToNextStopM!)} away',
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Small circular marker tinted by the degradation ladder's confidence tier
/// (docs §7.4) — the map must never render a live, estimated and stale bus the
/// same way.
class _BusMarker extends StatelessWidget {
  const _BusMarker({required this.bus});
  final LiveBus bus;

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.tierColor(bus.confidenceTier);
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: const Icon(Icons.directions_bus_filled_rounded, color: Colors.white, size: 20),
    );
  }
}

/// Cycles [DataSaverMode] (auto -> data saver -> full map -> auto). Filled blue
/// whenever the passenger has overridden the automatic bandwidth heuristic, so an
/// active override is visible at a glance rather than a silent app-state flag —
/// same "never hide the mode you're in" principle as the confidence-tier badges.
class _DataModeButton extends StatelessWidget {
  const _DataModeButton({required this.connectivity});
  final ConnectivityService connectivity;

  @override
  Widget build(BuildContext context) {
    final (icon, tooltip) = switch (connectivity.mode) {
      DataSaverMode.auto => (
          connectivity.shouldShowTextOnly ? Icons.text_snippet_outlined : Icons.map_outlined,
          'Auto — showing ${connectivity.shouldShowTextOnly ? 'text-only ETAs (weak/cellular connection)' : 'the live map (wifi)'}. Tap for data saver.',
        ),
      DataSaverMode.dataSaver => (Icons.text_snippet_rounded, 'Data saver — always text-only. Tap for full map.'),
      DataSaverMode.fullMap => (Icons.map_rounded, 'Full map — always shown, even on cellular. Tap for auto.'),
    };

    return CircleIconButton(
      icon: icon,
      tooltip: tooltip,
      filled: connectivity.mode != DataSaverMode.auto,
      onPressed: connectivity.cycleMode,
    );
  }
}

/// Bottom sheet on tapping a bus marker: confidence badge, occupancy, next 3
/// stops with ETA (docs §4.1 — "tap bus → trip details ... next 3 stops with
/// ETA"). No driver name / bus number beyond `busId` — that identity data isn't
/// part of the live feed today (trips.service.ts doesn't publish it over
/// Socket.IO), so this shows only what's real rather than inventing the rest.
class _BusDetailsSheet extends StatelessWidget {
  const _BusDetailsSheet({required this.bus});
  final LiveBus bus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final upcoming = bus.upcomingStops.take(3).toList();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppTheme.screenPadding, 8, AppTheme.screenPadding, AppTheme.screenPadding),
        child: SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Icon(Icons.directions_bus_filled_rounded, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('Bus ${bus.busId}',
                        style: theme.textTheme.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  Flexible(child: StatusPill(label: bus.freshnessLabel, color: AppTheme.tierColor(bus.confidenceTier))),
                ],
              ),
              const SizedBox(height: 12),
              StatusPill(
                label: AppTheme.occupancyLabel(bus.occupancy),
                color: AppTheme.occupancyColor(bus.occupancy),
                icon: Icons.groups_rounded,
              ),
              if (upcoming.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text('Next stops', style: theme.textTheme.titleSmall),
                const SizedBox(height: 10),
                StopTimeline(
                  activeIndex: 0,
                  stops: [
                    for (final stop in upcoming)
                      StopTimelineEntry(
                        name: stop.displayName,
                        trailing: Text(stop.etaLabel,
                            style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary)),
                      ),
                  ],
                ),
              ] else ...[
                const SizedBox(height: 16),
                Text('No ETA available yet', style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
