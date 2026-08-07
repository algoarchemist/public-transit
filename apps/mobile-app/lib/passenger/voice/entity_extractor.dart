/// The two entities a voice search needs. Either can be missing — the caller
/// prompts for whichever one is, rather than discarding the utterance.
class VoiceEntities {
  const VoiceEntities({this.busIdentifier, this.targetLocation});

  final String? busIdentifier;
  final String? targetLocation;

  bool get isComplete => busIdentifier != null && targetLocation != null;
  bool get isEmpty => busIdentifier == null && targetLocation == null;
}

/// Pulls `bus_identifier` and `target_location` out of a raw speech transcript.
///
/// Deliberately a plain regex parser, not an NLP model — there is no NLP
/// infrastructure anywhere else in this app, the vocabulary here is small and
/// domain-specific ("bus 42 to Central Station"), and a regex is something a
/// future contributor can read and extend without pulling in a model.
class EntityExtractor {
  EntityExtractor._();

  static final _busPattern =
      RegExp(r'\b(?:bus|route)\s*(?:number|no\.?)?\s*([a-z0-9]{1,5})\b', caseSensitive: false);

  static final _locationCuePattern =
      RegExp(r'\b(?:to|towards|toward|near|for|at|going to|headed to)\s+(.+)$', caseSensitive: false);

  static final _bareTokenPattern = RegExp(r'^[a-z0-9]{1,5}$', caseSensitive: false);

  static VoiceEntities extract(String rawTranscript) {
    final transcript = rawTranscript.trim();
    if (transcript.isEmpty) return const VoiceEntities();

    final busMatch = _busPattern.firstMatch(transcript);
    final bus = busMatch?.group(1)?.toUpperCase();

    final locationMatch = _locationCuePattern.firstMatch(transcript);
    String? location = locationMatch != null ? _cleanLocation(locationMatch.group(1)!) : null;

    // No cue word ("to"/"near"/...), but a bus was found — treat whatever follows
    // it as the destination. Covers utterances like "bus 42 central station".
    if (location == null && busMatch != null) {
      final after = transcript.substring(busMatch.end).trim();
      if (after.isNotEmpty) location = _cleanLocation(after);
    }

    // Neither a "bus"/"route" keyword nor a location cue — if the whole
    // utterance is a single short token, treat it as the bus identifier alone
    // (a user who's already been prompted just says "42").
    final soleToken = bus == null && location == null && _bareTokenPattern.hasMatch(transcript)
        ? transcript.toUpperCase()
        : null;

    return VoiceEntities(busIdentifier: bus ?? soleToken, targetLocation: location);
  }

  /// A one-word answer to a targeted "where are you headed?" follow-up prompt —
  /// the whole utterance is the answer, no cue word needed.
  static String? extractLocationOnly(String rawTranscript) {
    final transcript = rawTranscript.trim();
    if (transcript.isEmpty) return null;
    final cued = _locationCuePattern.firstMatch(transcript);
    return _cleanLocation(cued?.group(1) ?? transcript);
  }

  /// A one-word answer to a targeted "which bus?" follow-up prompt.
  static String? extractBusOnly(String rawTranscript) {
    final transcript = rawTranscript.trim();
    if (transcript.isEmpty) return null;
    final cued = _busPattern.firstMatch(transcript);
    if (cued != null) return cued.group(1)!.toUpperCase();
    final token = RegExp(r'[a-z0-9]{1,5}', caseSensitive: false).firstMatch(transcript);
    return token?.group(0)?.toUpperCase();
  }

  static String _cleanLocation(String raw) {
    final trimmed = raw.trim().replaceAll(RegExp(r'[.?!]+$'), '').trim();
    if (trimmed.isEmpty) return trimmed;
    return trimmed.split(' ').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');
  }
}
