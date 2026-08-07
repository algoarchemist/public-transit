import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:setutrack_mobile/core/api_client.dart';
import 'package:setutrack_mobile/passenger/voice/voice_io.dart';
import 'package:setutrack_mobile/passenger/voice/voice_search_service.dart';

/// Scripted [VoiceRecognizer]: the test drives it directly via [respond]/[fail]
/// instead of a real microphone, which is exactly what makes the Listen ->
/// Extract -> Search -> Speak loop runnable in a plain unit test.
class FakeVoiceRecognizer implements VoiceRecognizer {
  void Function(String text, bool isFinal)? _onResult;
  void Function(String message)? _onError;
  bool available = true;
  int listenCalls = 0;

  @override
  Future<bool> initialize() async => available;

  @override
  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    required void Function(String message) onError,
  }) async {
    listenCalls++;
    _onResult = onResult;
    _onError = onError;
  }

  @override
  Future<void> stop() async {}

  void respond(String text) => _onResult?.call(text, true);
  void fail(String message) => _onError?.call(message);
}

class FakeVoiceSpeaker implements VoiceSpeaker {
  final List<String> spoken = [];

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async {}
}

/// Pure microtask/fake-IO chains settle within a handful of event-loop turns;
/// a short real delay is simpler and more robust here than counting `await`s
/// through the service's internal state machine.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

ApiClient _apiWith(http.Response Function(http.Request) respond) {
  return ApiClient(client: MockClient((request) async => respond(request)), baseUrl: 'http://test.local');
}

void main() {
  group('VoiceSearchService', () {
    test('a single utterance with both entities resolves and speaks a formatted result', () async {
      final recognizer = FakeVoiceRecognizer();
      final speaker = FakeVoiceSpeaker();
      final api = _apiWith((request) {
        expect(request.url.path, '/search');
        expect(request.url.queryParameters['bus'], '1');
        expect(request.url.queryParameters['location'], 'Chandigarh Railway Station');
        return http.Response(
          jsonEncode({
            'matched': true,
            'bus': {'directionId': 'r16450017', 'routeId': '1', 'ref': '1', 'routeName': 'Bus 1: A => B'},
            'stop': {
              'osmNodeId': 2914440106,
              'name': 'Chandigarh Railway Station',
              'lat': 30.6,
              'lon': 76.8,
              'sequence': 1,
            },
            'upcomingStops': [],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final service = VoiceSearchService(apiClient: api, recognizer: recognizer, speaker: speaker);
      final statesFuture = expectLater(
        service.states,
        emitsThrough(predicate<VoiceSearchState>((s) => s.stage == VoiceSearchStage.result)),
      );

      await service.start();
      recognizer.respond('bus 1 to Chandigarh Railway Station');
      await statesFuture;

      expect(speaker.spoken, isNotEmpty);
      expect(
        speaker.spoken.last,
        "Bus 1 is on its way to Chandigarh Railway Station. Live arrival time isn't available for this stop yet.",
      );
    });

    test('a missing location triggers a spoken clarifying prompt, then completes on the follow-up', () async {
      final recognizer = FakeVoiceRecognizer();
      final speaker = FakeVoiceSpeaker();
      final api = _apiWith((request) {
        expect(request.url.queryParameters['bus'], '42');
        expect(request.url.queryParameters['location'], 'Central Station');
        return http.Response(jsonEncode({'matched': false, 'reason': 'bus_not_found'}), 200,
            headers: {'content-type': 'application/json'});
      });

      final service = VoiceSearchService(apiClient: api, recognizer: recognizer, speaker: speaker);
      final awaitingLocation = expectLater(
        service.states,
        emitsThrough(predicate<VoiceSearchState>((s) => s.stage == VoiceSearchStage.awaitingLocation)),
      );

      await service.start();
      recognizer.respond('bus 42');
      await awaitingLocation;
      await settle();

      expect(speaker.spoken.last, 'Where are you headed?');
      expect(recognizer.listenCalls, 2, reason: 'must re-listen for the follow-up answer');

      final result = expectLater(
        service.states,
        emitsThrough(predicate<VoiceSearchState>((s) => s.stage == VoiceSearchStage.result)),
      );
      recognizer.respond('Central Station');
      await result;

      expect(speaker.spoken.last, 'I couldn\'t find a bus matching "42".');
    });

    test('an unrecognized utterance (neither entity found) fails with a spoken retry hint', () async {
      final recognizer = FakeVoiceRecognizer();
      final speaker = FakeVoiceSpeaker();
      final api = _apiWith((_) => http.Response('{}', 500));

      final service = VoiceSearchService(apiClient: api, recognizer: recognizer, speaker: speaker);
      final errorState = expectLater(
        service.states,
        emitsThrough(predicate<VoiceSearchState>((s) => s.stage == VoiceSearchStage.error)),
      );

      await service.start();
      recognizer.respond('mumble mumble uh...');
      await errorState;

      expect(speaker.spoken.last, contains("didn't catch a bus number or a destination"));
    });

    test('a recognizer error (e.g. noisy audio) fails with a spoken apology', () async {
      final recognizer = FakeVoiceRecognizer();
      final speaker = FakeVoiceSpeaker();
      final api = _apiWith((_) => http.Response('{}', 500));

      final service = VoiceSearchService(apiClient: api, recognizer: recognizer, speaker: speaker);
      final errorState = expectLater(
        service.states,
        emitsThrough(predicate<VoiceSearchState>((s) => s.stage == VoiceSearchStage.error)),
      );

      await service.start();
      recognizer.fail('no speech detected');
      await errorState;

      expect(speaker.spoken.last, contains("didn't catch that"));
    });
  });
}
