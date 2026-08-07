import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Speech-to-text, behind an interface so [VoiceSearchService] can be driven by
/// a scripted fake in tests instead of a real microphone.
abstract class VoiceRecognizer {
  /// Requests mic permission / engine init. False means voice input can't be
  /// offered on this device at all (no mic, permission denied, unsupported).
  Future<bool> initialize();

  /// Starts one listening pass. `onResult` fires repeatedly with partial text
  /// and once more with `isFinal: true`; `onError` fires for engine errors
  /// (silence timeout, no match, audio error) instead of throwing.
  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    required void Function(String message) onError,
  });

  Future<void> stop();
}

/// Text-to-speech, behind the same kind of interface for the same reason.
abstract class VoiceSpeaker {
  Future<void> speak(String text);
  Future<void> stop();
}

/// [VoiceRecognizer] backed by the `speech_to_text` plugin.
class PluginVoiceRecognizer implements VoiceRecognizer {
  PluginVoiceRecognizer() : _stt = SpeechToText();

  final SpeechToText _stt;
  bool _initialized = false;

  /// The plugin registers its error handler once, at `initialize()` time, not
  /// per `listen()` call — so the most recent `listen()`'s handler is stashed
  /// here and forwarded to from a single persistent callback.
  void Function(String message)? _onError;

  @override
  Future<bool> initialize() async {
    if (_initialized) return true;
    _initialized = await _stt.initialize(onError: (error) => _onError?.call(error.errorMsg));
    return _initialized;
  }

  @override
  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    required void Function(String message) onError,
  }) async {
    _onError = onError;
    if (!_initialized && !await initialize()) {
      onError("Voice input isn't available on this device.");
      return;
    }
    await _stt.listen(
      onResult: (SpeechRecognitionResult result) => onResult(result.recognizedWords, result.finalResult),
      listenFor: const Duration(seconds: 12),
      pauseFor: const Duration(seconds: 3),
      partialResults: true,
      cancelOnError: true,
    );
  }

  @override
  Future<void> stop() => _stt.stop();
}

/// [VoiceSpeaker] backed by the `flutter_tts` plugin.
class PluginVoiceSpeaker implements VoiceSpeaker {
  PluginVoiceSpeaker() : _tts = FlutterTts() {
    _tts.setLanguage('en-US');
    _tts.setSpeechRate(0.48);
  }

  final FlutterTts _tts;

  @override
  Future<void> speak(String text) async {
    await _tts.stop();
    await _tts.speak(text);
  }

  @override
  Future<void> stop() => _tts.stop();
}
