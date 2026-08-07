import 'package:flutter/material.dart';

import '../core/app_scope.dart';
import '../core/models.dart';
import '../theme/app_theme.dart';
import '../ui/components.dart';

/// One real route *number* — a GTFS ref shared by every direction that carries
/// it (e.g. "35A" covers both "ISBT-17 => Sector-123" and the reverse). Distinct
/// from [BusRoute], which is one direction. Selecting a number, not a direction,
/// is what lets the Tracking tab show the whole fleet running that number at
/// once (both directions) rather than just one.
class RouteNumber {
  const RouteNumber({required this.routeId, required this.directionIds, required this.sampleName});
  final String routeId;
  final List<String> directionIds;
  final String sampleName;
}

/// Full-screen searchable list of real route numbers
/// (`GET /api/routes`, deduped by `routeId`), used to switch the Tracking tab
/// from "buses near me" into "the whole fleet running route N". Returns the
/// picked [RouteNumber] via `Navigator.pop(context, picked)`.
class RouteNumberPickerScreen extends StatefulWidget {
  const RouteNumberPickerScreen({super.key});

  @override
  State<RouteNumberPickerScreen> createState() => _RouteNumberPickerScreenState();
}

class _RouteNumberPickerScreenState extends State<RouteNumberPickerScreen> {
  bool _initialized = false;
  Future<List<RouteNumber>>? _numbersFuture;
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _numbersFuture = _loadRouteNumbers();
  }

  Future<List<RouteNumber>> _loadRouteNumbers({bool forceRefresh = false}) async {
    final routes = await ApiScope.of(context).routes(forceRefresh: forceRefresh);
    final byRouteId = <String, List<BusRoute>>{};
    for (final r in routes) {
      byRouteId.putIfAbsent(r.routeId ?? r.directionId, () => []).add(r);
    }
    final numbers = byRouteId.entries
        .map((e) => RouteNumber(
              routeId: e.key,
              directionIds: e.value.map((r) => r.directionId).toList(),
              sampleName: e.value.first.displayName,
            ))
        .toList()
      ..sort((a, b) => a.routeId.compareTo(b.routeId));
    return numbers;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Find a Route',
      leading: CircleIconButton(
        icon: Icons.arrow_back_rounded,
        tooltip: 'Back',
        onPressed: () => Navigator.pop(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SoftTextField(
            controller: _searchController,
            hint: 'Search route number, e.g. 35A',
            icon: Icons.search_rounded,
            autofocus: true,
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: AppTheme.gap),
          Expanded(
            child: FutureBuilder<List<RouteNumber>>(
              future: _numbersFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return Center(child: StateCard.loading(title: 'Loading routes'));
                }
                if (snapshot.hasError) {
                  return Center(
                    child: StateCard.error(
                      message: snapshot.error.toString(),
                      onRetry: () => setState(() {
                        _numbersFuture = _loadRouteNumbers(forceRefresh: true);
                      }),
                    ),
                  );
                }
                final query = _query.trim().toLowerCase();
                final numbers = (snapshot.data ?? const [])
                    .where((n) => query.isEmpty || n.routeId.toLowerCase().contains(query) || n.sampleName.toLowerCase().contains(query))
                    .toList();
                if (numbers.isEmpty) {
                  return Center(child: StateCard.empty(title: 'No routes match', icon: Icons.search_off_rounded));
                }
                return ListView.separated(
                  itemCount: numbers.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final n = numbers[i];
                    return SoftCard(
                      onTap: () => Navigator.pop(context, n),
                      child: Row(
                        children: [
                          RouteBadge(label: n.routeId, large: true),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(n.sampleName,
                                    style: Theme.of(context).textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 2),
                                MetaRow(
                                  icon: Icons.alt_route_rounded,
                                  text: n.directionIds.length > 1 ? '${n.directionIds.length} directions' : '1 direction',
                                ),
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
