# SetuTrack — Passenger App

Flutter app: live bus tracking, ETA, ticketing, voice assistant. See
`SIH25013_TrackMyRide_Solution.md` section 4.1 for the full screen/flow spec.

## Setup

This directory has `pubspec.yaml` and `lib/` hand-written, but not the generated
platform folders (`android/`, `ios/`, `web/`) — those need the Flutter SDK, which
wasn't available in the environment this was scaffolded in. Once Flutter is
installed, run once from this directory:

```
flutter create .
flutter pub get
flutter run
```

`flutter create .` will fill in the platform folders without touching the
existing `lib/` and `pubspec.yaml`.
