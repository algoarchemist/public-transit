import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:setutrack_mobile/passenger/voice/voice_io.dart';
import 'package:setutrack_mobile/passenger/voice/voice_mic_button.dart';

/// Same scripted-recognizer approach as voice_search_service_test.dart's
/// FakeVoiceRecognizer, duplicated here (rather than shared) since the two
/// tests want independently controllable `available` results.
class _FakeRecognizer implements VoiceRecognizer {
  bool available = true;
  bool stopped = false;
  void Function(String text, bool isFinal)? onResult;
  void Function(String message)? onError;

  @override
  Future<bool> initialize() async => available;

  @override
  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    required void Function(String message) onError,
  }) async {
    this.onResult = onResult;
    this.onError = onError;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }
}

void main() {
  testWidgets('tapping the mic starts listening and streams partial + final text', (tester) async {
    final recognizer = _FakeRecognizer();
    final partials = <String>[];
    String? finalText;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VoiceMicButton(
          recognizer: recognizer,
          onPartialResult: partials.add,
          onFinalResult: (t) => finalText = t,
        ),
      ),
    ));

    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();

    // Icon reflects the listening state once initialize() resolves.
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);

    recognizer.onResult?.call('bus st', false);
    await tester.pump();
    expect(partials, ['bus st']);

    recognizer.onResult?.call('bus stop road', true);
    await tester.pump();
    expect(finalText, 'bus stop road');
    // A final result ends the listening session on its own.
    expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
  });

  testWidgets('tapping again while listening stops the recognizer', (tester) async {
    final recognizer = _FakeRecognizer();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VoiceMicButton(
          recognizer: recognizer,
          onPartialResult: (_) {},
          onFinalResult: (_) {},
        ),
      ),
    ));

    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);

    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();

    expect(recognizer.stopped, isTrue);
    expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
  });

  testWidgets('unavailable recognizer surfaces onError and stays idle', (tester) async {
    final recognizer = _FakeRecognizer()..available = false;
    String? error;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VoiceMicButton(
          recognizer: recognizer,
          onPartialResult: (_) {},
          onFinalResult: (_) {},
          onError: (m) => error = m,
        ),
      ),
    ));

    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();

    expect(error, "Voice input isn't available on this device.");
    expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
  });
}
