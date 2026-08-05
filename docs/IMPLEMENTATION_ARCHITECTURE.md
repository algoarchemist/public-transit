# SetuTrack — Implementation Architecture

Companion to [`SIH25013_TrackMyRide_Solution.md`](../SIH25013_TrackMyRide_Solution.md).
That document argues *what* to build and *why those technologies*. This one specifies
*how it is actually assembled*: components, data model, contracts between services,
and the order things get built in.

**Governing constraint:** no hardcoded route geometry, no invented stop coordinates.
Every route polyline, stop location, and baseline travel time originates from a real
data source (OSM / OSRM / published operator timetables). The GPS *motion* is
simulated — because we have no live fleet — but it is simulated **on top of real
geometry with distributions calibrated against real-world timings**. The distinction
matters and is defended in §5.4.

---

## 1. Current state

| Component | State |
|---|---|
| `apps/admin-dashboard` | Vite+React+TS+Tailwind, routed shell, 6 stub pages. Builds. |
| `apps/mobile-app` | One Flutter app, both roles — startup screen picks Passenger vs Driver/Conductor, persisted via `shared_preferences`. Driver flow has a real, tested divergence-triggered GPS transmitter + SQLite offline buffer (§7.4); passenger flow is still screen stubs. **No platform folders** — needs `flutter create .` |
| `services/api-gateway` | NestJS, 4 modules (routes/buses/tickets/auth) with stub returns. Builds. |
| `services/ml-service` | FastAPI, `/eta/predict` + `/crowd/predict`, naive baselines. Runs. |
| `services/stream-processor` | Real map-matching + route-aware degradation-ladder dead reckoning against the geo-ingest snapshot (`routeStore.ts`, `geo.ts`, `deadReckoning.ts`), both verified against real Mohali-tricity data (§7.3–7.4). `consumer.ts` (MQTT→Redis→Kafka) + `gateway.ts` (Kafka→Socket.IO + watchdog). Still per-ping, not batched (§7.3). Typechecks. |
| `services/geo-ingest` | Python. Real OSM/OSRM route+stop ingestion — 100 real CTU route directions reconciled and enriched with real OSRM segment baselines, committed as a GeoJSON/GTFS snapshot (see its own README and §4, §11.1). |
| `packages/shared-types` | GPS/bus-state/ML request-response types. Builds. |
| `docker-compose.yml` | Postgres+PostGIS, Redis, Redpanda, EMQX. **Never started — Docker not installed.** |

