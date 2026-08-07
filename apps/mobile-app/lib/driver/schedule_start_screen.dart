import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/api_client.dart';
import '../core/app_scope.dart';
import '../core/models.dart';
import '../theme/app_theme.dart';
import '../ui/bus_illustration.dart';
import '../ui/components.dart';

/// Why the driver landed on this screen — same wheel-and-confirm UI either way,
/// different banner and different field the confirmed time is submitted as.
enum StartTimeReason {
  /// Proactive: driver wants to record a predefined/expected start time before
  /// attempting GPS at all ("schedule a start with a predefined timing").
  /// Confirming here carries the value forward as `scheduledStart` into
  /// [TripStartScreen]'s GPS attempt.
  schedule,

  /// Reactive: [TripStartScreen] couldn't get a GPS fix (denied permission,
  /// disabled service, or timed out). Confirming here submits the value as the
  /// trip's real `startedAt`, straight into [OnTripScreen].
  gpsUnavailable,
}

/// The "Actual Start" time-wheel confirm screen — covers both the driver
/// dashboard reference's "3. EDIT START TIME" (predefined-timing / schedule case)
/// and "4. GPS UNAVAILABLE (MANUAL ENTRY)" screens, which are the same control
/// with a different banner. One implementation, one [StartTimeReason] away from
/// diverging, rather than two near-duplicate screens.
class ScheduleStartScreen extends StatefulWidget {
  const ScheduleStartScreen({super.key});

  @override
  State<ScheduleStartScreen> createState() => _ScheduleStartScreenState();
}

class _ScheduleStartScreenState extends State<ScheduleStartScreen> {
  bool _argsRead = false;
  late ApiClient _api;

  String _busId = 'unknown-bus';
  String? _driverId;
  String _directionId = '';
  String? _routeId;
  String? _routeName;
  BusRoute? _route;
  StartTimeReason _reason = StartTimeReason.schedule;
  DateTime? _carriedScheduledStart;

