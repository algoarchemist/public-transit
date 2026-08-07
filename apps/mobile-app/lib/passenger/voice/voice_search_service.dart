import 'dart:async';

import '../../core/api_client.dart';
import '../../core/models.dart';
import 'entity_extractor.dart';
import 'voice_io.dart';

enum VoiceSearchStage {
  idle,
  listening,
  awaitingBus,
  awaitingLocation,
  searching,
  result,
  error,
}

/// A snapshot of the voice search loop, for the UI to render and for tests to
/// assert on. `spokenPrompt` is whatever was just (or is about to be) spoken —
/// the UI shows it as a caption under the transcript.
class VoiceSearchState {
  const VoiceSearchState({
    required this.stage,
    this.transcript = '',
    this.spokenPrompt,
    this.result,
    this.errorMessage,
  });

  final VoiceSearchStage stage;
  final String transcript;
  final String? spokenPrompt;
  final SearchResult? result;
  final String? errorMessage;
}

/// Drives Listen -> Extract -> Search -> Speak.
///
/// [recognizer] and [speaker] default to the real plugin-backed implementations
/// but can be swapped for scripted fakes, which is what lets [handleTranscript]
/// (and therefore the whole loop below the microphone) run in a plain unit test
/// with no device, mic, or plugin channel involved.
class VoiceSearchService {
  VoiceSearchService({required this.apiClient, VoiceRecognizer? recognizer, VoiceSpeaker? speaker})
      : recognizer = recognizer ?? PluginVoiceRecognizer(),
        speaker = speaker ?? PluginVoiceSpeaker();

  final ApiClient apiClient;
  final VoiceRecognizer recognizer;
  final VoiceSpeaker speaker;

  final _stateController = StreamController<VoiceSearchState>.broadcast();
  Stream<VoiceSearchState> get states => _stateController.stream;

  String? _bus;
  String? _location;
  VoiceSearchStage _awaiting = VoiceSearchStage.idle;

  /// Clears any partially-collected entities and starts a fresh listening pass.
  Future<void> start() async {
    _bus = null;
    _location = null;
    _awaiting = VoiceSearchStage.idle;
    await _listenForStage(VoiceSearchStage.listening);
  }

  Future<void> stopListening() => recognizer.stop();

  void dispose() {
    recognizer.stop();
    _stateController.close();
  }

  Future<void> _listenForStage(VoiceSearchStage stage) async {
    _emit(VoiceSearchState(stage: stage));
    final available = await recognizer.initialize();
    if (!available) {
      await _fail("Voice input isn't available on this device.");
      return;
    }
    await recognizer.listen(
      onResult: (text, isFinal) {
        _emit(VoiceSearchState(stage: stage, transcript: text));
        if (isFinal && text.trim().isNotEmpty) _onFinalTranscript(text, stage);
      },
      onError: (message) => _fail("Sorry, I didn't catch that. ${_retryHint(stage)}"),
    );
  }

  void _onFinalTranscript(String transcript, VoiceSearchStage stage) {
    switch (stage) {
      case VoiceSearchStage.awaitingBus:
        _bus = EntityExtractor.extractBusOnly(transcript) ?? transcript.trim().toUpperCase();
        break;
      case VoiceSearchStage.awaitingLocation:
        _location = EntityExtractor.extractLocationOnly(transcript) ?? transcript.trim();
        break;
      default:
        final entities = EntityExtractor.extract(transcript);
        _bus = entities.busIdentifier;
        _location = entities.targetLocation;
    }
    unawaited(_advance());
  }

  /// Exposed directly (not just via the recognizer callback) so a manual-entry
  /// fallback UI, and tests, can drive the loop without a microphone.
  Future<void> handleTranscript(String transcript) async {
    _onFinalTranscript(transcript, _awaiting == VoiceSearchStage.idle ? VoiceSearchStage.listening : _awaiting);
  }

  Future<void> _advance() async {
    if (_bus == null && _location == null) {
      await _fail("I didn't catch a bus number or a destination. Try something like \"bus 42 to Central Station\".");
      return;
    }
    if (_bus == null) {
      await _prompt(VoiceSearchStage.awaitingBus, 'Which bus are you looking for?');
      return;
    }
    if (_location == null) {
      await _prompt(VoiceSearchStage.awaitingLocation, 'Where are you headed?');
      return;
    }
    await _search();
  }

  Future<void> _prompt(VoiceSearchStage stage, String question) async {
    _awaiting = stage;
    _emit(VoiceSearchState(stage: stage, spokenPrompt: question));
    await speaker.speak(question);
    await _listenForStage(stage);
  }

  Future<void> _search() async {
    _emit(const VoiceSearchState(stage: VoiceSearchStage.searching));
    try {
      final result = await apiClient.search(bus: _bus!, location: _location!);
      final answer = _formatAnswer(result);
      _emit(VoiceSearchState(stage: VoiceSearchStage.result, result: result, spokenPrompt: answer));
      await speaker.speak(answer);
    } on ApiException catch (e) {
      await _fail("Something went wrong reaching search. ${e.message}");
    }
  }

  String _formatAnswer(SearchResult result) {
    if (!result.matched) {
      if (result.reason == 'bus_not_found') {
        return "I couldn't find a bus matching \"$_bus\".";
      }
      final busLabel = result.bus?.label ?? _bus;
      return "I found bus $busLabel, but no stop matching \"$_location\" on that route.";
    }

    final busLabel = result.bus!.label;
    final stopName = result.stop!.name;
    StopEta? eta;
    for (final s in result.upcomingStops) {
      if (s.stopId == result.stop!.osmNodeId) {
        eta = s;
        break;
      }
    }
    if (eta?.etaSeconds != null) {
      return 'Bus $busLabel to $stopName will arrive in ${formatEta(eta!.etaSeconds)}.';
    }
    return "Bus $busLabel is on its way to $stopName. Live arrival time isn't available for this stop yet.";
  }

  String _retryHint(VoiceSearchStage stage) => switch (stage) {
        VoiceSearchStage.awaitingBus => 'Which bus are you looking for?',
        VoiceSearchStage.awaitingLocation => 'Where are you headed?',
        _ => 'Please try again.',
      };

  Future<void> _fail(String message) async {
    _emit(VoiceSearchState(stage: VoiceSearchStage.error, errorMessage: message));
    await speaker.speak(message);
  }

  void _emit(VoiceSearchState state) {
    if (!_stateController.isClosed) _stateController.add(state);
  }
}
