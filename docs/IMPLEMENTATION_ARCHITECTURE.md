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
| `apps/admin-dashboard` | Vite+React+TS+Tailwind, routed shell, 5 stub pages + a real Live Fleet Map (`useFleetSocket` + `FleetMap`, MapLibre, socket.io-client against `gateway.ts`'s new `admin:fleet` room). Builds. |
| `apps/mobile-app` | One Flutter app, both roles — startup screen picks Passenger vs Driver/Conductor, persisted via `shared_preferences`. Driver flow has a real, tested divergence-triggered GPS transmitter + SQLite offline buffer (§7.4); passenger flow is still screen stubs. **No platform folders** — needs `flutter create .` |
| `services/api-gateway` | NestJS, 4 modules (routes/buses/tickets/auth) with stub returns. Builds. |
| `services/ml-service` | FastAPI, `/eta/predict` + `/crowd/predict`, naive baselines. Runs. |
| `services/stream-processor` | Real map-matching + route-aware degradation-ladder dead reckoning against the geo-ingest snapshot (`routeStore.ts`, `geo.ts`, `deadReckoning.ts`), both verified against real Mohali-tricity data (§7.3–7.4). `consumer.ts` (MQTT→Redis→Kafka) + `gateway.ts` (Kafka→Socket.IO + watchdog). ETA scoring is now batched once/sec across all live buses (`etaScoringLoop.ts`, §7.3 item 3); map-matching itself is still per-ping, in-process (§7.3 item 2). Typechecks. |
| `services/geo-ingest` | Python. Real OSM/OSRM route+stop ingestion — 103 real CTU route directions reconciled and enriched with real OSRM segment baselines, committed as a GeoJSON/GTFS snapshot (see its own README and §4, §11.1). Stop discovery queries nodes **and** ways; the earlier node-only query silently dropped way-mapped platforms/stations (38→56 features, 540→620 stop rows, +3 routes). |
| `services/simulator` | Python. GPS simulator (Phase 2/3, §10) — walks real routes with congestion/crowd models calibrated against real OSRM baselines; `--mode=live` (divergence-triggered MQTT publish, mirrors the mobile-app transmitter) and `--mode=backfill` (training corpus CSV). Verified against all 100 real routes; caught and fixed 3 real bugs along the way, one of which (a flawed "first stop = distance 0" assumption) also existed in `stream-processor/routeStore.ts` and is now fixed in both — see its own README. |
| `packages/shared-types` | GPS/bus-state/ML request-response types. Builds. |
| `docker-compose.yml` | Postgres+PostGIS, Redis, Redpanda, EMQX, self-hosted OSRM (tricity bbox, `infra/docker/osrm/`). **Up and healthy** (`docker compose up -d`). |

Real data now flows through the stream-processor: `routeStore.ts` loads the
committed geo-ingest snapshot at process start, and map-matching / dead reckoning
run against that real geometry — not stubs. The live MQTT→consumer→Kafka→gateway→
Socket.IO chain has been run end-to-end against simulated buses (§10 Phase 2) — real
map-matching, real (naive-baseline) ETA scoring, Kafka consumer lag 0, and now the
admin dashboard's Live Fleet Map actually subscribed and rendering (server-side
confirmed live; not yet human-eyeballed in a browser as of this writing). What's
still wiring-with-`TODO`: the protobuf wire format, batched (rather than per-ping)
map-matching/ETA scoring, and route-polyline overlay on the fleet map (no GeoJSON
endpoint reachable by the browser yet). `db/migrations/` now
creates the full §3 schema (plain PostGIS — TimescaleDB was dropped from the MVP
scope for speed, see §2) and `persist.py` does real route/stop/segment upserts
against it, not just `cities`.

### Environment gaps blocking work

