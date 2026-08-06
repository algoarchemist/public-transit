# ETA model training (Phase 4, docs/IMPLEMENTATION_ARCHITECTURE.md §6.2)

Trains the segment-duration LightGBM regressor against the simulator's backfill
corpus, evaluates it against the §5.4 time-based split, and exports
`../artifacts/eta_model.onnx` + `../artifacts/metrics.json`.

## Running it

Needs `data/backfill/<label>/stop_events.csv` to exist — run the simulator's
backfill mode first (`services/simulator`, `--mode backfill --days 90`).

```
pip install -r ../requirements-train.txt   # pandas/scikit-learn/onnxmltools/skl2onnx — not in the serving image
python -m train.train_eta --label mohali-tricity
```

`--smoke --train-days N --val-days N --test-days N` lets this run against a partial,
still-generating corpus for iterating on the pipeline itself — it scales the split
down to whatever days actually exist. **Never report a `--smoke` metrics.json as a
real result**: with few training days, most (segment, hour) historical-stat buckets
have near-zero samples and fall back to route-baseline speed, which both inflates
the model's apparent improvement over the naive baseline and starves it of the
signal a full 60-day window provides. `historical_stat_fallback_counts` in
metrics.json is exactly this — check it's a small fraction of row count before
trusting the run.

## Refreshing segment_travel_stats / stop_dwell_stats

Separate from model training — this populates the Postgres tables
`stream-processor`'s live ETA scoring reads (docs §3.3, §7.3 item 3), from the same
backfill corpus:

```
python -m train.refresh_stats --label mohali-tricity
```

Needs `DATABASE_URL` set (or pass `--database-url`) and `psycopg[binary]` (in
`requirements-train.txt`). Re-run after regenerating the backfill corpus — see
`db/migrations/0003_derived_stats.sql`'s header comment and §3.3 for the full
design (keying, the `dow=-1` sentinel, why this is a batch script and not a
TimescaleDB continuous aggregate).

## What one training row is

One row = one bus's traversal of one `route_segment`, start to finish (docs §6.2:
"unit of prediction: per-segment traversal time"). `duration_sec` (the label) comes
directly from `stop_events.csv`: `next_stop.arrived_at - this_stop.departed_at`.
Multi-segment, per-stop ETAs are built by summing predictions across segments plus
predicted dwell — see `train_eta.py`'s `_horizon_eval` for the evaluation-time version
of that sum, and `app/models/eta.py`'s `predict_eta_batch` for the serving-time one.
Both use the identical dwell-charging convention (charged when leaving a stop, not
arriving) so offline evaluation and live serving agree.

## Feature contract

`app/features.py`'s `FEATURE_COLUMNS` is the single definition of the model's input
layout — `dataset.py` (training) and `app/models/eta.py` (serving) both import it
rather than each hardcoding a column order, per docs §6.1's train/serve-skew
principle.

Historical aggregates (`segment_avg_speed_7d/30d`, `upcoming_stop_dwell_prior_sec`,
the expected-duration table used for `current_delay_sec`) are frozen at the end of
the **training** window and reused unchanged for validation/test rows. This isn't a
shortcut — it's what a real system does (an aggregate table is refreshed
periodically from the past and scores whatever comes next), and it's the only way
to keep test rows genuinely free of future leakage under the time-based split.
`dataset.py`'s module docstring has the full reasoning, including why `7d`/`30d`
bucket by hour-of-day but deliberately not by day-of-week (too sparse at 4
trips/route/day — a same-weekday 7-day window has only ~1 matching day).

## Serving-side gap: mostly closed

`services/stream-processor/src/etaScoringLoop.ts` (docs §7.3 item 3) calls
`/eta/predict-batch` once a second for every live bus, replacing the old
`etaClient.ts` per-ping `/eta/predict` call — that file is deleted. §3.3's
`segment_travel_stats`/`stop_dwell_stats` tables are now built
(`db/migrations/0003_derived_stats.sql`) and populated by `train/refresh_stats.py`
(this directory — reuses `dataset.py`'s `load_segments`/`load_stop_events`/
`traversal_durations` rather than re-parsing the corpus a second way), loaded into
`stream-processor`'s `statsStore.ts` at startup:

- `live_traffic_factor` is a real live signal (this tick's observed speed ÷ the
  current segment's OSRM baseline, clamped [0.2, 3.0]).
- `segment_avg_speed_7d`/`segment_avg_speed_30d` and `upcoming_stop_dwell_prior_sec`
  now read real rolling stats from Postgres where a (segment, hour)/(stop, hour)
  bucket has one, falling back to the OSRM baseline / a flat constant where it
  doesn't (`statsStore`'s `lookupCounts`, logged once a minute by
  `etaScoringLoop.ts` — same honesty pattern as this directory's
  `historical_stat_fallback_counts`).
- `current_delay_sec` still stays `0` (no per-trip schedule to measure delay
  against — buses run on randomized headways, not a fixed timetable) and
  `weather_bucket` stays `0` (nothing simulates or observes weather).

`refresh_stats.py --source live` now reads real Postgres traffic instead of the
offline corpus (see "Refreshing segment_travel_stats / stop_dwell_stats" above).
Upserts only touch the cells they compute, so running it early — before much
real traffic exists — only refines a handful of buckets and leaves the 90-day
corpus-derived rest untouched.

**Why "mostly" rather than fully closed**: `--source live` only ever refreshes
`segment_travel_stats`, never `stop_dwell_stats`. `pgPersist.ts` (stream-processor)
only observes one coarse "confirmed passed this stop" instant per stop from
map-matching, not a real arrival/departure pair, so `dwell_sec` is honestly
`NULL` for every live row — computing dwell stats from it would upsert a
fabricated "0 dwell" over real backfill-derived numbers, so `refresh_stats.py`
skips that table entirely for `--source live` and logs why. Real dwell needs a
speed-based near-stop-stationary detector in `pgPersist.ts`, which isn't built.

**A real bug lived here until this was actually exercised against live data**:
an earlier version of `pgPersist.ts` reused its one confirmation instant as both
"departed the previous stop" and "arrived this stop," which made every derived
segment duration compute to exactly zero — invisible until `--source live` was
run against genuine `stop_events` and returned zero traversals. Root-caused by
comparing consecutive rows directly in Postgres (`departed_at[i]` and
`arrived_at[i+1]` were byte-identical) and fixed by recording only the one real
signal, with `dataset.py`'s `traversal_durations()` falling back to
consecutive-arrival deltas when `departed_at` is `NULL`. Re-verified afterward:
real, plausible per-segment speeds (2.5–77 km/h) from genuine live traversals.

## Weather

`weather_bucket` is always `0` — nothing in `services/simulator` models weather, so
the feature has zero variance in this corpus and should show ~zero importance in
`metrics.json`. That's an honest reflection of what's simulated, not a bug to chase.
