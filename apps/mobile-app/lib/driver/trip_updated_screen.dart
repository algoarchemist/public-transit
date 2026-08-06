import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/models.dart';
import '../theme/app_theme.dart';
import '../ui/components.dart';

/// Shown right after `PATCH /api/trips/:id/end` succeeds (see on_trip_screen.dart's
/// `_endTrip`). Every value on the summary card is read from the real ended
/// [TripSession] and the [BusRoute] the driver picked in route_selection_screen.dart
/// — nothing here is a placeholder. No revenue/earnings figure: this app has no
/// fare/ticketing path (docs §10 — ticketing is descoped for this round), so there
/// is no real number to show.
class TripUpdatedScreen extends StatelessWidget {
  const TripUpdatedScreen({super.key, required this.trip, this.route});

  final TripSession trip;
  final BusRoute? route;

  void _backToRouteSelection(BuildContext context) {
    Navigator.popUntil(context, (r) => r.settings.name == '/driver/route-selection');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final endpoints = route?.endpoints;
    final routeLabel = route?.shortLabel ?? trip.routeId ?? trip.directionId;
    final routeName = route?.displayName ?? trip.routeName;
    final startedLabel = trip.startedAt == null ? '—' : DateFormat('h:mm a').format(trip.startedAt!.toLocal());

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.screenPadding),
          child: Column(
            children: [
              const SizedBox(height: 4),
              Row(
                children: [
                  CircleIconButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: 'Back',
                    onPressed: () => _backToRouteSelection(context),
                  ),
                  Expanded(
                    child: Text(
                      'Trip Summary',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  const SizedBox(width: 44), // balances the back button so the title stays centred
                ],
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      const SizedBox(height: 28),
                      const _SuccessBadge(),
                      const SizedBox(height: 28),
                      Text(
                        'Trip Updated Successfully!',
                        style: theme.textTheme.headlineMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Your trip has ended and been recorded.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 32),
                      SoftCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                RouteBadge(label: routeLabel, large: true),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (endpoints != null)
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                endpoints.$1,
                                                style: theme.textTheme.titleMedium,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            Padding(
                                              padding: const EdgeInsets.symmetric(horizontal: 6),
                                              child: Icon(Icons.arrow_forward_rounded,
                                                  size: 16, color: theme.colorScheme.onSurfaceVariant),
                                            ),
                                            Flexible(
                                              child: Text(
                                                endpoints.$2,
                                                style: theme.textTheme.titleMedium,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        )
                                      else
                                        Text(
                                          routeName ?? 'Route $routeLabel',
                                          style: theme.textTheme.titleMedium,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      const SizedBox(height: 2),
                                      StatusPill(
                                        label: trip.status == 'completed' ? 'Completed' : trip.status,
                                        color: trip.status == 'completed' ? AppTheme.liveGreen : AppTheme.staleGrey,
                                        compact: true,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
                            const Divider(height: 1),
                            const SizedBox(height: 16),
                            _SummaryRow(icon: Icons.directions_bus_filled_rounded, label: 'Bus ID', value: trip.busId),
                            const SizedBox(height: 12),
                            _SummaryRow(icon: Icons.schedule_rounded, label: 'Start Time', value: startedLabel),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
              PillButton(
                label: 'VIEW ALL TRIPS',
                icon: Icons.receipt_long_rounded,
                onPressed: () => Navigator.pushNamed(context, '/driver/trip-history', arguments: {'busId': trip.busId}),
              ),
              const SizedBox(height: 14),
              TextButton(
                onPressed: () => _backToRouteSelection(context),
                child: Text(
                  'BACK TO HOME',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const Spacer(),
        Text(value, style: theme.textTheme.titleMedium),
      ],
    );
  }
}

/// Large green success check with a scatter of small celebratory dots. Pops in
/// once with an elastic scale — a single restrained flourish, not a looping
/// animation, matching the rest of the app's "quiet unless it's telling you
/// something" motion language.
class _SuccessBadge extends StatelessWidget {
  const _SuccessBadge();

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 550),
      curve: Curves.elasticOut,
      builder: (context, t, child) => Transform.scale(scale: t.clamp(0, 1.15), child: child),
      child: SizedBox(
        width: 168,
        height: 168,
        child: Stack(
          alignment: Alignment.center,
          children: [
            _dot(top: 4, left: 20, color: AppTheme.primary, size: 10),
            _dot(top: 20, right: 6, color: AppTheme.estimatedAmber, size: 8),
            _dot(bottom: 22, left: 2, color: AppTheme.liveGreen, size: 7),
            _dot(bottom: 2, right: 26, color: AppTheme.primary, size: 9),
            _dot(top: 46, right: -2, color: AppTheme.liveGreen, size: 6),
            _dot(bottom: 46, left: -4, color: AppTheme.estimatedAmber, size: 6),
            Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(color: AppTheme.liveGreen.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: Center(
                child: Container(
                  width: 78,
                  height: 78,
                  decoration: const BoxDecoration(color: AppTheme.liveGreen, shape: BoxShape.circle),
                  child: const Icon(Icons.check_rounded, color: Colors.white, size: 42),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dot({double? top, double? bottom, double? left, double? right, required Color color, required double size}) {
    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      child: Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
    );
  }
}
