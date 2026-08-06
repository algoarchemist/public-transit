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

## Serving-side gap: partially closed

`services/stream-processor/src/etaScoringLoop.ts` (docs §7.3 item 3) now calls
`/eta/predict-batch` once a second for every live bus, replacing the old
`etaClient.ts` per-ping `/eta/predict` call — that file is deleted. Feature quality
improved but is still bounded by what §3.3's aggregate tables would provide once
built:

- `live_traffic_factor` is now a real live signal (this tick's observed speed ÷ the
  current segment's OSRM baseline, clamped [0.2, 3.0]) instead of the old flat `1`.
- `segment_avg_speed_7d` and `segment_avg_speed_30d` both still read the segment's
  OSRM free-flow baseline (`routeStore`'s `avgSpeedMps`), not a genuine rolling
  historical average — `segment_travel_stats` doesn't exist yet (§3.3, MVP cut).
- `current_delay_sec` stays `0` (no per-trip schedule to measure delay against) and
  `upcoming_stop_dwell_prior_sec` stays a flat constant (no `stop_dwell_stats`
  table). `weather_bucket` stays `0` (nothing simulates or observes weather).

Net effect: this model is trained on genuine historical rolling aggregates and is
correct to be, but it will predict less sharply live than `metrics.json` suggests
until `segment_travel_stats`/`stop_dwell_stats` exist for real and `etaScoringLoop.ts`
reads from them instead of the OSRM baseline. That table is the next real blocker on
this specific gap, not a nice-to-have.

## Weather

`weather_bucket` is always `0` — nothing in `services/simulator` models weather, so
the feature has zero variance in this corpus and should show ~zero importance in
`metrics.json`. That's an honest reflection of what's simulated, not a bug to chase.
