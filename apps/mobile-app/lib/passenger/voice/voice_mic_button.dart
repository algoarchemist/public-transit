import 'dart:async';

import 'package:flutter/material.dart';

import 'voice_io.dart';

/// Small mic button that drives a [VoiceRecognizer] directly and streams the
/// spoken words back to the caller as plain text — no bus/location entity
/// extraction, no spoken response. That two-slot conversational flow lives in
/// [VoiceSearchService]/voice_search_screen.dart; this is the lighter-weight
/// sibling for "speak instead of type" on an ordinary search field, e.g. the
/// stop search box on stop_picker_screen.dart.
///
/// [onPartialResult] fires as words are recognized (so the field updates live,
/// same feel as typing); [onFinalResult] fires once more when the recognizer
/// settles on a final transcript.
class VoiceMicButton extends StatefulWidget {
  const VoiceMicButton({
    super.key,
    required this.onPartialResult,
    required this.onFinalResult,
    this.onError,
    this.recognizer,
  });

  final ValueChanged<String> onPartialResult;
  final ValueChanged<String> onFinalResult;
  final ValueChanged<String>? onError;

  /// Overridable for tests; defaults to the real `speech_to_text`-backed one.
  final VoiceRecognizer? recognizer;

  @override
  State<VoiceMicButton> createState() => _VoiceMicButtonState();
}

class _VoiceMicButtonState extends State<VoiceMicButton> {
  late final VoiceRecognizer _recognizer = widget.recognizer ?? PluginVoiceRecognizer();
  bool _listening = false;
  bool _starting = false;

  @override
  void dispose() {
    if (_listening) unawaited(_recognizer.stop());
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_listening) {
      await _recognizer.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    if (_starting) return;
    _starting = true;
    try {
      final available = await _recognizer.initialize();
      if (!mounted) return;
      if (!available) {
        widget.onError?.call("Voice input isn't available on this device.");
        return;
      }
      setState(() => _listening = true);
      await _recognizer.listen(
        onResult: (text, isFinal) {
          if (!mounted) return;
          if (isFinal) {
            setState(() => _listening = false);
            if (text.trim().isNotEmpty) widget.onFinalResult(text.trim());
          } else if (text.isNotEmpty) {
            widget.onPartialResult(text);
          }
        },
        onError: (message) {
          if (!mounted) return;
          setState(() => _listening = false);
          widget.onError?.call(message);
        },
      );
    } finally {
      _starting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      icon: Icon(_listening ? Icons.mic_rounded : Icons.mic_none_rounded),
      color: _listening ? scheme.primary : scheme.onSurfaceVariant,
      tooltip: _listening ? 'Listening… tap to stop' : 'Speak instead of typing',
      splashRadius: 20,
      visualDensity: VisualDensity.compact,
      onPressed: _toggle,
    );
  }
}