Real data now flows through the stream-processor: `routeStore.ts` loads the
committed geo-ingest snapshot at process start, and map-matching / dead reckoning
run against that real geometry — not stubs. What's still wiring-with-`TODO`: the
protobuf wire format, batched (rather than per-ping) map-matching/ETA scoring, and
everything gated on Docker (PostGIS-backed persistence, the actual MQTT/Kafka/Redis
transport this has all been tested to run *through* but not yet run *on*, since
Docker isn't installed here).

### Environment gaps blocking work

1. **Docker Desktop is not installed** — blocks Postgres/PostGIS, Redis, Redpanda, EMQX, and therefore blocks actually running the MQTT→Kafka→Redis→Socket.IO pipeline end-to-end (the logic on both sides of it — map-matching, dead reckoning, the transmitter — is built and unit-verified without it).
2. **Flutter/Dart SDK is not installed** — blocks the mobile app (no platform folders, no way to run `dart analyze`/`flutter test`; the Dart source was reviewed by hand instead).
3. Overpass and the public OSRM demo server are both reachable from this machine (verified).

---

## 2. Component map

New components this plan introduces, in the existing `apps/ services/ packages/` layout:

```
services/
  geo-ingest/        [NEW, Python]  OSM/OSRM -> canonical routes & stops -> PostGIS
  simulator/         [NEW, Python]  real geometry + calibrated distributions -> GPS traces
  api-gateway/       [exists]
  ml-service/        [exists, extend] serving + training share one feature module
  stream-processor/  [exists, extend]
packages/
  proto/             [NEW]  .proto ping schema, codegen for TS / Python / Dart
  shared-types/      [exists]
db/
  migrations/        [NEW]  versioned SQL (PostGIS + TimescaleDB); replaces TypeORM synchronize
data/
  cache/             raw Overpass/OSRM responses (reproducibility, rate-limit friendliness)
  snapshots/         committed GeoJSON + GTFS-static export of the ingested city
```

**Why `geo-ingest` and `simulator` are Python:** the simulator's speed/dwell/boarding
distributions are the same code that calibrates and validates the ML training set.
Keeping simulation and training in one language means the calibration constants have a
single home. `geo-ingest` joins them because shapely/geopandas do the polyline work.

**Why `db/migrations` replaces `synchronize: true`:** the current `api-gateway`
`TypeOrmModule` has `synchronize` on. That cannot express PostGIS geometry columns with
SRID constraints, GiST indexes, or TimescaleDB hypertables. Schema moves to explicit SQL
migrations; TypeORM entities become read models over that schema.

---

## 3. Data model

PostgreSQL 16 + PostGIS 3.4 + TimescaleDB. All geometry `SRID 4326`; distance math in
`geography` or a projected CRS (EPSG:32643, UTM 43N covers Punjab) — never raw degrees.

### 3.1 Static / reference tables

**`cities`** — `id, name, state, osm_area_id, bbox geometry(Polygon,4326)`

**`stops`**
```
id, city_id, osm_node_id, name, name_pa, name_hi,
geom geometry(Point,4326), footfall_prior real, created_at
```
`footfall_prior` is derived from real OSM POI density within 200 m (markets, schools,
hospitals) — it drives dwell time in the simulator and is a genuine feature, not a guess.

**`routes`**
```
id, city_id, ref, name, operator, direction,
osm_relation_id nullable, source enum('osm_relation','osrm_synthesized'),
geom geometry(LineString,4326), length_m double precision
```
`source` is recorded per route so we can always state which routes came straight from an
OSM relation and which were reconstructed. Honesty about provenance is a scoring point.

**`route_stops`** — ordered stop list with position along the line
```
route_id, stop_id, sequence, dist_along_route_m, scheduled_offset_sec
PRIMARY KEY (route_id, sequence)
```
`dist_along_route_m = ST_LineLocatePoint(route.geom, stop.geom) * route.length_m`

**`route_segments`** — stop-to-stop; **the unit of ETA prediction**
```
id, route_id, sequence, from_stop_id, to_stop_id,
geom geometry(LineString,4326),   -- ST_LineSubstring of the parent route
length_m, osrm_baseline_sec, dominant_highway_class
```

**`buses`** — `id, registration_no, depot_id, capacity, has_vltd, model`

### 3.2 Operational / time-series tables

**`trips`** — one bus running one route once
```
id, route_id, bus_id, driver_id, scheduled_start, started_at, ended_at,
status enum('scheduled','running','completed','abandoned')
```

**`gps_pings`** — TimescaleDB hypertable, partitioned on `time`
```
time timestamptz, trip_id, bus_id, geom geometry(Point,4326),
speed_kmh, heading, accuracy_m, source enum('sim','vltd','driver_app')
```
Retention: raw pings 90 d, then drop to continuous aggregates.

**`map_matched_positions`** — hypertable, derived by `stream-processor`
```
time, trip_id, route_id, dist_along_route_m, fraction_complete,
current_segment_id, next_stop_id, delay_sec
```

**`stop_events`** — **ground truth for ETA training**
```
trip_id, stop_id, sequence, arrived_at, departed_at, dwell_sec,
boarding_count, alighting_count
```

**`occupancy_snapshots`** — `time, trip_id, occupancy, source enum('conductor_tally','ticket_derived','sensor')`

**`tickets`** — `id, passenger_id, trip_id, from_stop_id, to_stop_id, fare_paise, qr_payload, signature, status, purchased_at, validated_at, validated_offline bool`

**`alerts`** — `id, type enum('sos','breakdown','route_deviation','signal_lost'), trip_id, bus_id, geom, raised_at, resolved_at, notes`

### 3.3 Derived feature tables

**`segment_travel_stats`** — TimescaleDB continuous aggregate, refreshed hourly.
This is the single most important table for ETA quality.
```
route_id, segment_id, dow, hour_bucket, window enum('7d','30d'),
avg_speed_kmh, p50_duration_sec, p85_duration_sec, sample_count
```

**`stop_dwell_stats`** — `stop_id, dow, hour_bucket, p50_dwell_sec, avg_boarding, avg_alighting, sample_count`

---

## 4. Real-world data collection pipeline (`services/geo-ingest`)

City-agnostic: the target city is a config parameter, so the pipeline stays valid
regardless of which Punjab city is finally chosen.

### 4.1 Stages

**Stage 1 — Discover.** Overpass query scoped to the city admin area, pulling:
`relation[type=route][route=bus]`, `node[highway=bus_stop]`,
`node[public_transport=platform]`, plus the drivable highway network.

**Stage 2 — Reconcile.** OSM bus-route *relations* are well-mapped in Indian metros but
sparse-to-absent in tier-3 Punjab towns. The pipeline must handle both, and record which
path it took:

- **Path A — relation exists.** Extract member ways in order, stitch to a single
  `LINESTRING` (handling reversed ways and gaps), take `platform`/`stop` role members as
  the stop sequence. `source='osm_relation'`.
- **Path B — no relation.** Take the **real** `highway=bus_stop` nodes along the
  corridor plus the operator's published stop sequence (PRTC/PUNBUS route lists), then
  call OSRM `/route` with those stops as ordered waypoints. OSRM snaps them to the
  **real road network** and returns a road-following polyline. `source='osrm_synthesized'`.

Path B is still real-world data: real roads, real stop coordinates, real routing engine.
The only human-supplied input is the *order* of stops, taken from the operator's own
published route list. That distinction is worth stating explicitly to judges.

**Stage 3 — Enrich.** Per segment: OSRM `/route` for free-flow baseline duration;
dominant `highway=*` class from the underlying ways; `footfall_prior` per stop from OSM
POI density.

**Stage 4 — Persist.** Write to PostGIS; emit a GeoJSON snapshot and a GTFS-static
export into `data/snapshots/` so a run is reproducible and reviewable without a database.

### 4.2 Operational rules

- **Cache every raw response** under `data/cache/` keyed by query hash. Overpass allows
  2 concurrent slots; an uncached pipeline will get throttled and makes runs
  irreproducible.
- **Self-host OSRM** in Docker for the enrichment pass (a Punjab OSM extract is small).
  The public demo server is rate-limited and explicitly not for batch use — depending on
  it would make the pipeline unreliable exactly when demoing.
- **Idempotent by `osm_node_id` / `osm_relation_id`** so re-running updates rather than
  duplicates.
- **Validation gate** — reject a route if the polyline is discontinuous, if stop
  projections are non-monotonic along the line, or if any stop is >150 m from its
  projection. Bad geometry silently destroys ETA accuracy, so it fails loudly at ingest.

---

## 5. GPS simulation engine (`services/simulator`)

### 5.1 Principle

The simulator does **not** invent positions. It advances a bus along a real
`route_segments` polyline, drawing its speed from distributions anchored to real OSRM
baseline durations and real road classes.

### 5.2 Generative model

Per segment traversal:
```
base_speed      = segment.length_m / segment.osrm_baseline_sec     # real, from OSRM
congestion      = f(hour, dow, is_holiday, highway_class)          # calibrated multiplier
noise           ~ LogNormal(0, sigma_segment)
actual_speed    = base_speed * congestion * noise
```
Per stop:
```
boarding    ~ Poisson(lambda(stop.footfall_prior, hour, dow, school_term))
alighting   ~ Poisson(mu(occupancy, stop.footfall_prior, hour))
dwell_sec   = 8 + 1.8*boarding + 1.1*alighting + LogNormal(...)
occupancy   = clamp(occupancy + boarding - alighting, 0, bus.capacity)
```
Per emitted ping:
```
observed_position = true_position + Gaussian(0, 5..15 m)
+ occasional urban-canyon outlier (heavy tail)
+ dropout windows -> exercises the "bus went dark" path (§7.4)
+ adaptive interval: 5 s near stop / 15-20 s cruising  (mirrors driver-app behaviour)
```

### 5.3 Two sinks, one core

| Mode | Sink | Purpose |
|---|---|---|
| `--mode=live` | MQTT publish, wall-clock paced | Stage demo — drives the entire real pipeline |
| `--mode=backfill --days=90` | Bulk insert to TimescaleDB | Generates the ML training corpus |

Same generative code both ways. The demo and the training data therefore come from one
explainable process, which is much easier to defend than two separate fakes.

### 5.4 Calibration and the honesty problem

**The trap:** train the ETA model on simulator output, evaluate on simulator output, and
you have measured only that the model learned the simulator — not that it predicts
reality. Judges do probe this.

Mitigations, all of which belong in the pitch:

1. **Calibrate against real published timings.** PRTC/PUNBUS timetables give real
   end-to-end trip durations. Tune congestion multipliers until simulated trip-duration
   distributions match published times; report that fit as a number.
2. **Time-based splits only.** Train on days 1–60, validate 61–75, test 76–90. Random
   splits leak, since trips on the same day share congestion draws.
3. **Report against the naive baseline.** The honest headline metric is
   "MAE vs. distance/avg-speed baseline", not raw MAE — the baseline is subject to the
   same simulator, so the *improvement* is the meaningful signal.
4. **Design for online retraining.** Schema and training pipeline take
   `gps_pings.source` as a first-class field; the day real VLTD data arrives, the same
   pipeline retrains on `source='vltd'` with no code change. Say this out loud — it is
   the AIS-140 deployability argument in concrete form.

---

## 6. ML architecture

### 6.1 Train/serve skew prevention

**One feature module, imported by both paths:** `services/ml-service/app/features.py`
defines every feature transform. Training imports it; the FastAPI serving path imports
it. No feature is ever computed twice in two places. This is the single most common way
ETA systems silently rot, and it costs nothing to prevent now.

### 6.2 ETA model

- **Unit of prediction:** per-segment traversal time (not whole-trip). ETA to stop *N*
  is the sum of remaining predicted segment times plus predicted dwells.
- **Model:** LightGBM regressor. Features from `segment_travel_stats` +
  `stop_dwell_stats` + live state: hour bucket, dow, holiday flag, distance-to-stop,
  current delay, weather bucket, occupancy, and a **live traffic factor** =
  observed speed on the current segment ÷ its historical average.
- **Online correction:** blend model prior with live observed pace, Kalman-style, so the
  number reacts within one ping rather than being a static prediction.
- **Target:** MAE < 2 min for stops within a 10-minute horizon; report MAE bucketed by
  horizon, since a single aggregate MAE hides the near-term error that passengers feel.

### 6.3 Crowd model

LightGBM regressor per stop predicting boarding/alighting, conditioned on hour, dow,
`footfall_prior`, current occupancy. Feeds both the passenger occupancy badge and the
admin demand-supply view.

### 6.4 Serving contract change

The current `/eta/predict` takes one bus and returns one scalar. That is wrong on two
counts. It should become:

- **`POST /eta/predict-batch`** — the stream processor scores *all* active buses about
  once per second (doc §5.1.4); per-ping HTTP calls will not hold up.
- **Response carries per-stop ETAs**, not a single number — the passenger UI shows the
  next three stops, and the admin view needs the whole downstream chain.

Model artifacts land in `services/ml-service/artifacts/` as ONNX plus a sidecar
`metrics.json` (MAE by horizon, training window, row count, git SHA) so the dashboard's
Model Health page has something real to render.

---

## 7. Real-time pipeline

### 7.1 Wire format

Protobuf, defined once in `packages/proto/gps.proto`, codegen'd to TS
(stream-processor), Python (simulator), and Dart (driver app). The current
`JSON.parse` in `consumer.ts` is a placeholder. Payload target 20–40 bytes vs 200+ for
JSON — this is the headline low-bandwidth claim and it needs to be true.

### 7.2 Topics

| Transport | Topic | Payload |
|---|---|---|
| MQTT | `gps/{busId}/ping` | protobuf GpsPing |
| MQTT | `bus/{busId}/status` | trip start/end, delay tags |
| MQTT | `sos/{busId}` | SOS / breakdown |
| Kafka | `raw-gps-pings` | bridged from MQTT (EMQX rule engine in prod) |
| Kafka | `bus-state-updates` | enriched state → WebSocket fan-out |
| Kafka | `stop-events` | arrivals/departures → analytics + training |

### 7.3 Processing loop (corrects the current scaffold)

`consumer.ts` still map-matches and calls the ML service **per ping** rather than
batching into a 1-second window across all active buses — that batching (item 2/4
below) is not yet built. What IS built, replacing the earlier `mapMatch.ts` stub:

1. **Real map-matching** (`routeStore.ts` + `geo.ts` + `mapMatch.ts`) — loads the
   geo-ingest snapshot (`data/snapshots/<label>/{routes,stops,segments}.geojson`,
   real OSM geometry + real OSRM segment baselines) into memory at process start,
   and projects each raw fix onto the bus's real route line — the in-process,
   pre-Docker equivalent of the PostGIS `ST_LineLocatePoint` design below. Verified
   against the real Mohali-tricity snapshot: a synthetic ~20m GPS offset round-tripped
   to a computed offset of 20.8m.
2. Batch map-match via PostGIS, once Postgres/PostGIS is actually running — not yet
   built; today's version calls `mapMatch()` per ping, in-process, no DB round-trip.
3. One batched call to `/eta/predict-batch` — not yet built; `scoreEta()` is still
   called per ping against `/eta/predict`.
4. Pipelined Redis writes (`bus:{id}:position` now also carries `directionId`,
   `distAlongRouteM`, `speedMps`, `nextStopId/Name` — the state the degradation
   ladder below needs) plus an `active-buses` Set the ladder's watchdog scans.
5. One Kafka produce per ping (not yet batched) to `bus-state-updates`, tagged
   `confidenceTier: 'live'`.

Ordering guarantee: Kafka key = `busId`, so a single bus's updates stay ordered on one
partition.

### 7.4 Degradation ladder — built

What the passenger sees while a bus's pings have stopped, instead of either a frozen
marker (dishonest — looks live when it isn't) or a hidden one (throws away a good
estimate). Implemented in `services/stream-processor/src/deadReckoning.ts` plus a
watchdog loop in `gateway.ts` that ticks every 5s independently of any real ping:

| Age since last real ping | Tier | Passenger sees |
|---|---|---|
| ≤ 60s (`LIVE_MAX_AGE_SEC`) | `live` | Real last-reported position (pushed instantly via the Kafka consumer, not the watchdog) |
| 60–180s (`ESTIMATED_MAX_AGE_SEC`) | `estimated` | Position dead-reckoned along the **real** route geometry, badge: "estimated position — signal lost Ns ago" |
| \> 180s | `stale` | Last known position held, badge: "last seen N min ago near X — estimate may be stale" |

The extrapolation blends the bus's last observed speed toward its **current
segment's real OSRM-baseline average speed** as the gap grows (recent momentum is
the best guide right after signal loss; the segment's typical pace is a better guide
the longer it's been dark) — via a proper time-integral of the linear speed ramp, not
`blend(age) * age`, which is non-monotonic and can imply the bus briefly moved
*backward* (caught and fixed during testing — verified monotonic across a 400s sweep
at 1-second resolution).

**Driver-side divergence-triggered transmitter** (`apps/mobile-app/lib/driver/location_transmitter.dart`)
— publishes a ping only when the real GPS fix diverges >50m from simple
constant-velocity straight-line extrapolation off the *last transmitted* fix, plus a
mandatory 60s heartbeat. This predictor is intentionally simpler than, and does not
need to match, the server-side route-aware one above — one decides *when* to send,
the other *what to show* when nothing arrives.

**Driver offline** — pings queue in a bounded SQLite buffer (`ping_buffer.dart`,
2000-row oldest-first eviction), flushed on reconnect; anything buffered >30s is
flagged `lateArrival: true` — the consumer/ladder must never let a replayed backlog
rewind a bus's live position (this flag is defined; the consumer doesn't yet special-case
it on ingest — see Known gaps below).

