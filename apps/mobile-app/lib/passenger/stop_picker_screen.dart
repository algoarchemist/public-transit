import 'package:flutter/material.dart';

import '../core/app_scope.dart';
import '../core/models.dart';
import '../theme/app_theme.dart';
import '../ui/components.dart';
import 'voice/voice_mic_button.dart';

/// Full-screen searchable list of every real stop in the city
/// (`GET /api/stops`), used for both the origin and destination fields on
/// route_search_screen.dart. Returns the picked [SearchStop] via
/// `Navigator.pop(context, stop)` — a plain result-returning picker, matching
/// the pattern the rest of this app uses for single-choice pickers.
class StopPickerScreen extends StatefulWidget {
  const StopPickerScreen({super.key, required this.title, this.exclude});

  final String title;

  /// A stop already picked for the other field — shown but visually muted
  /// rather than hidden, so picking the same stop twice is merely pointless,
  /// not confusingly impossible.
  final SearchStop? exclude;

  @override
  State<StopPickerScreen> createState() => _StopPickerScreenState();
}

class _StopPickerScreenState extends State<StopPickerScreen> {
  bool _initialized = false;
  Future<List<SearchStop>>? _stopsFuture;
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _stopsFuture = ApiScope.of(context).allStops();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Mirrors what typing into [_searchController] does — same field, same
  /// filter — just fed from [VoiceMicButton] instead of the keyboard. Cursor
  /// is pinned to the end so a mid-utterance partial result doesn't leave the
  /// caret (and therefore the next typed character) stranded mid-string.
  void _setQueryFromVoice(String text) {
    _searchController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() => _query = text);
  }

  void _showVoiceError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppScaffold(
      title: widget.title,
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
            hint: 'Search stop name or route number',
            icon: Icons.search_rounded,
            autofocus: true,
            onChanged: (v) => setState(() => _query = v),
            suffix: VoiceMicButton(
              onPartialResult: _setQueryFromVoice,
              onFinalResult: _setQueryFromVoice,
              onError: _showVoiceError,
            ),
          ),
          const SizedBox(height: AppTheme.gap),
          Expanded(
            child: FutureBuilder<List<SearchStop>>(
              future: _stopsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return Center(child: StateCard.loading(title: 'Loading stops'));
                }
                if (snapshot.hasError) {
                  return Center(
                    child: StateCard.error(
                      message: snapshot.error.toString(),
                      onRetry: () => setState(() {
                        _stopsFuture = ApiScope.of(context).allStops(forceRefresh: true);
                      }),
                    ),
                  );
                }
                final stops = (snapshot.data ?? const []).where((s) => s.matches(_query)).toList();
                if (stops.isEmpty) {
                  return Center(child: StateCard.empty(title: 'No stops match', icon: Icons.search_off_rounded));
                }
                return ListView.separated(
                  itemCount: stops.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final stop = stops[i];
                    final isExcluded = stop.osmNodeId == widget.exclude?.osmNodeId;
                    return Opacity(
                      opacity: isExcluded ? 0.45 : 1,
                      child: SoftCard(
                        onTap: () => Navigator.pop(context, stop),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(Icons.location_on_rounded, size: 18, color: theme.colorScheme.onPrimaryContainer),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(stop.displayName,
                                      style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  if (stop.routes.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 6,
                                      children: stop.routes
                                          .take(4)
                                          .map((r) => RouteBadge(label: r.routeId ?? r.directionId))
                                          .toList(),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
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
