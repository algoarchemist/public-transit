import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_client.dart';
import '../core/app_scope.dart';
import '../core/location_service.dart';
import '../core/models.dart';
import '../theme/app_theme.dart';
import '../ui/components.dart';
import 'live_map_screen.dart';
import 'route_number_picker_screen.dart';
import 'stop_picker_screen.dart';

/// Passenger dashboard's front page — reference design's search/find-routes
/// screen. Origin/destination picked from real stops (stop_picker_screen.dart),
/// "Find Routes" runs a real search (`GET /api/routes/journeys`, real distance,
/// real duration where every covered segment has an OSRM baseline), and results
/// are tagged "Fastest" by real computed duration — never "Cheapest": no fare
/// exists anywhere in this system (ticketing is descoped, docs §10), so that tag
/// would be a number with nothing behind it. Same reason there's no bus-type
/// ("AC Volvo") or frequency ("every 15 mins") line — neither is real data this
/// system has.
class RouteSearchScreen extends StatefulWidget {
  const RouteSearchScreen({super.key, this.bottomInset = 0});
  final double bottomInset;

  @override
  State<RouteSearchScreen> createState() => _RouteSearchScreenState();
}

class _RecentSearch {
  final SearchStop from;
  final SearchStop to;
  final DateTime at;
  const _RecentSearch({required this.from, required this.to, required this.at});
}

class _RouteSearchScreenState extends State<RouteSearchScreen> {
  static const _recentKey = 'setutrack_recent_route_searches';
  static const _maxRecent = 5;

  SearchStop? _from;
  SearchStop? _to;
  TimeOfDay? _departAt;
  DateTime _date = DateTime.now();

  List<_RecentSearch> _recent = [];
  bool _searching = false;
  String? _error;
  List<JourneyOption>? _results;