**Not yet built:**
- Protobuf wire format (§7.1) — both the transmitter and `consumer.ts` still use JSON.
- A real Android/iOS foreground service — the transmitter's Dart logic is complete
  and independently testable, but survives-screen-off needs native platform config
  that can't exist until `flutter create .` generates `android/`/`ios/`.
- `consumer.ts` doesn't yet special-case incoming pings flagged `lateArrival: true`
  (e.g. routing them to TimescaleDB history without overwriting the live Redis key
  if a fresher ping has since arrived) — the flag exists end-to-end but nothing acts
  on it server-side yet.
- Low-bandwidth passenger-app fallbacks (text-only ETA, cached map tiles, SMS/USSD).

---

## 8. API surface (`api-gateway`)

```
POST   /api/auth/otp/request | /verify
GET    /api/routes | /routes/:id | /routes/:id/stops | /routes/:id/performance
GET    /api/stops/nearby?lat&lon&radius_m
GET    /api/buses | /buses/:id | /buses/:id/eta          # REST polling fallback
POST   /api/trips | PATCH /api/trips/:id/end             # driver
POST   /api/trips/:id/tally                              # conductor +/- occupancy
POST   /api/tickets/fare | /api/tickets | /api/tickets/:id/validate
POST   /api/alerts/sos | /api/alerts/breakdown
GET    /api/admin/analytics/ridership | /demand-supply | /model-health
```
WebSocket (`stream-processor/gateway.ts`) carries all live state; REST endpoints are the
low-bandwidth polling fallback, not the primary path.