1. ~~Docker Desktop is not installed~~ — **resolved.** Docker Desktop is installed and
   `docker compose up -d` brings up Postgres/PostGIS, Redis, Redpanda, EMQX, and a
   self-hosted OSRM instance (tricity bbox) all healthy. Remaining PostGIS-write gap is
   schema (`db/migrations` doesn't exist yet), not Docker.
2. ~~Flutter/Dart SDK is not installed~~ — **resolved.** Flutter 3.44.8 is installed;
   `apps/mobile-app` has real `android/`/`ios/` platform folders now (`flutter create .`
   has been run), unblocking `flutter analyze`/`flutter test`.
3. Overpass and the public OSRM demo server are both reachable from this machine
   (verified) — though `geo-ingest`'s `OSRM_URL` now points at the self-hosted instance
   by default (§4.2).

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
  migrations/        [NEW]  versioned SQL (PostGIS); replaces TypeORM synchronize. TimescaleDB
                     dropped from the MVP — plain indexed tables are enough at this data volume.
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

PostgreSQL 16 + PostGIS 3.4. (TimescaleDB was in the original design for the
time-series tables below but dropped from the MVP for speed/complexity — plain
`time`-indexed tables instead of hypertables. §3.3's `segment_travel_stats`/
`stop_dwell_stats` are now built, but as plain tables populated by an offline
batch script, not a live TimescaleDB continuous aggregate — see §3.3 and
`db/migrations/0003_derived_stats.sql`.) All geometry `SRID 4326`; distance math
in `geography` or a projected CRS (EPSG:32643, UTM 43N covers Punjab) — never raw
degrees.

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

### 3.3 Derived feature tables — ✅ built (`db/migrations/0003_derived_stats.sql`)

**`segment_travel_stats`** — the single most important table for ETA quality.
```
direction_id, sequence, route_id, dow, hour_bucket, agg_window enum('7d','30d'),
avg_speed_kmh, p50_duration_sec, p85_duration_sec, sample_count
```

**`stop_dwell_stats`** — `stop_osm_node_id, dow, hour_bucket, p50_dwell_sec, avg_boarding, avg_alighting, sample_count`

Two deliberate deviations from the schema as originally specified, both explained
in full in `0003_derived_stats.sql`'s header comment:

- **Keyed by `(direction_id, sequence)` / `stop_osm_node_id`, not `route_segments.id`/
  `stops.id`.** The live in-memory pipeline (`stream-processor/routeStore.ts`,
  `data/snapshots/<label>/segments.geojson`) never queries Postgres for anything —
  it only knows the geojson snapshot's own identifiers. Keying these tables to match
  avoids a fragile join between two separate id systems in a 1-second-tick hot loop.
  `route_id` is carried as plain text for readability/filtering only, not a FK.
- **Not a live TimescaleDB continuous aggregate — a batch script**
  (`services/ml-service/train/refresh_stats.py`), re-run against the simulator's
  backfill corpus. `consumer.ts` doesn't persist raw `gps_pings`/`stop_events` to
  Postgres (a separate, still-open gap — see §7.3), so there's no live traffic to
  continuously aggregate from yet; that's the actual reason TimescaleDB stayed out
  of scope here, not `agg_window`/`hour_bucket` bucketing being unimportant.
- **`dow` is schema-complete but populated as `-1`** ("any day") for every row: at
  the simulator's ~4 trips/route/day, a (segment, dow, hour) cell over even a 30-day
  window gets roughly 1-3 samples — too sparse to be a real per-weekday signal
  rather than noise (the same finding `train/dataset.py` already made for the
  offline training pipeline, which drops `dow` from its own bucket key for the same
  reason). Consumers (`stream-processor/statsStore.ts`) look up the real `dow`
  first, falling back to `-1` — real per-dow data can slot in later with no code
  change on either side.

First real run against the full 90-day/103-route corpus: 15,639 `segment_travel_stats`
rows (94.5% of the realistically populatable (segment, hour, window) cells within the
6am-10pm service window) and 559 `stop_dwell_stats` rows, spanning 33 distinct real
stop ids — not a bug, matches `services/geo-ingest/README.md`'s already-documented
finding that only ~30 of the tricity's real OSM stop nodes actually get matched to a
route, shared across all 103 directions.

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
- **Self-host OSRM** in Docker for the enrichment pass — done, `docker-compose.yml`'s
  `osrm` service serves a pre-built tricity-bbox graph (`infra/docker/osrm/build.sh`
  reproduces it from a fresh Overpass extract). The public demo server is rate-limited
  and explicitly not for batch use, so `OSRM_URL` defaults to the self-hosted instance
  now; it's still available as a manual fallback.
- **Idempotent by `osm_node_id` / `osm_relation_id`** so re-running updates rather than
  duplicates.
- **Validation gate** — reject a route if the polyline is discontinuous, if stop
  projections are non-monotonic along the line, or if any stop is >150 m from its
  projection. Bad geometry silently destroys ETA accuracy, so it fails loudly at ingest.
- **Query nodes *and* ways.** Bus stops are not consistently mapped as nodes —
  platforms and station compounds are frequently drawn as ways, and Overpass returns
  those with a `center` rather than inline `lat`/`lon`. A node-only query drops them
  silently (this was a real bug; see geo-ingest's README). `osm_node_id` stays the
  stop idempotency key, so ingest now fails loudly if an id appears in both the node
  and way namespace rather than merging two distinct stops.
- **Some corridors have no OSM stops at all**, and no query change recovers them —
  route 8's final 7.09 km into Mohali (35% of the line) has zero stop features within
  150 m. That gap is a *data* limit, closed only by a Google Places key or a real
  operator timetable (Path B), never by synthesizing coordinates.

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

`consumer.ts` still map-matches per ping rather than batching into a 1-second window
across all active buses (item 2 below) — but ETA scoring (item 3) is no longer part
of that per-ping path. What IS built, replacing the earlier `mapMatch.ts` stub:

1. **Real map-matching** (`routeStore.ts` + `geo.ts` + `mapMatch.ts`) — loads the
   geo-ingest snapshot (`data/snapshots/<label>/{routes,stops,segments}.geojson`,
   real OSM geometry + real OSRM segment baselines) into memory at process start,
   and projects each raw fix onto the bus's real route line — the in-process,
   pre-Docker equivalent of the PostGIS `ST_LineLocatePoint` design below. Verified
   against the real Mohali-tricity snapshot: a synthetic ~20m GPS offset round-tripped
   to a computed offset of 20.8m.
2. Batch map-match via PostGIS, once Postgres/PostGIS is actually running — not yet
   built; today's version calls `mapMatch()` per ping, in-process, no DB round-trip.
3. **One batched call to `/eta/predict-batch` per second, scoring every live bus —
   built** (`etaScoringLoop.ts`, started from `consumer.ts`'s `main()`). Verified live
   against the real simulator: 3 concurrent buses, one `POST /eta/predict-batch` per
   second returning 200, cumulative per-stop ETAs increasing monotonically, real stop
   names resolved where OSM has them. `etaClient.ts`'s old per-ping `/eta/predict`
   call (and its placeholder features) is deleted, not just unused.

   Feature quality: `segment_avg_speed_7d/30d` and `upcoming_stop_dwell_prior_sec`
   now read real rolling stats from §3.3's `segment_travel_stats`/`stop_dwell_stats`
   (`statsStore.ts`, loaded into memory at startup and reloaded every 5 min — a
   1-second-tick hot loop querying Postgres per bus per tick would add real load
   for no benefit, since these tables only change when `refresh_stats.py` is
   re-run). Verified against Postgres directly: a known cell
   (`r16490723`, segment 0, hour 8, 30d window) returned `49.335205` km/h through
   `statsStore.getSegmentStat`, matching the DB row exactly; an out-of-service-hours
   lookup (3am) correctly returned `null`. `live_traffic_factor` is a real live
   signal (this tick's observed speed ÷ the current segment's baseline, clamped to
   [0.2, 3.0]). `current_delay_sec` still stays `0` — there's no per-trip schedule
   to measure delay against (buses run on randomized headways, not a fixed
   timetable) — see `etaScoringLoop.ts`'s module docstring for the full accounting.

   What's still a real gap: these tables are populated from the *offline backfill
   corpus*, not live traffic — `consumer.ts` doesn't persist raw `gps_pings`/
   `stop_events` to Postgres, so there's nothing live to aggregate from yet. A
   miss (no row for a given segment/hour/window) falls back to the OSRM baseline,
   logged via `statsStore`'s `lookupCounts` (`etaScoringLoop.ts` reports the
   hit/miss rate once a minute) rather than silently degrading unnoticed.
4. Pipelined Redis writes (`bus:{id}:position` now also carries `directionId`,
   `distAlongRouteM`, `speedMps`, `nextStopId/Name` — the state the degradation
   ladder below needs) plus an `active-buses` Set the ladder's watchdog scans.
5. One Kafka produce per ping (not yet batched) to `bus-state-updates`, tagged
   `confidenceTier: 'live'`, now carrying whatever `upcomingStops` the batch scorer
   last computed (best-effort, up to one tick stale between real pings) — plus a
   second produce per bus from the batch loop itself once a second, so the passenger
   UI's per-stop ETAs refresh even between GPS pings (docs §6.4: "the passenger UI
   shows the next three stops"). Both paths preserve the REAL last-ping `updatedAt`,
   never the scoring tick's own clock, so the degradation ladder's staleness math
   (§7.4) stays honest regardless of which path produced a given message.

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
| **0. Unblock** | ✅ Docker Desktop + Flutter SDK installed; `docker compose up` green (postgres/redis/redpanda/emqx/osrm all healthy); self-hosted OSRM serving the tricity bbox | — |
| **1. Real data** | ✅ `geo-ingest` run end-to-end → 100 real CTU route directions with stops/segments/OSRM baselines, GeoJSON/GTFS snapshot committed. `db/migrations/` (plain PostGIS, no TimescaleDB — MVP scale doesn't need hypertables) creates the full §3 schema; `persist.py` now does real route/stop/segment upserts against it (idempotent by `osm_relation_id`/`osm_node_id`, §4.2), verified against a synthetic fixture exercising every write path including the `ST_LineLocatePoint` stop-projection. Not yet re-verified against a full live 100-route Overpass run — that's the next thing to actually do, not a design gap. | 0 |
| **2. Safety-net MVP** | ✅ Live end-to-end wiring verified: `simulator --mode=live` → EMQX → `consumer.ts` (real map-match + naive-baseline ETA from `ml-service` + Redis) → Redpanda → `gateway.ts` (consumer group lag 0) → Socket.IO. `apps/admin-dashboard`'s `LiveFleetMap.tsx` now subscribes for real (`useFleetSocket` + `FleetMap`, MapLibre, a new `admin:fleet` broadcast room in `gateway.ts`) — backend confirmed serving it live traffic (Kafka lag 0, Redis position keys populated) while the page was up. The rendered "dot on the map" hasn't been eyeballed by a human yet (no browser automation available in this environment) — everything server-side of the browser is verified live; the pixels aren't. | 1 |
| **3. Training corpus** | `simulator --mode=backfill` built and verified (CSV output, correct schema) — small trial runs only so far (days=2, a few routes); the full `--days=90` across all 100 routes hasn't been run (compute time, and calibration fit vs published timetables per §5.4 still needs real timetable data to compare against). | 1 |
| **4. ETA model** | ✅ Trained and live. `app/features.py` (shared train/serve contract), `train/dataset.py` + `train/train_eta.py` (LightGBM, §5.4 time-based split, ONNX export) trained on the full 90-day/103-route corpus: per-segment MAE 5.8s vs naive baseline 49.4s (88.3% improvement), horizon-bucketed MAE well under the §6.2 target (<2min within a 10-min horizon) at every bucket including 10min+ (21.2s) — see `artifacts/metrics.json`. `/eta/predict-batch` is live and wired into `stream-processor` (§7.3 item 3) — `etaScoringLoop.ts` scores every live bus once a second. §3.3's `segment_travel_stats`/`stop_dwell_stats` are now built and wired in too (`refresh_stats.py`, `statsStore.ts`) — live features are real rolling stats where a bucket exists, OSRM-baseline fallback where it doesn't, not placeholders. Remaining gap, honestly: those tables are populated from the offline backfill corpus, not live traffic — `consumer.ts` still doesn't persist real-time `gps_pings`/`stop_events` to Postgres, so there's no live signal to aggregate from yet. | 3 |
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
4. ~~**`react-router` 7.18.2** carries a high-severity CSRF advisory~~ — **resolved.**
   `apps/admin-dashboard` was on `react-router-dom@7.18.2`, inside the
   `>=7.12.0 <8.3.0` vulnerable range for
   [GHSA-qwww-vcr4-c8h2](https://github.com/advisories/GHSA-qwww-vcr4-c8h2).
   `react-router-dom` is discontinued as of v8 (folded into `react-router` /
   `react-router/dom`), so rather than downgrade to 7.11.0, the dependency was
   swapped to `react-router@^8.3.0` — the first patched version — with two import
   updates (`App.tsx`, `Layout.tsx`; this app only uses `BrowserRouter`, `Routes`,
   `Route`, `NavLink`, `Outlet`, all re-exported from `react-router`'s main entry,
   so `react-router/dom` wasn't needed). `npm audit` is clean.

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
