import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/app_scope.dart';
import '../core/models.dart';
import '../theme/app_theme.dart';
import '../ui/components.dart';

enum _HistoryFilter { all, thisWeek, thisMonth }

/// Driver dashboard's History tab — reference design's "6. HISTORY (PAST TRIPS)".
/// Real data (`GET /api/trips?busId=`), filtered client-side by date range and
/// showing real Actual Start (`startedAt`) against real Scheduled
/// (`scheduledStart`, null unless the driver went through the schedule flow) —
/// nothing here is invented; a trip with no scheduled time just shows "—".
class DriverHistoryScreen extends StatefulWidget {
  const DriverHistoryScreen({super.key, required this.busId});

  final String busId;

  @override
  State<DriverHistoryScreen> createState() => _DriverHistoryScreenState();
}

class _DriverHistoryScreenState extends State<DriverHistoryScreen> {
  bool _initialized = false;
  late Future<List<TripSession>> _tripsFuture;
  _HistoryFilter _filter = _HistoryFilter.all;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ApiScope.of(context) is an InheritedWidget lookup — illegal in initState,
    // before the widget is attached to the tree.
    if (_initialized) return;
    _initialized = true;
    _tripsFuture = ApiScope.of(context).trips(busId: widget.busId, limit: 100);
  }

  void _refresh() => setState(() {
        _tripsFuture = ApiScope.of(context).trips(busId: widget.busId, limit: 100);
      });

  bool _matchesFilter(TripSession trip) {
    final start = trip.startedAt?.toLocal();
    if (start == null) return _filter == _HistoryFilter.all;
    final now = DateTime.now();
    switch (_filter) {
      case _HistoryFilter.all:
        return true;
      case _HistoryFilter.thisWeek:
        return now.difference(start).inDays < 7;
      case _HistoryFilter.thisMonth:
        return start.year == now.year && start.month == now.month;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'History',
      subtitle: 'Bus ${widget.busId}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 4),
          SoftSegmentedControl<_HistoryFilter>(
            options: _HistoryFilter.values,
            value: _filter,
            onChanged: (v) => setState(() => _filter = v),
            labelOf: (v) => switch (v) {
              _HistoryFilter.all => 'All',
              _HistoryFilter.thisWeek => 'This Week',
              _HistoryFilter.thisMonth => 'This Month',
            },
          ),
          const SizedBox(height: AppTheme.gap),
          Expanded(
            child: FutureBuilder<List<TripSession>>(
              future: _tripsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return Center(child: StateCard.loading(title: 'Loading trips'));
                }
                if (snapshot.hasError) {
                  return Center(child: StateCard.error(message: snapshot.error.toString(), onRetry: _refresh));
                }
                final trips = (snapshot.data ?? const []).where(_matchesFilter).toList();
                if (trips.isEmpty) {
                  return Center(child: StateCard.empty(title: 'No trips in this range', icon: Icons.receipt_long_outlined));
                }
                return ListView.separated(
                  itemCount: trips.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) => _HistoryCard(trip: trips[i]),
                );
              },
            ),
          ),
          const NavClearance(),
        ],
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.trip});
  final TripSession trip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayName =
        BusRoute(directionId: trip.directionId, routeId: trip.routeId, name: trip.routeName).displayName;
    final dateLabel = trip.startedAt == null ? '—' : DateFormat('d MMM yyyy').format(trip.startedAt!.toLocal());
    final actual = trip.startedAt == null ? '—' : DateFormat('h:mm a').format(trip.startedAt!.toLocal());
    final scheduled = trip.scheduledStart == null ? '—' : DateFormat('h:mm a').format(trip.scheduledStart!.toLocal());
    final delay = trip.startDelay;

    return SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RouteBadge(label: trip.routeId ?? trip.directionId),
              const SizedBox(width: 12),
              Expanded(
                child: Text(displayName, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              Text(dateLabel, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Actual Start', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(actual, style: theme.textTheme.titleMedium?.copyWith(color: AppTheme.liveGreen)),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Scheduled', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(scheduled, style: theme.textTheme.titleMedium),
                  ],
                ),
              ),
              StatusPill(
                label: switch (trip.status) {
                  'running' => 'Running',
                  'completed' => 'Completed',
                  'abandoned' => 'Abandoned',
                  _ => trip.status,
                },
                color: switch (trip.status) {
                  'running' => AppTheme.liveGreen,
                  'completed' => AppTheme.primary,
                  _ => AppTheme.staleGrey,
                },
                compact: true,
              ),
            ],
          ),
          if (delay != null && delay.inMinutes.abs() >= 1) ...[
            const SizedBox(height: 10),
            MetaRow(
              icon: delay.isNegative ? Icons.trending_down_rounded : Icons.trending_up_rounded,
              text: delay.isNegative
                  ? '${delay.abs().inMinutes} min early'
                  : '${delay.inMinutes} min late vs. scheduled',
              color: delay.isNegative ? AppTheme.liveGreen : AppTheme.estimatedAmber,
            ),
          ],
        ],
      ),
    );
  }
}
