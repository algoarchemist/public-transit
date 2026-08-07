import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/app_scope.dart';
import '../core/location_service.dart';
import '../core/models.dart';
import '../role_switch.dart';
import '../theme/app_theme.dart';
import '../ui/components.dart';

/// Nearby stops (`GET /api/stops/nearby`, via [LocationService] + [ApiClient]) and
/// the "track my bus" quick action into the live map. Route/destination search
/// (docs §4.1) narrows this same list by stop name; a dedicated route picker isn't
/// built here — route_selection_screen.dart already has one on the driver side and
/// live_map_screen.dart is where a passenger actually watches a route once picked.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _initialized = false;
  Future<List<NearbyStop>>? _stopsFuture;
  bool _locationIsReal = true;
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _load();
  }

  void _load() {
    final api = ApiScope.of(context);
    setState(() {
      _stopsFuture = _fetchNearby(api);
    });
  }

  Future<List<NearbyStop>> _fetchNearby(ApiClient api) async {
    final loc = await LocationService.currentOrFallback();
    _locationIsReal = loc.isReal;
    return api.nearbyStops(lat: loc.point.latitude, lon: loc.point.longitude);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AppScaffold(
      title: 'SetuTrack',
      actions: [
        CircleIconButton(
          icon: Icons.mic_rounded,
          tooltip: 'Voice search',
          onPressed: () => Navigator.pushNamed(context, '/passenger/voice-search'),
        ),
        const SizedBox(width: 8),
        CircleIconButton(
          icon: Icons.swap_horiz_rounded,
          tooltip: 'Switch role',
          onPressed: () => switchRole(context),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SoftTextField(
            controller: _searchController,
            hint: 'Search stops, route number, or destination',
            icon: Icons.search_rounded,
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: AppTheme.gap),
          PillButton(
            label: 'Track my bus',
            icon: Icons.map_rounded,
            onPressed: () => Navigator.pushNamed(context, '/passenger/live-map'),
          ),
          SectionHeader(
            'Nearby stops',
            trailing: _locationIsReal
                ? null
                : const MetaRow(icon: Icons.location_off_outlined, text: 'Approximate — location unavailable'),
          ),
          Expanded(
            child: FutureBuilder<List<NearbyStop>>(
              future: _stopsFuture,
              builder: (context, snapshot) {
                if (_stopsFuture == null || snapshot.connectionState != ConnectionState.done) {
                  return Center(child: StateCard.loading(title: 'Finding stops near you'));
                }
                if (snapshot.hasError) {
                  return Center(
                    child: StateCard.error(message: snapshot.error.toString(), onRetry: _load),
                  );
                }
                final query = _query.trim().toLowerCase();
                final stops = (snapshot.data ?? const [])
                    .where((s) =>
                        query.isEmpty ||
                        s.displayName.toLowerCase().contains(query) ||
                        s.routes.any((r) =>
                            (r.routeId?.toLowerCase().contains(query) ?? false) ||
                            (r.routeName?.toLowerCase().contains(query) ?? false)))
                    .toList();
                if (stops.isEmpty) {
                  return Center(
                    child: StateCard.empty(
                      title: _query.trim().isEmpty ? 'No stops nearby' : 'No stops match "$_query"',
                      icon: Icons.location_off_outlined,
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: stops.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final stop = stops[i];
                    return SoftCard(
                      onTap: () => Navigator.pushNamed(
                        context,
                        '/passenger/live-map',
                        arguments: stop.routes.isEmpty ? null : {'directionId': stop.routes.first.directionId},
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(color: theme.colorScheme.primaryContainer, shape: BoxShape.circle),
                            child: Icon(Icons.directions_bus_filled_rounded,
                                color: theme.colorScheme.onPrimaryContainer, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(stop.displayName,
                                    style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 3),
                                MetaRow(icon: Icons.social_distance_rounded, text: stop.distanceLabel),
                                if (stop.routes.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: stop.routes
                                        .take(6)
                                        .map((r) => RouteBadge(label: r.routeId ?? r.directionId))
                                        .toList(),
                                  ),
                                ],
                              ],
                            ),
                          ),
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