  late DateTime _picked;
  bool _busy = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsRead) return;
    _argsRead = true;
    _api = ApiScope.of(context);

    final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    _busId = (args?['busId'] as String?) ?? _busId;
    _driverId = args?['driverId'] as String?;
    _directionId = (args?['directionId'] as String?) ?? '';
    _routeId = args?['routeId'] as String?;
    _routeName = args?['routeName'] as String?;
    _route = args?['route'] as BusRoute?;
    _reason = (args?['reason'] as StartTimeReason?) ?? StartTimeReason.schedule;
    _carriedScheduledStart = args?['scheduledStart'] as DateTime?;
    _picked = _carriedScheduledStart ?? DateTime.now();
  }

  String get _routeLabel => _route?.displayName ?? _routeName ?? _routeId ?? _directionId;

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _picked,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 1)),
    );
    if (picked == null) return;
    setState(() {
      _picked = DateTime(picked.year, picked.month, picked.day, _picked.hour, _picked.minute);
    });
  }

  Future<void> _confirm() async {
    switch (_reason) {
      case StartTimeReason.schedule:
        // Just carrying a chosen time forward — nothing to submit yet, the GPS
        // screen submits the real POST /api/trips once it has (or gives up on) a fix.
        if (!mounted) return;
        Navigator.pushReplacementNamed(
          context,
          '/driver/trip-start',
          arguments: {
            'busId': _busId,
            'driverId': _driverId,
            'directionId': _directionId,
            'routeId': _routeId,
            'routeName': _routeName,
            'route': _route,
            'scheduledStart': _picked,
          },
        );
        return;

      case StartTimeReason.gpsUnavailable:
        setState(() {
          _busy = true;
          _error = null;
        });
        try {
          final trip = await _api.startTrip(
            busId: _busId,
            directionId: _directionId,
            driverId: _driverId,
            scheduledStart: _carriedScheduledStart,
            startedAt: _picked,
          );
          if (!mounted) return;
          Navigator.pushReplacementNamed(
            context,
            '/driver/on-trip',
            arguments: {
              'busId': _busId,
              'driverId': _driverId,
              'directionId': _directionId,
              'routeId': _routeId,
              'routeName': _routeName,
              'route': _route,
              'existingTrip': trip,
              'gpsWasUnavailable': true,
            },
          );
        } on ApiException catch (e) {
          if (!mounted) return;
          setState(() {
            _error = e.message;
            _busy = false;
          });
        }
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isGps = _reason == StartTimeReason.gpsUnavailable;

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
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Text(_routeLabel, style: theme.textTheme.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                        if (_route?.endpoints != null)
                          Text(
                            '${_route!.endpoints!.$1} → ${_route!.endpoints!.$2}',
                            style: theme.textTheme.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 44),
                ],
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 20),
                      _Banner(
                        icon: isGps ? Icons.location_off_rounded : Icons.event_available_rounded,
                        iconColor: isGps ? AppTheme.crowded : AppTheme.primary,
                        title: isGps ? 'GPS Signal Unavailable' : 'Schedule a Start Time',
                        message: isGps
                            ? "We couldn't detect your location. Please enter the start time manually."
                            : 'Set the time this trip is expected to start — GPS auto-detect runs next.',
                      ),
                      const SizedBox(height: AppTheme.gapSection),
                      SoftCard(
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Bus ID', style: theme.textTheme.titleSmall),
                                  const SizedBox(height: 4),
                                  Text(_busId, style: theme.textTheme.titleLarge),
                                  const SizedBox(height: 14),
                                  Text('Scheduled Start', style: theme.textTheme.titleSmall),
                                  const SizedBox(height: 4),
                                  Text(
                                    _carriedScheduledStart == null
                                        ? '—'
                                        : DateFormat('h:mm a').format(_carriedScheduledStart!),
                                    style: theme.textTheme.titleLarge,
                                  ),
                                ],
                              ),
                            ),
                            const PunjabBusIllustration(),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppTheme.gap),
                      SoftCard(
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text('Actual Start', style: theme.textTheme.titleMedium),
                              ],
                            ),
                            SizedBox(
                              height: 180,
                              child: CupertinoTheme(
                                data: CupertinoThemeData(
                                  brightness: theme.brightness,
                                  textTheme: CupertinoTextThemeData(
                                    dateTimePickerTextStyle: theme.textTheme.headlineMedium,
                                  ),
                                ),
                                child: CupertinoDatePicker(
                                  mode: CupertinoDatePickerMode.time,
                                  initialDateTime: _picked,
                                  use24hFormat: false,
                                  onDateTimeChanged: (value) => setState(() {
                                    _picked = DateTime(_picked.year, _picked.month, _picked.day, value.hour, value.minute);
                                  }),
                                ),
                              ),
                            ),
                            const Divider(height: 1),
                            const SizedBox(height: 12),
                            InkWell(
                              onTap: _pickDate,
                              borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(DateFormat('d MMMM yyyy').format(_picked), style: theme.textTheme.titleMedium),
                                    const SizedBox(width: 8),
                                    Icon(Icons.calendar_month_rounded, size: 20, color: theme.colorScheme.primary),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!, style: const TextStyle(color: AppTheme.crowded, fontWeight: FontWeight.w600)),
                      ],
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
              PillButton(
                label: isGps ? 'CONFIRM TIME' : 'CONFIRM & DETECT GPS',
                icon: Icons.check_rounded,
                loading: _busy,
                onPressed: _busy ? null : _confirm,
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: Text(
                  'CANCEL',
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

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.iconColor, required this.title, required this.message});
  final IconData icon;
  final Color iconColor;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(color: iconColor.withValues(alpha: 0.10), shape: BoxShape.circle),
          child: Icon(icon, color: iconColor, size: 36),
        ),
        const SizedBox(height: 16),
        Text(title, style: theme.textTheme.headlineMedium, textAlign: TextAlign.center),
        const SizedBox(height: 6),
        Text(
          message,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
