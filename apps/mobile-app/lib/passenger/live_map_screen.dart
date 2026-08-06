import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../config.dart';
import '../core/api_client.dart';
import '../core/app_scope.dart';
import '../core/fleet_socket.dart';
import '../core/models.dart';
import '../theme/app_theme.dart';
import '../ui/components.dart';

/// Bus marker moving on the route polyline, ETA per upcoming stop, occupancy
/// badge — docs §4.1's flagship passenger screen. Real route geometry from
/// `GET /api/routes/:id/geometry` + `/stops` (ApiClient, cached), real live
/// positions from [FleetSocket]'s `bus:update` feed (already applies the
/// degradation ladder server-side — see [LiveBus.confidenceTier]).
///
/// Optionally receives `{'directionId': ...}` as route arguments (e.g. tapping a
/// served route from home_screen.dart's nearby-stops list); otherwise opens on a
/// route picker, since a passenger arriving from "Track my bus" hasn't chosen one
/// yet.
class LiveMapScreen extends StatefulWidget {
  const LiveMapScreen({super.key});

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
  bool _argsRead = false;
  String? _directionId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsRead) return;
    _argsRead = true;
    final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    _directionId = args?['directionId'] as String?;
  }

  @override
  Widget build(BuildContext context) {
    final directionId = _directionId;
    if (directionId == null) {
      return _RoutePickerView(onSelected: (route) => setState(() => _directionId = route.directionId));
    }
    return _RouteLiveMapView(
      key: ValueKey(directionId),
      directionId: directionId,
      onChangeRoute: () => setState(() => _directionId = null),
    );
  }
}

class _RoutePickerView extends StatefulWidget {
  const _RoutePickerView({required this.onSelected});
  final ValueChanged<BusRoute> onSelected;

  @override
  State<_RoutePickerView> createState() => _RoutePickerViewState();
}

class _RoutePickerViewState extends State<_RoutePickerView> {
  bool _fetched = false;
  Future<List<BusRoute>>? _routesFuture;
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_fetched) return;
    _fetched = true;
    _routesFuture = ApiScope.of(context).routes();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Live Map',
      subtitle: 'Pick a route to track',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SoftTextField(
            controller: _searchController,
            hint: 'Search route number or name',
            icon: Icons.search_rounded,
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: AppTheme.gap),
          Expanded(
            child: FutureBuilder<List<BusRoute>>(
              future: _routesFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return Center(child: StateCard.loading(title: 'Loading routes'));
                }
                if (snapshot.hasError) {
                  return Center(
                    child: StateCard.error(
                      message: snapshot.error.toString(),
                      onRetry: () => setState(() => _routesFuture = ApiScope.of(context).routes(forceRefresh: true)),
                    ),
                  );
                }
                final routes = (snapshot.data ?? const []).where((r) => r.matches(_query)).toList()
                  ..sort((a, b) => a.displayName.compareTo(b.displayName));
                if (routes.isEmpty) {
                  return Center(child: StateCard.empty(title: 'No routes match', icon: Icons.search_off_rounded));
                }
                return ListView.separated(
                  itemCount: routes.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final route = routes[i];
                    return SoftCard(
                      onTap: () => widget.onSelected(route),
                      child: Row(
                        children: [
                          RouteBadge(label: route.shortLabel),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(route.displayName,
                                    style: Theme.of(context).textTheme.titleMedium,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 2),
                                MetaRow(icon: Icons.pin_drop_outlined, text: '${route.stopCount} stops'),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteLiveMapView extends StatefulWidget {
  const _RouteLiveMapView({super.key, required this.directionId, required this.onChangeRoute});
  final String directionId;
  final VoidCallback onChangeRoute;

  @override
  State<_RouteLiveMapView> createState() => _RouteLiveMapViewState();
}

class _RouteLiveMapViewState extends State<_RouteLiveMapView> {
  final _mapController = MapController();
  late Future<(List<LatLng> geometry, List<RouteStop> stops)> _routeDataFuture;
  bool _fitted = false;

  @override
  void initState() {
    super.initState();
    _routeDataFuture = _loadRouteData(ApiScope.of(context));
    FleetScope.read(context).subscribeRoute(widget.directionId);
  }

  Future<(List<LatLng>, List<RouteStop>)> _loadRouteData(ApiClient api) async {
    final geometry = await api.routeGeometry(widget.directionId);
    final stops = await api.routeStops(widget.directionId);
    return (geometry, stops);
  }

  @override
  void dispose() {
    FleetScope.read(context).unsubscribeRoute(widget.directionId);
    super.dispose();
  }

  void _fitBounds(List<LatLng> points) {
    if (_fitted || points.isEmpty) return;
    _fitted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _mapController.fitCamera(
        CameraFit.coordinates(coordinates: points, padding: const EdgeInsets.all(48)),
      );
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

    return Scaffold(
      body: Stack(
        children: [
          FutureBuilder<(List<LatLng>, List<RouteStop>)>(
            future: _routeDataFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(child: StateCard.error(message: snapshot.error.toString()));
              }
              final (geometry, stops) = snapshot.data!;
              _fitBounds(geometry);

              return AnimatedBuilder(
                animation: FleetScope.of(context),
                builder: (context, _) {
                  final fleet = FleetScope.of(context);
                  final buses = fleet.busesOnDirection(widget.directionId);

                  return FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: geometry.isNotEmpty
                          ? geometry[geometry.length ~/ 2]
                          : const LatLng(AppConfig.fallbackLat, AppConfig.fallbackLon),
                      initialZoom: 13,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.setutrack.mobile_app',
                      ),
                      if (geometry.isNotEmpty)
                        PolylineLayer(polylines: [
                          Polyline(points: geometry, strokeWidth: 4, color: theme.colorScheme.primary.withValues(alpha: 0.55)),
                        ]),
                      MarkerLayer(markers: [
                        for (final stop in stops)
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
                      tooltip: 'Choose another route',
                      onPressed: widget.onChangeRoute,
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
                            final count = FleetScope.of(context).busesOnDirection(widget.directionId).length;
                            return Text(
                              count == 0 ? 'No buses live right now' : '$count bus${count == 1 ? '' : 'es'} live',
                              style: theme.textTheme.titleMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
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
                  StatusPill(label: bus.freshnessLabel, color: AppTheme.tierColor(bus.confidenceTier)),
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