---

## 9. Offline-verifiable ticketing

The conductor must validate a QR **with no connectivity on either device**. Design:

1. On purchase, server signs the ticket payload with **Ed25519**.
2. QR encodes `{ticketId, routeId, fromStop, toStop, validFrom, validUntil, fare, sig}`.
3. Driver app ships the **public key** and verifies the signature offline — no network,
   no server round-trip.
4. **Replay protection:** driver app keeps a local seen-set of validated ticket IDs and
   syncs on reconnect; server dedupes and flags multi-device replays for audit.

Step 4 is the part that is usually missing, and it is exactly what a technically strong
judge will ask about.

---

## 10. Build phases

Ordered by dependency; each phase ends with something demonstrable.

| Phase | Deliverable | Depends on |
|---|---|---|
| **0. Unblock** | Docker Desktop + Flutter SDK installed; `docker compose up` green; self-hosted OSRM with a Punjab extract | — |
| **1. Real data** | `geo-ingest` run end-to-end → 2 real routes with stops, segments, baselines in PostGIS; GeoJSON snapshot committed | 0 |
| **2. Safety-net MVP** | `simulator --mode=live` → MQTT → consumer → Redis/Kafka → gateway → **dot moving on the admin MapLibre map** | 1 |
| **3. Training corpus** | `simulator --mode=backfill --days=90`; calibration fit vs published timetables reported | 1 |
| **4. ETA model** | Feature extraction, LightGBM, time-split eval, ONNX export, `/eta/predict-batch` live; naive baseline retired | 3 |
| **5. Driver app** | Trip start/end, foreground GPS → MQTT, offline SQLite queue, tally buttons | 0, 2 |
| **6. Passenger app** | Live map, ETA, occupancy badge, degraded text mode | 2, 4 |
| **7. Ticketing** | Fare calc, UPI sandbox, Ed25519 QR, offline validation + replay sync | 5, 6 |
| **8. Crowd + planning** | Crowd model; admin demand-supply view (the highest-scoring admin feature) | 4 |
| **9. Voice + i18n** | Punjabi/Hindi/English strings; Bhashini/Whisper → intent → booking API function-calling | 7 |
| **10. Hardening** | SOS/alerts, signal-loss paths, model-health page, load test, **recorded backup demo video** | all |

