import 'package:flutter/material.dart';

import '../core/models.dart';
import '../theme/app_theme.dart';
import '../ui/components.dart';

/// The passenger-facing "ETA text-only view replaces live map rendering" fallback
/// (SIH25013_TrackMyRide_Solution.md §1.3). Same live data as the map — FleetSocket's
/// `bus:update` feed, already carrying the degradation-ladder confidence tier
/// (live/estimated/stale) and the ML-scored upcoming-stop ETAs — just rendered as a
/// list instead of raster map tiles. The tiles are the actual bandwidth cost on a
/// weak connection, not the JSON position updates; dropping them is what "degraded
/// mode" really buys, so this view never touches flutter_map/TileLayer at all.
class TextOnlyRouteView extends StatelessWidget {
  const TextOnlyRouteView({
    super.key,
    this.stops,
    required this.buses,
    this.emptyMessage,
  });

  /// Null in "nearby" mode (live_map_screen.dart's `_NearbyBusesView`), which has
  /// no single route's stop list to reference.
  final List<RouteStop>? stops;
  final List<LiveBus> buses;

  /// Overrides the default "No buses live right now" body copy — nearby mode
  /// has nothing route-specific to say instead ("N stops on this route").
  final String? emptyMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sorted = [...buses]..sort((a, b) {
        final ae = a.etaSeconds ?? (1 << 30);
        final be = b.etaSeconds ?? (1 << 30);
        return ae.compareTo(be);
      });

    return Container(
      color: theme.scaffoldBackgroundColor,
      width: double.infinity,
      height: double.infinity,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.screenPadding,
          92,
          AppTheme.screenPadding,
          AppTheme.screenPadding,
        ),
        children: [
          NestedCard(
            child: Row(
              children: [
                Icon(Icons.text_snippet_rounded, color: theme.colorScheme.primary, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Data saver — showing text-only ETAs instead of the live map.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.gap),
          if (sorted.isEmpty)
            StateCard.empty(
              title: 'No buses live right now',
              message: emptyMessage ??
                  (stops != null
                      ? '${stops!.length} stops on this route — check back once a bus starts its trip.'
                      : 'Check back once a bus starts its trip.'),
              icon: Icons.directions_bus_outlined,
            )
          else
            ...sorted.map(
              (bus) => Padding(
                padding: const EdgeInsets.only(bottom: AppTheme.gap),
                child: _BusEtaCard(bus: bus),
              ),
            ),
        ],
      ),
    );
  }
}

class _BusEtaCard extends StatelessWidget {
  const _BusEtaCard({required this.bus});
  final LiveBus bus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final upcoming = bus.upcomingStops.take(3).toList();

    return SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.directions_bus_filled_rounded, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Bus ${bus.busId}',
                  style: theme.textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Flexible(
                child: StatusPill(label: bus.freshnessLabel, color: AppTheme.tierColor(bus.confidenceTier), compact: true),
              ),
            ],
          ),
          const SizedBox(height: 8),
          StatusPill(
            label: AppTheme.occupancyLabel(bus.occupancy),
            color: AppTheme.occupancyColor(bus.occupancy),
            icon: Icons.groups_rounded,
            compact: true,
          ),
          if (upcoming.isNotEmpty) ...[
            const SizedBox(height: 14),
            StopTimeline(
              activeIndex: 0,
              stops: [
                for (final stop in upcoming)
                  StopTimelineEntry(
                    name: stop.displayName,
                    trailing: Text(
                      stop.etaLabel,
                      style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary),
                    ),
                  ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 10),
            Text('No ETA available yet', style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
