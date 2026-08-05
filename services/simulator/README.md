# SetuTrack — GPS simulator

Phase 2 of the build order (docs/IMPLEMENTATION_ARCHITECTURE.md §10): walks real
routes from the geo-ingest snapshot with speed/dwell/boarding drawn from
distributions calibrated against real OSRM segment baselines, and either publishes
to MQTT for the real pipeline to consume, or writes a training corpus. No
hardcoded geometry — same principle as geo-ingest.

## Setup

```
python -m venv .venv
source .venv/Scripts/activate   # .venv/bin/activate on macOS/Linux
pip install -r requirements.txt
cp .env.example .env
```

## Running it

```
# Live mode — needs Docker/EMQX running (docker compose up -d from repo root)
python -m app.main --mode live --buses 5 --speed-multiplier 1.0

# Backfill mode — training corpus, no broker needed
python -m app.main --mode backfill --days 7 --trips-per-day 4
```

`--speed-multiplier` scales live mode's wall-clock pacing (1.0 = real time; use
that for an actual demo). Backfill mode ignores it — trips are generated as fast
as possible and written to `data/backfill/<label>/{gps_pings,stop_events}.csv`.

## Architecture (`app/`)

| Module | Role |
|---|---|
| `snapshot_loader.py` | Loads the geo-ingest snapshot into the same shape stream-processor's `routeStore.ts` uses. Independent Python port, not a shared import — same reasoning as stream-processor's own independent `geo.ts`. |
| `geometry.py` | Haversine distance, point-at-distance, polyline projection, GPS jitter. |
| `congestion.py` | Time-of-day/day-of-week multiplier over a segment's real OSRM baseline speed. |
| `crowd_model.py` | Poisson boarding/alighting + dwell-time formula (docs §2.4/§5.2). |
| `trip_simulator.py` | The core: one `simulate_trip()` generator yielding a 2s tick stream, shared by both sinks. |
| `live_publisher.py` | Paces ticks in (scaled) wall-clock time, applies divergence-triggered filtering (mirrors `apps/mobile-app`'s transmitter), publishes to MQTT. |
| `backfill_writer.py` | Full-fidelity (no filtering) CSV writer for training data; best-effort TimescaleDB write if reachable. |

A trip runs from a route's **first real stop to its last** — not the full raw
polyline, which commonly extends into unstopped depot/access-road stretches with
no real speed data (see "Bugs found" below).

## Bugs found and fixed during verification

Building this surfaced three real bugs — two in this service, one shared with
`stream-processor` — none of which would have been obvious without actually
running the model against real data and checking the output:

1. **Bad fallback speed for the unmapped tail.** A route's segments only cover
   stop-to-stop; the stretch past the last stop (or, as bug 2 below made clear,
   *before* the first) has no baselined segment. Originally fell back to
   whichever segment happened to be last, which could be a short, locally slow
   one — one route simulated an 89-minute trip for a 21-minute OSRM free-flow
   baseline. Fixed by falling back to the route's real overall average speed
   (`SimRoute.average_speed_mps`) instead.

2. **Assuming a route's first stop sits at distance 0 along its polyline.**
   False whenever it isn't the polyline's own starting vertex — one real route's
   first stop sits **~10km into a ~24km line**, causing a single simulated
   "cruising tick" to teleport across that gap. Fixed by projecting every stop
   onto the route's real geometry (`project_onto_polyline`) instead of summing
   segment lengths from an assumed zero. **The identical bug existed in
   `services/stream-processor/src/routeStore.ts`** — masked there because the
   route used to verify it (2G) happened to have its first stop near the
   polyline's start (219.6m in, not exactly 0, but close enough to not trip the
   earlier, less thorough check). Fixed in both places; both independent
   implementations now agree exactly on every stop's real distance.

3. **The final stop never got its own arrival/boarding/dwell event.** The loop
   ended the instant `dist_m` reached the last stop, before entering the branch
   that processes it. Restructured to loop until every stop (including the last)
   is explicitly handled.

Also worth being upfront about (not bugs, just real limits of what's tested):

- The 60s heartbeat in live mode is a soft bound, not hard: verified across all
  100 real routes (7,180 sends) at a worst-case 66.0s when no dropout is involved
  — see `live_publisher.py`'s module docstring for why and by how much.
- `footfall_prior` is 0.0 for every stop (geo-ingest's bbox discovery mode skips
  POI-density enrichment — see its own README), so the crowd model can't yet
  differentiate busy vs. quiet stops. Written to use it correctly the moment
  geo-ingest populates it.
- The congestion multiplier is a hand-tuned placeholder, not calibrated against
  any real published timetable (docs §5.4's honesty problem) — flag this
  explicitly if presenting simulated ETAs as validated.