Phase 2 is the safety net: once a dot moves on the map through the real pipeline, there
is always something to show, and every later phase is additive.

---

## 11. Open decisions

1. **Target city** — Bathinda / Patiala / Pathankot. Pipeline is city-agnostic, but the
   choice should be driven by *actual OSM bus-route coverage*, which Phase 1 measures.
   Decide with data, not preference.
2. **Kafka vs. Redis Streams** — Redpanda is already in compose, but for a 2-route,
   ~20-bus demo, Redis Streams would remove a whole moving part. Keeping Kafka is
   defensible as a scale story; dropping it is defensible as an ops story. Worth an
   explicit call rather than drifting into it.
3. **Keycloak vs. Firebase Auth** — doc says Keycloak for data sovereignty, Firebase for
   hackathon speed. Firebase now + Keycloak as stated production path is the pragmatic
   split, but it must be *said*, not hidden.
4. **`react-router` 7.12.0** carries a high-severity CSRF advisory; the fix is a
   downgrade to 7.11.0. Low real exposure for an authenticated dashboard, but it will
   surface in any audit run during judging.

---

## 12. Principal risks

| Risk | Mitigation |
|---|---|
| OSM bus-route coverage in tier-3 Punjab is thin | Path B reconstruction (§4.2) — real stops + real roads via OSRM; provenance recorded per route |
| Model learns the simulator, not reality | Calibration against published timings; time-based splits; report improvement over baseline; retrain-on-VLTD path built in (§5.4) |
| Public OSRM/Overpass throttling mid-demo | Self-host OSRM; cache every raw response; snapshots committed so a demo never needs the network |
| Venue Wi-Fi failure | Whole pipeline runs on one laptop via compose; recorded backup video (doc §6) |
| Scope overrun on voice/ML | Phase order protects the live-tracking core; phases 8–9 are the first to be cut |

---

*Living document — update as decisions in §11 are resolved.*
