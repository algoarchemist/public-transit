import 'package:flutter/material.dart';

/// "Amigo" voice/chat assistant: STT (Whisper/Bhashini) -> intent -> function-calling
/// into the booking API -> TTS confirmation. Punjabi/Hindi/English.
/// See solution doc section 4.1.
class VoiceAssistantScreen extends StatelessWidget {
  const VoiceAssistantScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ask Amigo')),
      body: const Center(child: Text('Voice assistant — TODO')),
    );
  }
}
