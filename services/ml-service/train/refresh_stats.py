"""Populates segment_travel_stats and stop_dwell_stats (db/migrations/0003_derived_stats.sql,
docs/IMPLEMENTATION_ARCHITECTURE.md §3.3) from either the simulator's offline
backfill corpus or Postgres's real, live stop_events (stream-processor's
pgPersist.ts).

This is a BATCH refresh either way, not a live continuous aggregate — even
`--source live` is a one-shot snapshot of whatever real stop_events exist right
now, re-run on demand, not a standing TimescaleDB aggregate.

Usage:
    python -m train.refresh_stats --label mohali-tricity                  # offline backfill (default)
    python -m train.refresh_stats --label mohali-tricity --source live    # real Postgres traffic

Both sources upsert into the SAME tables via ON CONFLICT — a row this run
doesn't touch (e.g. a (segment, hour) bucket `--source live` has no real traffic
for yet) is left as whatever a previous `--source backfill` run wrote, not wiped.
So running `--source live` early, before much real traffic has accumulated, is
safe: it can only refine buckets it actually has data for, never blank out the
rest. Check `sample_count` in Postgres (or the row counts this script logs)
before trusting a `--source live` run's numbers over the backfill-derived ones —
a handful of real trips is not the same statistical weight as the 90-day corpus.

`--database-url` defaults to $DATABASE_URL (the same variable every other service
in this repo uses).

Keying and dow, read before changing: see 0003_derived_stats.sql's header comment.
Short version — these tables are keyed by (direction_id, sequence) / stop's real
osm_node_id, matching what stream-processor's routeStore.ts already uses, not
route_segments.id/stops.id. `dow` is written as -1 ("any day") for every row: at
4 trips/route/day, a (segment, dow, hour) cell has too few samples over even a
30-day window to be a real per-weekday signal rather than noise (same finding as
build_dataset's segment_avg_speed_7d/30d, which drops dow from its bucket key for
the same reason). Consumers should look up the real dow first and fall back to -1.
"""
from __future__ import annotations

import argparse
import logging
import os
import sys
from datetime import timedelta
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from train.dataset import (  # noqa: E402
    enrich_stop_events,
    load_live_stop_events,
    load_segments,
    load_stop_events,
    traversal_durations,
)

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("refresh_stats")

ANY_DOW = -1


def _segment_stats(seg_durations: pd.DataFrame, window_label: str) -> pd.DataFrame:
    if seg_durations.empty:
        return pd.DataFrame(columns=[
            "direction_id", "sequence", "route_id", "hour_bucket",
            "avg_speed_kmh", "p50_duration_sec", "p85_duration_sec", "sample_count",
        ])

    def agg(g: pd.DataFrame) -> pd.Series:
        return pd.Series({
            "avg_speed_kmh": g["speed_mps"].mean() * 3.6,
            "p50_duration_sec": np.percentile(g["duration_sec"], 50),
            "p85_duration_sec": np.percentile(g["duration_sec"], 85),
            "sample_count": len(g),
        })

    out = (
        seg_durations.groupby(["direction_id", "sequence", "route_id", "hour"], as_index=False)
        .apply(agg, include_groups=False)
        .rename(columns={"hour": "hour_bucket"})
    )
    out["agg_window"] = window_label
    return out


def _dwell_stats(events: pd.DataFrame) -> pd.DataFrame:
    if events.empty:
        return pd.DataFrame(columns=[
            "stop_osm_node_id", "hour_bucket", "p50_dwell_sec", "avg_boarding", "avg_alighting", "sample_count",
        ])

    e = events.copy()
    e["hour"] = e["arrived_dt"].dt.hour

    def agg(g: pd.DataFrame) -> pd.Series:
        return pd.Series({
            "p50_dwell_sec": np.percentile(g["dwell_sec"].dropna(), 50) if g["dwell_sec"].notna().any() else 0.0,
            "avg_boarding": g["boarding_count"].mean(),
            "avg_alighting": g["alighting_count"].mean(),
            "sample_count": len(g),
        })

    return (
        e.groupby(["stop_osm_node_id", "hour"], as_index=False)
        .apply(agg, include_groups=False)
        .rename(columns={"hour": "hour_bucket"})
    )


def _upsert_segment_stats(conn, rows: pd.DataFrame) -> None:
    with conn.cursor() as cur:
        for r in rows.itertuples(index=False):
            cur.execute(
                """
                INSERT INTO segment_travel_stats
                    (direction_id, sequence, route_id, dow, hour_bucket, agg_window,
                     avg_speed_kmh, p50_duration_sec, p85_duration_sec, sample_count, refreshed_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, now())
                ON CONFLICT (direction_id, sequence, dow, hour_bucket, agg_window)
                DO UPDATE SET
                    route_id = EXCLUDED.route_id,
                    avg_speed_kmh = EXCLUDED.avg_speed_kmh,
                    p50_duration_sec = EXCLUDED.p50_duration_sec,
                    p85_duration_sec = EXCLUDED.p85_duration_sec,
                    sample_count = EXCLUDED.sample_count,
                    refreshed_at = now()
                """,
                (
                    r.direction_id, int(r.sequence), r.route_id, ANY_DOW, int(r.hour_bucket), r.agg_window,
                    float(r.avg_speed_kmh), float(r.p50_duration_sec), float(r.p85_duration_sec), int(r.sample_count),
                ),
            )


