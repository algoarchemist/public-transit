import 'package:flutter/material.dart';

import '../core/app_scope.dart';
import '../core/models.dart';
import '../theme/app_theme.dart';
import '../ui/components.dart';

/// Passenger dashboard's Alerts tab — real data from `GET /api/alerts`
/// (alerts.controller.ts), the same feed the admin dashboard's Alerts panel
/// reads. Relabeled for a passenger audience, but the type set is exactly what
/// this system can actually raise: driver-reported SOS/breakdown/traffic/
/// diversion/accident, or a system-detected route deviation. There is
/// deliberately no "Delay" or "Cancellation" type here — no schedule exists to
/// be delayed against, and no cancellation concept exists in the trip model, so
/// showing either would be inventing a signal this system doesn't have.
class PassengerAlertsScreen extends StatefulWidget {
  const PassengerAlertsScreen({super.key, this.bottomInset = 0});
  final double bottomInset;

  @override
  State<PassengerAlertsScreen> createState() => _PassengerAlertsScreenState();
}

class _PassengerAlertsScreenState extends State<PassengerAlertsScreen> {
  bool _initialized = false;
  Future<List<AlertItem>>? _alertsFuture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _alertsFuture = ApiScope.of(context).openAlerts();
  }

  void _refresh() => setState(() {
        _alertsFuture = ApiScope.of(context).openAlerts();
      });

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Recent Alerts',
      child: RefreshIndicator(
        onRefresh: () async => _refresh(),
        child: FutureBuilder<List<AlertItem>>(
          future: _alertsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return ListView(children: [Center(child: StateCard.loading(title: 'Loading alerts'))]);
            }
            if (snapshot.hasError) {
              return ListView(children: [Center(child: StateCard.error(message: snapshot.error.toString(), onRetry: _refresh))]);
            }
            final alerts = snapshot.data ?? const [];
            if (alerts.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  const SizedBox(height: 40),
                  StateCard.empty(
                    title: 'No open alerts',
                    message: "Nothing's been reported right now — service looks normal.",
                    icon: Icons.notifications_none_rounded,
                  ),
                ],
              );
            }
            return ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(bottom: widget.bottomInset),
              itemCount: alerts.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) => _AlertCard(alert: alerts[i]),
            );
          },
        ),
      ),
    );
  }
}

class _AlertPresentation {
  const _AlertPresentation(this.icon, this.color, this.label);
  final IconData icon;
  final Color color;
  final String label;
}

_AlertPresentation _presentationFor(String type) => switch (type) {
      'sos' => const _AlertPresentation(Icons.emergency_rounded, AppTheme.crowded, 'SOS'),
      'breakdown' => const _AlertPresentation(Icons.build_rounded, AppTheme.crowded, 'Breakdown'),
      'accident' => const _AlertPresentation(Icons.report_rounded, AppTheme.crowded, 'Accident'),
      'route_deviation' => const _AlertPresentation(Icons.alt_route_rounded, AppTheme.estimatedAmber, 'Route Deviation'),
      'road_diversion' => const _AlertPresentation(Icons.turn_slight_right_rounded, AppTheme.estimatedAmber, 'Diversion'),
      'traffic' => const _AlertPresentation(Icons.traffic_rounded, AppTheme.estimatedAmber, 'Traffic'),
      'signal_lost' => const _AlertPresentation(Icons.location_off_rounded, AppTheme.staleGrey, 'Signal Lost'),
      _ => _AlertPresentation(Icons.info_outline_rounded, AppTheme.primary, type),
    };

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert});
  final AlertItem alert;

  String _timeAgo(DateTime at) {
    final diff = DateTime.now().difference(at);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min${diff.inMinutes == 1 ? '' : 's'} ago';
    if (diff.inHours < 24) return '${diff.inHours} hr${diff.inHours == 1 ? '' : 's'} ago';
    if (diff.inDays == 1) return 'Yesterday';
    return '${diff.inDays} days ago';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _presentationFor(alert.type);

    return SoftCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: p.color.withValues(alpha: 0.12), shape: BoxShape.circle),
            child: Icon(p.icon, color: p.color, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(p.label, style: theme.textTheme.titleMedium)),
                    Text(_timeAgo(alert.raisedAt), style: theme.textTheme.bodySmall),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  alert.notes ?? (alert.busId != null ? 'Reported on bus ${alert.busId}' : 'No further details reported'),
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                if (alert.busId != null) ...[
                  const SizedBox(height: 8),
                  MetaRow(icon: Icons.directions_bus_filled_rounded, text: 'Bus ${alert.busId}'),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
