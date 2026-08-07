import 'package:flutter_test/flutter_test.dart';
import 'package:setutrack_mobile/passenger/voice/entity_extractor.dart';

void main() {
  group('EntityExtractor.extract', () {
    test('parses "bus <N> to <place>"', () {
      final e = EntityExtractor.extract('bus 42 to Central Station');
      expect(e.busIdentifier, '42');
      expect(e.targetLocation, 'Central Station');
      expect(e.isComplete, isTrue);
    });

    test('parses a route letter suffix', () {
      final e = EntityExtractor.extract('route 2a to Housing Board Chowk');
      expect(e.busIdentifier, '2A');
      expect(e.targetLocation, 'Housing Board Chowk');
    });

    test('handles "near" as a location cue', () {
      final e = EntityExtractor.extract('when does bus 15 arrive near Market Square');
      expect(e.busIdentifier, '15');
      expect(e.targetLocation, 'Market Square');
    });

    test('falls back to trailing words when no cue word is present', () {
      final e = EntityExtractor.extract('bus 42 central station');
      expect(e.busIdentifier, '42');
      expect(e.targetLocation, 'Central Station');
    });

    test('missing location leaves targetLocation null', () {
      final e = EntityExtractor.extract('bus 42');
      expect(e.busIdentifier, '42');
      expect(e.targetLocation, isNull);
      expect(e.isComplete, isFalse);
    });

    test('missing bus leaves busIdentifier null', () {
      final e = EntityExtractor.extract('going to Central Station');
      expect(e.busIdentifier, isNull);
      expect(e.targetLocation, 'Central Station');
    });

    test('a bare short token is treated as the bus identifier', () {
      final e = EntityExtractor.extract('42');
      expect(e.busIdentifier, '42');
      expect(e.targetLocation, isNull);
    });

    test('empty transcript yields nothing', () {
      final e = EntityExtractor.extract('   ');
      expect(e.isEmpty, isTrue);
    });

    test('trailing punctuation from the recognizer is stripped from the location', () {
      final e = EntityExtractor.extract('bus 9 to Sector 17?');
      expect(e.targetLocation, 'Sector 17');
    });
  });

  group('EntityExtractor.extractBusOnly / extractLocationOnly', () {
    test('extractBusOnly reads a bare follow-up answer', () {
      expect(EntityExtractor.extractBusOnly('42'), '42');
      expect(EntityExtractor.extractBusOnly('bus 42'), '42');
      expect(EntityExtractor.extractBusOnly('2a'), '2A');
    });

    test('extractLocationOnly reads a bare follow-up answer', () {
      expect(EntityExtractor.extractLocationOnly('central station'), 'Central Station');
      expect(EntityExtractor.extractLocationOnly('to Central Station'), 'Central Station');
    });
  });
}
