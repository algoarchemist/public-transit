import 'package:flutter/material.dart';

import '../core/app_scope.dart';
import '../core/models.dart';
import '../theme/app_theme.dart';
import '../ui/components.dart';

/// Pick the route/direction to run. Docs §4.2 describes this as picking an
/// "assigned route/shift from a depot roster" — no roster exists, so any of the
/// 103 real ingested directions (`GET /api/routes`) can be picked, the same
/// demo-scope simplification as the rest of the driver flow. Feeds `directionId`
/// forward into the real `POST /api/trips` call made on entering [OnTripScreen].
class RouteSelectionScreen extends StatefulWidget {
  const RouteSelectionScreen({super.key});

  @override
  State<RouteSelectionScreen> createState() => _RouteSelectionScreenState();
}

class _RouteSelectionScreenState extends State<RouteSelectionScreen> {
  bool _argsRead = false;
  String _busId = 'unknown-bus';
  String? _driverId;

  Future<List<BusRoute>>? _routesFuture;
  final _searchController = TextEditingController();
  String _query = '';
  BusRoute? _selected;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsRead) return;
    _argsRead = true;
    final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    _busId = (args?['busId'] as String?) ?? _busId;
    _driverId = args?['driverId'] as String?;
    _routesFuture = ApiScope.of(context).routes();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _startTrip() {
    final selected = _selected;
    if (selected == null) return;
    Navigator.pushNamed(
      context,
      '/driver/on-trip',
      arguments: {
        'busId': _busId,
        'driverId': _driverId,
        'directionId': selected.directionId,
        'routeId': selected.shortLabel,
        'routeName': selected.displayName,
        'route': selected,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Select Route',
      subtitle: 'Bus $_busId',
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
                  return Center(
                    child: StateCard.empty(title: 'No routes match', icon: Icons.search_off_rounded),
                  );
                }
                return ListView.separated(
                  itemCount: routes.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final route = routes[i];
                    final selected = route.directionId == _selected?.directionId;
                    return SoftCard(
                      onTap: () => setState(() => _selected = route),
                      border:
                          selected ? Border.all(color: Theme.of(context).colorScheme.primary, width: 1.6) : null,
                      child: Row(
                        children: [
                          RouteBadge(label: route.shortLabel),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  route.displayName,
                                  style: Theme.of(context).textTheme.titleMedium,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                MetaRow(icon: Icons.pin_drop_outlined, text: '${route.stopCount} stops'),
                              ],
                            ),
                          ),
                          if (selected)
                            Icon(Icons.check_circle_rounded, color: Theme.of(context).colorScheme.primary),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(height: AppTheme.gap),
          PillButton(
            label: 'Start Trip',
            icon: Icons.play_arrow_rounded,
            onPressed: _selected == null ? null : _startTrip,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
