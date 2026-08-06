import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/app_scope.dart';
import '../core/models.dart';
import '../theme/app_theme.dart';
import '../ui/components.dart';

/// "VIEW ALL TRIPS" destination from trip_updated_screen.dart. Real data —
/// `GET /api/trips?busId=` (trips.controller.ts's `findAll`) — most recent first,
/// scoped to the bus that just finished a trip so a driver sees their own shift
/// history, not the whole fleet's.
class TripHistoryScreen extends StatefulWidget {
  const TripHistoryScreen({super.key});

  @override
  State<TripHistoryScreen> createState() => _TripHistoryScreenState();
}

class _TripHistoryScreenState extends State<TripHistoryScreen> {
  bool _argsRead = false;
  String? _busId;
  Future<List<TripSession>>? _tripsFuture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsRead) return;
    _argsRead = true;
    final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    _busId = args?['busId'] as String?;
    _tripsFuture = ApiScope.of(context).trips(busId: _busId);
  }

  String _timeRange(TripSession trip) {
    final fmt = DateFormat('h:mm a');
    final start = trip.startedAt == null ? '—' : fmt.format(trip.startedAt!.toLocal());
    final end = trip.endedAt == null ? 'ongoing' : fmt.format(trip.endedAt!.toLocal());
    return '$start – $end';
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Trip History',
      subtitle: _busId == null ? null : 'Bus $_busId',
      child: FutureBuilder<List<TripSession>>(
        future: _tripsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Center(child: StateCard.loading(title: 'Loading trips'));
          }
          if (snapshot.hasError) {
            return Center(
              child: StateCard.error(
                message: snapshot.error.toString(),
                onRetry: () => setState(() {
                  _tripsFuture = ApiScope.of(context).trips(busId: _busId);
                }),
              ),
            );
          }
          final trips = snapshot.data ?? const [];
          if (trips.isEmpty) {
            return Center(
              child: StateCard.empty(title: 'No trips yet', icon: Icons.receipt_long_outlined),
            );
          }
          return ListView.separated(
            itemCount: trips.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final trip = trips[i];
              final displayName =
                  BusRoute(directionId: trip.directionId, routeId: trip.routeId, name: trip.routeName).displayName;
              return SoftCard(
                child: Row(
                  children: [
                    RouteBadge(label: trip.routeId ?? trip.directionId),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(displayName,
                              style: Theme.of(context).textTheme.titleMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 3),
                          MetaRow(icon: Icons.schedule_rounded, text: _timeRange(trip)),
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
              );
            },
          );
        },
      ),
    );
  }
}
