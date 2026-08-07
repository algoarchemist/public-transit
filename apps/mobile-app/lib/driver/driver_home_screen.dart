import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/app_scope.dart';
import '../core/models.dart';
import '../role_switch.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../ui/components.dart';

/// Driver dashboard home tab — reference design's "Today's Trips" screen, built
/// from real data: `GET /api/trips?busId=` (trips.controller.ts), filtered
/// client-side to trips whose scheduled or actual start falls today. There is no
/// depot roster in this system (route_selection_screen.dart's docstring already
/// says so) — "today's trips" means trips this bus has actually started or
/// scheduled today, not an invented shift assignment.
class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key, required this.busId, required this.driverId});

  final String busId;
  final String? driverId;

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  bool _initialized = false;
  late Future<List<TripSession>> _tripsFuture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ApiScope.of(context) is an InheritedWidget lookup — illegal in initState,
    // where the widget isn't attached to the tree yet (same reason
    // passenger/home_screen.dart's _fetchNearby waits for this hook too).
    if (_initialized) return;
    _initialized = true;
    _load();
  }

  void _load() {
    _tripsFuture = ApiScope.of(context).trips(busId: widget.busId, limit: 50);
  }

  void _refresh() => setState(_load);

  void _startTrip() => Navigator.pushNamed(
        context,
        '/driver/route-selection',
        arguments: {'busId': widget.busId, 'driverId': widget.driverId, 'flow': 'auto'},
      );

  void _scheduleStart() => Navigator.pushNamed(
        context,
        '/driver/route-selection',
        arguments: {'busId': widget.busId, 'driverId': widget.driverId, 'flow': 'schedule'},
      );

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = DateTime.now();

    return AppScaffold(
      title: widget.driverId ?? 'Driver',
      subtitle: '$_greeting · Bus ${widget.busId}',
      actions: [
        const ThemeToggleButton(),
        const SizedBox(width: 8),
        CircleIconButton(icon: Icons.swap_horiz_rounded, tooltip: 'Switch role', onPressed: () => switchRole(context)),
      ],
      child: RefreshIndicator(
        onRefresh: () async => _refresh(),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: PillButton(label: 'Start New Trip', icon: Icons.play_arrow_rounded, onPressed: _startTrip),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SecondaryPillButton(
                      label: 'Schedule',
                      icon: Icons.event_available_rounded,
                      onPressed: _scheduleStart,
                    ),
                  ),
                ],
              ),
              SectionHeader('Today, ${DateFormat('d MMM yyyy').format(today)}'),
              Text('Your Trips', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 14),
              FutureBuilder<List<TripSession>>(
                future: _tripsFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 30),
                      child: Center(child: StateCard.loading(title: "Loading today's trips")),
                    );
                  }
                  if (snapshot.hasError) {
                    return StateCard.error(message: snapshot.error.toString(), onRetry: _refresh);
                  }
                  final all = snapshot.data ?? const [];
                  final todays = all.where((t) {
                    final ref = t.scheduledStart ?? t.startedAt;
                    if (ref == null) return false;
                    final local = ref.toLocal();
                    return local.year == today.year && local.month == today.month && local.day == today.day;
                  }).toList()
                    ..sort((a, b) => (a.scheduledStart ?? a.startedAt ?? DateTime(0))
                        .compareTo(b.scheduledStart ?? b.startedAt ?? DateTime(0)));

                  if (todays.isEmpty) {
                    return StateCard.empty(
                      title: 'No trips yet today',
                      message: 'Start a trip to see it here.',
                      icon: Icons.directions_bus_outlined,
                    );
                  }

                  final nextIndex = todays.indexWhere((t) => t.status == 'running');

                  return Column(
                    children: [
                      for (var i = 0; i < todays.length; i++) ...[
                        _TripCard(trip: todays[i], isNext: i == nextIndex),
                        if (i != todays.length - 1) const SizedBox(height: 10),
                      ],
                    ],
                  );
                },
              ),
              const NavClearance(),
            ],
          ),
        ),
      ),
    );
  }
}

class _TripCard extends StatelessWidget {
  const _TripCard({required this.trip, required this.isNext});
  final TripSession trip;
  final bool isNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayName =
        BusRoute(directionId: trip.directionId, routeId: trip.routeId, name: trip.routeName).displayName;
    final scheduled = trip.scheduledStart == null ? '—' : DateFormat('h:mm a').format(trip.scheduledStart!.toLocal());
    final (statusLabel, statusColor) = switch (trip.status) {
      'running' => ('Running', AppTheme.liveGreen),
      'completed' => ('Completed', AppTheme.primary),
      'abandoned' => ('Abandoned', AppTheme.staleGrey),
      _ => ('Not Started', AppTheme.staleGrey),
    };

    return SoftCard(
      border: isNext ? Border.all(color: theme.colorScheme.primary, width: 1.6) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (isNext) ...[
                StatusPill(label: 'NEXT', color: theme.colorScheme.primary, compact: true),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(displayName, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 8),
          MetaRow(icon: Icons.directions_bus_filled_rounded, text: 'Bus ${trip.busId}'),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Scheduled Start', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(scheduled, style: theme.textTheme.titleMedium),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('Status', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  StatusPill(label: statusLabel, color: statusColor, compact: true),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
