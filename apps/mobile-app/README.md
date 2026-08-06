# SetuTrack — Mobile App

One Flutter app for both riders and crew. The startup screen
(`lib/role_selection_screen.dart`) asks "I'm a Passenger" or "I'm a Driver /
Conductor" and routes into the matching flow; the choice is persisted
(`shared_preferences`) so a returning user skips straight to their flow. An app-bar
"switch role" action on each flow's entry screen (`lib/passenger/home_screen.dart`,
`lib/driver/login_screen.dart`) clears that choice — handy for demoing both sides on
one phone.

See `SIH25013_TrackMyRide_Solution.md` section 4.1 (passenger) and 4.2
(driver/conductor) for the full screen/flow spec.

```
lib/
  main.dart                    startup gate + route table for both flows
  config.dart                  compile-time config (MQTT broker host/port via --dart-define)
  role_selection_screen.dart   startup role picker, persists the choice
  role_switch.dart             clears the choice, returns to the picker
  passenger/                   home, live map, ticketing, voice assistant
  driver/
    login_screen.dart, route_selection_screen.dart, ticket_validation_screen.dart
    on_trip_screen.dart        starts/stops the GPS transmitter, shows sent/buffered counts
    location_transmitter.dart  divergence-triggered GPS transmitter (see below)
    ping_buffer.dart           SQLite-backed offline queue used by the transmitter
```

## GPS transmitter (`lib/driver/location_transmitter.dart`)

Publishes a ping only when the bus's real position has diverged >50m from where
simple constant-velocity extrapolation (from the last transmitted fix) would put
it, plus a mandatory 60s heartbeat. On a straight road at steady speed this sends
almost nothing; approaching a stop or stuck in traffic, it sends often — see
`SIH25013_TrackMyRide_Solution.md` §1.3 and `docs/IMPLEMENTATION_ARCHITECTURE.md`
§7 for the full design.

When MQTT publish fails or the device is offline, pings queue in a bounded SQLite
buffer (`ping_buffer.dart`, oldest-first eviction past 2000 rows) and flush on
reconnect; anything that sat buffered more than 30s is flagged `lateArrival: true`
so the server never lets a replayed backlog rewind a bus's live position (see
`services/stream-processor/src/deadReckoning.ts` and architecture doc §7.4).

This predictor is deliberately simple (straight-line, no route geometry) and does
**not** need to match the server-side route-aware dead-reckoning predictor used for
the passenger-facing degradation ladder — this one only decides *when* to send;
the server's decides *what to show the passenger* when nothing arrives. They can
differ freely without desyncing.

**Known gaps**, both flagged inline in the code:
- No real foreground service yet — `android/`/`ios/` platform folders now exist
  (`flutter create .` has been run), but the native config for surviving
  screen-off (Android foreground service, iOS background modes) hasn't been added
  to them.
- Wire format is still JSON, not the protobuf the solution doc calls for (~20-40
  bytes/ping on the wire vs 200+ for JSON) — `stream-processor`'s consumer has the
  matching TODO on the decode side.

## Setup

`pubspec.yaml`, `lib/`, and the generated platform folders (`android/`, `ios/`,
`web/`) are all present — `flutter create .` has already been run. From this
directory:

```
flutter pub get
flutter run
```

If the platform folders are ever wiped or need regenerating, `flutter create .`
fills them back in without touching the existing `lib/` and `pubspec.yaml`.

To point the driver flow's GPS transmitter at a real EMQX broker instead of the
Android-emulator-only default (`config.dart`):

```
flutter run --dart-define=MQTT_BROKER_HOST=192.168.1.50
```
