# SetuTrack — geo-ingest

Turns real OSM/OSRM/Google Maps data into the canonical route/stop/segment geometry
the rest of SetuTrack builds on — no hardcoded polylines, no invented stop
coordinates. See `docs/IMPLEMENTATION_ARCHITECTURE.md` §4 for the full design and
§11.1/§12 for why the target network ended up being the Chandigarh Tricity (CTU
routes around Mohali/Kharar/Zirakpur/Dera Bassi) rather than a small PRTC/PUNBUS city
— none of Bathinda/Patiala/Pathankot/Ludhiana/Jalandhar/Amritsar have OSM bus-route
relation coverage; CTU is the only real, dense, well-mapped bus network in Punjab.

## Setup

```
python -m venv .venv
source .venv/Scripts/activate   # .venv/bin/activate on macOS/Linux
pip install -r requirements.txt
cp .env.example .env            # GOOGLE_MAPS_API_KEY is optional, see below
```

## Running it

```
# Area-name mode — works when the target has a clean OSM admin boundary
python -m app.main --city Bathinda

# bbox mode — needed when the real network spans multiple admin boundaries and
# doesn't resolve as a single OSM area (this is what the tricity actually required)
python -m app.main --bbox 30.64,76.70,30.90,76.84 --label mohali-tricity
```

Output lands in `data/snapshots/<label>/` as GeoJSON (`routes.geojson`,
`stops.geojson`) and a minimal GTFS-static export (`routes.txt`, `stops.txt`,
`stop_times.txt`) — reproducible with no database required. It also attempts a
PostGIS write if `DATABASE_URL` is reachable, soft-failing (snapshot-only) if not.

## Pipeline stages (`app/`)

| Module | Stage | What it does |
|---|---|---|
| `overpass.py` | 1. Discover | City/bbox-scoped Overpass queries: route relations, stop nodes, POIs. Disk-cached, retried against the public instance's intermittent 406/504s. |
| `reconcile.py` | 2. Reconcile | Three real-data paths, tried in order — see below. |
| `enrich.py` | 3. Enrich | Segment baseline durations (Google Distance Matrix if configured, else OSRM), optional Google stop densification, OSM-POI footfall priors. |
| `persist.py` | 4. Persist | GeoJSON/GTFS snapshot (always) + PostGIS (best-effort). |
| `google_maps.py` | 3 (optional) | Places Nearby Search + Distance Matrix client. No-ops entirely if `GOOGLE_MAPS_API_KEY` is unset — **not yet live-tested**, no key was available when this was written. |
| `geometry.py` | shared | UTM-projected length/projection/substring/distance helpers. |
| `osrm.py` | shared | Free-flow routing/duration client (self-hosted via `docker compose up -d osrm`, tricity bbox — see `infra/docker/osrm/build.sh`). |

### Reconciliation paths, in the order `main._reconcile_one` tries them

1. **Path A (`build_route_from_relation`)** — the relation has explicit
   `stop`/`platform` member nodes in PTv2 style. Uses them directly, in relation order.
2. **Path A-hybrid (`build_route_with_inferred_stops`)** — the relation has real way
   geometry but *zero* stop members, which turned out to be true for **every one of
   the CTU relations checked** (100/110 reconciled this way in the tricity bbox run,
   10 skipped for having <2 real stop nodes near their geometry). Real standalone
   `bus_stop`/`platform` nodes near the route are projected onto the real stitched
   line and ordered by position — the geometry and the stop locations are both real;
   only the *pairing* of "these stops belong to this route" is inferred geometrically.
3. **Path B (`build_route_from_stop_sequence`)** — no usable relation at all. Needs a
   real, externally-sourced stop order (an operator timetable) passed in; this
   function will not invent one. Not currently wired into `main.py`'s automatic flow
   for that reason — it's a manual step once you have a real source.

All three raise `RouteValidationError` (not a silent bad result) if the geometry is
discontinuous or stops project non-monotonically along the line.

## Google Maps integration (optional, needs a key)

Set `GOOGLE_MAPS_API_KEY` in `.env` to unlock:
- **Stop densification** (`enrich.densify_stops_with_google`) — OSM only has 38
  tagged `bus_stop`/`platform` nodes in the tricity bbox (30 of them actually used),
  shared across 100 reconciled route directions — a median of 9 stops per route,
  well short of a real route's 15-30, and only ~36% of them carry a name in OSM.
  Google Places Nearby Search, sampled along each
  route's real geometry, finds real `bus_station`/`transit_station` places to fill
  that in.
- **Traffic-conditioned segment durations** (`enrich.enrich_segment_baselines`) —
  Google Distance Matrix's `duration_in_traffic` is a stronger simulator-calibration
  signal than OSRM's free-flow-only estimate (see
  `docs/IMPLEMENTATION_ARCHITECTURE.md` §5.4 on the calibration/honesty problem).

Both fall back cleanly to the OSRM/OSM path when the key is unset — nothing here is a
hard dependency. **This code has not been run against a real key** (none was
available while building it); before trusting it, get a key with Places API +
Distance Matrix API enabled and billing on, then re-run `python -m app.main` and spot
check `data/snapshots/<label>/stops.geojson` for the added stops.

## Known gaps

- Stop density stays thin without a Google Maps key (see above).
- bbox mode skips POI-based footfall priors (needs an area id for the current query
  shape) — `footfall_prior` stays 0 for bbox-mode routes until that's added.
- Path B has no automatic trigger; populate a real sourced stop list yourself and
  call `build_route_from_stop_sequence` directly if you need it for a specific route.
