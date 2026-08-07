import 'package:flutter/material.dart';

import '../../core/app_scope.dart';
import '../../theme/app_theme.dart';
import '../../ui/components.dart';
import 'voice_search_service.dart';

/// Voice search: "bus 42 to Central Station" -> resolved route+stop via
/// `GET /api/search` (search.controller.ts), spoken back as the result.
///
/// Listening starts automatically on open. A text field is also offered — same
/// [VoiceSearchService.handleTranscript] pipeline, so it works without a mic or
/// microphone permission (an emulator without audio input, a quiet demo, or
/// manual QA), and it is how the missing-entity clarifying prompts can be
/// answered by typing instead of speaking.
class VoiceSearchScreen extends StatefulWidget {
  const VoiceSearchScreen({super.key});

  @override
  State<VoiceSearchScreen> createState() => _VoiceSearchScreenState();
}

class _VoiceSearchScreenState extends State<VoiceSearchScreen> {
  late final VoiceSearchService _service;
  final _typedController = TextEditingController();
  VoiceSearchState _state = const VoiceSearchState(stage: VoiceSearchStage.idle);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _service = VoiceSearchService(apiClient: ApiScope.of(context));
    _service.states.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    _service.start();
  }

  @override
  void dispose() {
    _service.dispose();
    _typedController.dispose();
    super.dispose();
  }

  void _submitTyped() {
    final text = _typedController.text.trim();
    if (text.isEmpty) return;
    _typedController.clear();
    _service.handleTranscript(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final listening = _state.stage == VoiceSearchStage.listening ||
        _state.stage == VoiceSearchStage.awaitingBus ||
        _state.stage == VoiceSearchStage.awaitingLocation;

    return AppScaffold(
      title: 'Voice search',
      leading: CircleIconButton(
        icon: Icons.arrow_back_rounded,
        tooltip: 'Back',
        onPressed: () => Navigator.of(context).pop(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: AppTheme.gap),
          Center(
            child: Column(
              children: [
                _MicIndicator(listening: listening),
                const SizedBox(height: 16),
                Text(
                  _statusLine(_state),
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                if (_state.transcript.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text('"${_state.transcript}"',
                      style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppTheme.gapSection),
          if (_state.stage == VoiceSearchStage.result) _ResultCard(state: _state),
          if (_state.stage == VoiceSearchStage.error)
            StateCard.error(message: _state.errorMessage ?? 'Something went wrong.', onRetry: () => _service.start()),
          const Spacer(),
          SectionHeader('Or type it', padTop: false),
          Row(
            children: [
              Expanded(
                child: SoftTextField(
                  controller: _typedController,
                  hint: 'e.g. "bus 42 to Central Station"',
                  icon: Icons.keyboard_rounded,
                  onSubmitted: (_) => _submitTyped(),
                ),
              ),
              const SizedBox(width: 8),
              CircleIconButton(icon: Icons.send_rounded, filled: true, tooltip: 'Send', onPressed: _submitTyped),
            ],
          ),
          const SizedBox(height: 8),
          PillButton(
            label: listening ? 'Listening…' : 'Try again',
            icon: Icons.mic_rounded,
            loading: listening,
            onPressed: listening ? null : () => _service.start(),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  String _statusLine(VoiceSearchState s) => switch (s.stage) {
        VoiceSearchStage.idle => 'Starting…',
        VoiceSearchStage.listening => 'Say a bus and where you\'re headed',
        VoiceSearchStage.awaitingBus => s.spokenPrompt ?? 'Which bus are you looking for?',
        VoiceSearchStage.awaitingLocation => s.spokenPrompt ?? 'Where are you headed?',
        VoiceSearchStage.searching => 'Searching…',
        VoiceSearchStage.result => 'Here\'s what I found',
        VoiceSearchStage.error => 'I need another try',
      };
}

class _MicIndicator extends StatelessWidget {
  const _MicIndicator({required this.listening});
  final bool listening;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: listening ? scheme.primary : scheme.primaryContainer,
      ),
      child: Icon(
        Icons.mic_rounded,
        size: 40,
        color: listening ? scheme.onPrimary : scheme.onPrimaryContainer,
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.state});
  final VoiceSearchState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = state.result;
    if (result == null) return const SizedBox.shrink();

    if (!result.matched) {
      return StateCard.empty(
        title: state.spokenPrompt ?? 'No match found',
        icon: Icons.search_off_rounded,
      );
    }

    final bus = result.bus!;
    final stop = result.stop!;

    return SoftCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RouteBadge(label: bus.label, large: true),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(bus.routeName ?? 'Bus ${bus.label}', style: theme.textTheme.titleMedium),
                const SizedBox(height: 6),
                MetaRow(icon: Icons.location_on_outlined, text: stop.name),
                const SizedBox(height: 10),
                Text(state.spokenPrompt ?? '', style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