  bool _originInitialized = false;
  bool _originLoading = false;
  bool _locationIsReal = true;
  String? _originError;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_originInitialized) return;
    _originInitialized = true;
    _loadOrigin();
  }

  /// Resolves the passenger's boarding stop from their GPS fix instead of
  /// making them pick one — the reference design's "Where from?" field is
  /// gone; this is what fills its role. Widens the search radius once before
  /// giving up, since 1.5km can legitimately miss every stop on a fallback
  /// fix (city centre, not necessarily near dense stop coverage).
  Future<void> _loadOrigin() async {
    if (_originLoading) return;
    final api = ApiScope.of(context);
    setState(() {
      _originLoading = true;
      _originError = null;
    });
    final fix = await LocationService.currentOrFallback();
    if (!mounted) return;
    _locationIsReal = fix.isReal;
    try {
      var nearby = await api.nearbyStops(lat: fix.point.latitude, lon: fix.point.longitude, radiusM: 1500, limit: 1);
      if (nearby.isEmpty) {
        nearby = await api.nearbyStops(lat: fix.point.latitude, lon: fix.point.longitude, radiusM: 5000, limit: 1);
      }
      if (!mounted) return;
      if (nearby.isEmpty) {
        setState(() {
          _originLoading = false;
          _originError = 'No stops found near you';
        });
        return;
      }
      final nearest = nearby.first;
      setState(() {
        _from = SearchStop(osmNodeId: nearest.osmNodeId, name: nearest.name, lat: nearest.lat, lon: nearest.lon, routes: nearest.routes);
        _originLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _originLoading = false;
        _originError = e.message;
      });
    }
  }

  Future<void> _loadRecent() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_recentKey) ?? const [];
    final parsed = raw
        .map((s) {
          try {
            final j = jsonDecode(s) as Map<String, dynamic>;
            return _RecentSearch(
              from: SearchStop(osmNodeId: j['fromId'] as int, name: j['fromName'] as String?, lat: 0, lon: 0, routes: const []),
              to: SearchStop(osmNodeId: j['toId'] as int, name: j['toName'] as String?, lat: 0, lon: 0, routes: const []),
              at: DateTime.fromMillisecondsSinceEpoch(j['atMs'] as int),
            );
          } catch (_) {
            return null;
          }
        })
        .whereType<_RecentSearch>()
        .toList();
    if (mounted) setState(() => _recent = parsed);
  }

  Future<void> _saveRecent(SearchStop from, SearchStop to) async {
    final prefs = await SharedPreferences.getInstance();
    final next = [
      _RecentSearch(from: from, to: to, at: DateTime.now()),
      ..._recent.where((r) => !(r.from.osmNodeId == from.osmNodeId && r.to.osmNodeId == to.osmNodeId)),
    ].take(_maxRecent).toList();
    setState(() => _recent = next);
    await prefs.setStringList(
      _recentKey,
      next
          .map((r) => jsonEncode({
                'fromId': r.from.osmNodeId,
                'fromName': r.from.name,
                'toId': r.to.osmNodeId,
                'toName': r.to.name,
                'atMs': r.at.millisecondsSinceEpoch,
              }))
          .toList(),
    );
  }

  String _relativeTime(DateTime at) {
    final diff = DateTime.now().difference(at);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes} min ago';
    if (diff.inDays < 1) return '${diff.inHours} hour${diff.inHours == 1 ? '' : 's'} ago';
    if (diff.inDays == 1) return 'Yesterday';
    return '${diff.inDays} days ago';
  }

  Future<void> _pickDestination() async {
    final picked = await Navigator.push<SearchStop>(
      context,
      MaterialPageRoute(
        builder: (_) => StopPickerScreen(title: 'Where to?', exclude: _from),
      ),
    );
    if (picked == null) return;
    setState(() => _to = picked);
  }

  Future<void> _pickDepartTime() async {
    final picked = await showTimePicker(context: context, initialTime: _departAt ?? TimeOfDay.now());
    if (picked != null) setState(() => _departAt = picked);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: now,
      lastDate: now.add(const Duration(days: 14)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _findRoutes() async {
    final from = _from;
    final to = _to;
    if (from == null) {
      setState(() => _error = _originError ?? 'Still finding your location — try again in a moment');
      return;
    }
    if (to == null) {
      setState(() => _error = 'Pick where you\'re headed');
      return;
    }
    if (from.osmNodeId == to.osmNodeId) {
      setState(() => _error = 'Departure and arrival can\'t be the same stop');
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await ApiScope.of(context).journeys(fromStopId: from.osmNodeId, toStopId: to.osmNodeId);
      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
      });
      await _saveRecent(from, to);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _searching = false;
      });
    }
  }

  Future<void> _searchRecent(_RecentSearch r) async {
    setState(() {
      _from = r.from;
      _to = r.to;
    });
    await _findRoutes();
  }

  /// "Your current location", not the resolved stop's own name/id — that stop is
  /// an internal detail for computing the route, and plenty of real stops in this
  /// region's OSM data have no name tag at all (SearchStop.displayName's "Stop
  /// <id>" fallback is meant for telling entries apart in a list; showing that
  /// same raw id back to the passenger as their OWN location reads as broken,
  /// not honest). Only surface the resolved name when it's real.
  String get _originLabel {
    final from = _from;
    if (from == null) return 'Current location';
    final name = from.name;
    return (name != null && name.isNotEmpty) ? 'Near $name' : 'Your current location';
  }

  bool get _isCustomTime => _departAt != null || !_isToday;
  bool get _isToday {
    final now = DateTime.now();
    return _date.year == now.year && _date.month == now.month && _date.day == now.day;
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'SetuTrack',
      child: SingleChildScrollView(
        padding: EdgeInsets.only(bottom: widget.bottomInset + 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 4),
            SoftCard(
              child: Column(
                children: [
                  // No "Where from?" field to tap — the boarding stop is resolved
                  // from the passenger's GPS fix (_loadOrigin), same "ask, don't
                  // demand" location handling as location_service.dart. Tapping
                  // this row re-resolves it, which doubles as the retry action
                  // when _originError is set.
                  _StopField(
                    icon: Icons.my_location_rounded,
                    iconColor: AppTheme.liveGreen,
                    label: _originLoading ? 'Finding your location…' : (_originError ?? _originLabel),
                    filled: _from != null,
                    onTap: _loadOrigin,
                  ),
                  if (!_originLoading && _from != null && !_locationIsReal) ...[
                    const SizedBox(height: 8),
                    const MetaRow(
                      icon: Icons.info_outline_rounded,
                      text: "Using the city centre — enable location for a nearer boarding stop",
                    ),
                  ],
                  const SizedBox(height: 10),
                  _StopField(
                    icon: Icons.location_on_rounded,
                    iconColor: AppTheme.crowded,
                    label: _to?.displayName ?? 'Where to?',
                    filled: _to != null,
                    onTap: _pickDestination,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _Chip(
                          icon: Icons.schedule_rounded,
                          label: _departAt == null ? 'Depart Now' : _departAt!.format(context),
                          onTap: _pickDepartTime,
                          onClear: _departAt == null ? null : () => setState(() => _departAt = null),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _Chip(
                          icon: Icons.calendar_month_rounded,
                          label: _isToday ? 'Today' : DateFormat('d MMM').format(_date),
                          onTap: _pickDate,
                        ),
                      ),
                    ],
                  ),
                  if (_isCustomTime) ...[
                    const SizedBox(height: 10),
                    const MetaRow(
                      icon: Icons.info_outline_rounded,
                      text: "Showing typical travel time — live timetables aren't available yet",
                    ),
                  ],
                  const SizedBox(height: 16),
                  PillButton(
                    label: 'Find Routes',
                    icon: Icons.search_rounded,
                    loading: _searching,
                    onPressed: _searching ? null : _findRoutes,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!, style: const TextStyle(color: AppTheme.crowded, fontWeight: FontWeight.w600)),
                  ],
                ],
              ),
            ),
            if (_recent.isNotEmpty) ...[
              const SectionHeader('Recent Searches'),
              SoftCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (var i = 0; i < _recent.length; i++) ...[
                      _RecentRow(search: _recent[i], relativeTime: _relativeTime(_recent[i].at), onTap: () => _searchRecent(_recent[i])),
                      if (i != _recent.length - 1) const Divider(height: 1, indent: 18, endIndent: 18),
                    ],
                  ],
                ),
              ),
            ],
            const SectionHeader('Suggested Routes'),
            if (_results == null)
              StateCard.empty(
                title: 'Search for a route',
                message: 'Pick a departure and arrival stop above to see real route matches.',
                icon: Icons.route_outlined,
              )
            else if (_results!.isEmpty)
              StateCard.empty(
                title: 'No direct route found',
                message: 'No single route connects these two stops yet in this city.',
                icon: Icons.alt_route_rounded,
              )
            else
              Column(
                children: [
                  for (var i = 0; i < _results!.length; i++) ...[
                    _JourneyCard(journey: _results![i], isFastest: i == 0 && _results![i].durationSec != null),
                    if (i != _results!.length - 1) const SizedBox(height: 10),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _StopField extends StatelessWidget {
  const _StopField({required this.icon, required this.iconColor, required this.label, required this.filled, required this.onTap});
  final IconData icon;
  final Color iconColor;
  final String label;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusField),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.cardNestedDark : AppTheme.cardNestedLight,
          borderRadius: BorderRadius.circular(AppTheme.radiusField),
        ),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(color: iconColor.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: Icon(icon, size: 15, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: filled
                    ? theme.textTheme.bodyLarge
                    : theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, required this.onTap, this.onClear});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusPill),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppTheme.radiusPill),
          border: Border.all(color: isDark ? AppTheme.borderDark : AppTheme.borderLight),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 7),
            Flexible(
              child: Text(label,
                  style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            if (onClear != null) ...[
              const SizedBox(width: 4),
              GestureDetector(
                onTap: onClear,
                child: Icon(Icons.close_rounded, size: 15, color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.search, required this.relativeTime, required this.onTap});
  final _RecentSearch search;
  final String relativeTime;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: theme.colorScheme.primaryContainer, shape: BoxShape.circle),
              child: Icon(Icons.history_rounded, size: 18, color: theme.colorScheme.onPrimaryContainer),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(child: Text(search.from.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Icon(Icons.arrow_forward_rounded, size: 14, color: theme.colorScheme.onSurfaceVariant),
                      ),
                      Flexible(child: Text(search.to.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(relativeTime, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _JourneyCard extends StatelessWidget {
  const _JourneyCard({required this.journey, required this.isFastest});
  final JourneyOption journey;
  final bool isFastest;

  /// Same live map + ETA + next-3-stops view "Find a route by number" already
  /// builds (live_map_screen.dart's RouteFleetView) — a suggested journey is
  /// just a different way of arriving at "show me this route's real buses"
  /// than picking a number out of a list.
  void _openFleetView(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RouteFleetView(
          routeNumber: RouteNumber(
            routeId: journey.routeId ?? journey.directionId,
            directionIds: [journey.directionId],
            sampleName: journey.displayName,
          ),
          onBack: () => Navigator.pop(context),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SoftCard(
      onTap: () => _openFleetView(context),
      border: isFastest ? Border(left: BorderSide(color: theme.colorScheme.primary, width: 3)) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RouteBadge(label: journey.routeId ?? journey.directionId),
              const SizedBox(width: 10),
              Expanded(
                child: Text(journey.displayName, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              if (isFastest) ...[
                StatusPill(label: 'Fastest', color: theme.colorScheme.primary, icon: Icons.bolt_rounded, compact: true),
                const SizedBox(width: 6),
              ],
              Icon(Icons.chevron_right_rounded, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            journey.durationLabel,
            style: theme.textTheme.headlineMedium?.copyWith(color: journey.durationSec == null ? theme.colorScheme.onSurfaceVariant : null),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              MetaRow(icon: Icons.route_outlined, text: journey.distanceLabel),
              const SizedBox(width: 14),
              MetaRow(icon: Icons.pin_drop_outlined, text: '${journey.stopsBetween} stops'),
            ],
          ),
        ],
      ),
    );
  }
}