def _upsert_dwell_stats(conn, rows: pd.DataFrame) -> None:
    with conn.cursor() as cur:
        for r in rows.itertuples(index=False):
            cur.execute(
                """
                INSERT INTO stop_dwell_stats
                    (stop_osm_node_id, dow, hour_bucket, p50_dwell_sec, avg_boarding, avg_alighting,
                     sample_count, refreshed_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, now())
                ON CONFLICT (stop_osm_node_id, dow, hour_bucket)
                DO UPDATE SET
                    p50_dwell_sec = EXCLUDED.p50_dwell_sec,
                    avg_boarding = EXCLUDED.avg_boarding,
                    avg_alighting = EXCLUDED.avg_alighting,
                    sample_count = EXCLUDED.sample_count,
                    refreshed_at = now()
                """,
                (
                    int(r.stop_osm_node_id), ANY_DOW, int(r.hour_bucket),
                    float(r.p50_dwell_sec), float(r.avg_boarding), float(r.avg_alighting), int(r.sample_count),
                ),
            )


def main() -> None:
    parser = argparse.ArgumentParser(description="Refresh segment_travel_stats / stop_dwell_stats")
    parser.add_argument("--label", default="mohali-tricity")
    parser.add_argument("--database-url", default=os.environ.get("DATABASE_URL"))
    parser.add_argument(
        "--source", choices=["backfill", "live"], default="backfill",
        help="backfill = offline simulator corpus (default); live = real Postgres stop_events",
    )
    args = parser.parse_args()

    if not args.database_url:
        logger.error("no --database-url given and DATABASE_URL is not set")
        sys.exit(1)

    segments = load_segments(args.label)
    if args.source == "live":
        raw_events = load_live_stop_events(args.database_url, args.label)
        source_desc = f"Postgres stop_events (city={args.label!r})"
    else:
        raw_events = load_stop_events(args.label)
        source_desc = f"data/backfill/{args.label}/stop_events.csv"

    if raw_events.empty:
        if args.source == "live":
            # Not an error: early on (or right after a truncate), there simply
            # isn't real traffic yet. Existing backfill-derived rows are
            # untouched — see the module docstring's upsert-is-additive note.
            logger.info("no rows in %s yet — nothing to add this run", source_desc)
            return
        logger.error("no rows in %s — nothing to write", source_desc)
        sys.exit(1)

    events = enrich_stop_events(raw_events)

    all_durations = traversal_durations(events, segments)
    if all_durations.empty:
        if args.source == "live":
            # Not an error: early on (or right after a truncate), there simply
            # isn't real traffic yet. Existing backfill-derived rows are
            # untouched — see the module docstring's upsert-is-additive note.
            logger.info("no live segment traversals in %s yet — nothing to add this run", source_desc)
            return
        logger.error("no segment traversals reconstructed from %s — nothing to write", source_desc)
        sys.exit(1)

    max_date = all_durations["service_date"].max()
    window_30d = all_durations[all_durations["service_date"] >= max_date - timedelta(days=29)]
    window_7d = all_durations[all_durations["service_date"] >= max_date - timedelta(days=6)]

    seg_stats_30d = _segment_stats(window_30d, "30d")
    seg_stats_7d = _segment_stats(window_7d, "7d")
    seg_stats = pd.concat([seg_stats_30d, seg_stats_7d], ignore_index=True)

    if args.source == "live":
        # pgPersist.ts writes dwell_sec = NULL for every live row (map-matching
        # only observes one coarse "confirmed passed" instant per stop, not a
        # real arrival/departure pair — see its module docstring). Computing
        # _dwell_stats() against all-NULL dwell_sec would upsert a fabricated
        # "0 dwell" over every touched (stop, hour) cell, silently clobbering the
        # real backfill-derived dwell stats with a worse number. Skip entirely
        # until pgPersist.ts can observe real dwell (needs speed-based
        # near-stop-stationary detection, not built).
        dwell_stats = pd.DataFrame(columns=[
            "stop_osm_node_id", "hour_bucket", "p50_dwell_sec", "avg_boarding", "avg_alighting", "sample_count",
        ])
        logger.info("source=live: skipping stop_dwell_stats — dwell isn't observable from live data yet (see pgPersist.ts)")
    else:
        dwell_stats = _dwell_stats(events)

    n_directions = len(segments and {k[0] for k in segments})
    n_segments = len(segments)
    max_possible_seg_cells = n_segments * 24 * 2  # x2 for the two windows
    logger.info(
        "source=%s: computed %d segment_travel_stats rows (%d/%d possible (segment, hour, window) cells populated, "
        "%d directions, %d segments) and %d stop_dwell_stats rows over service days %s..%s",
        args.source, len(seg_stats), len(seg_stats), max_possible_seg_cells, n_directions, n_segments,
        len(dwell_stats), all_durations["service_date"].min(), max_date,
    )
    if args.source == "live" and (all_durations["service_date"].max() - all_durations["service_date"].min()).days < 7:
        logger.warning(
            "live source spans less than 7 real days — this run's rows carry real but low sample_count; "
            "check Postgres before treating them as a replacement for the backfill-derived stats"
        )

    import psycopg

    with psycopg.connect(args.database_url) as conn:
        _upsert_segment_stats(conn, seg_stats)
        _upsert_dwell_stats(conn, dwell_stats)
        conn.commit()

    logger.info(
        "done — wrote %d segment_travel_stats rows, %d stop_dwell_stats rows (source=%s)",
        len(seg_stats), len(dwell_stats), args.source,
    )


if __name__ == "__main__":
    main()
