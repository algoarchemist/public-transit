"""Populates segment_travel_stats and stop_dwell_stats (db/migrations/0003_derived_stats.sql,
docs/IMPLEMENTATION_ARCHITECTURE.md §3.3) from the simulator's backfill corpus.

This is a BATCH refresh, not a live continuous aggregate — consumer.ts doesn't
persist raw gps_pings/stop_events to Postgres (that's a separate, still-open gap),
so there is no live traffic to continuously aggregate from. Re-run this after
regenerating data/backfill/<label>/ to refresh both tables.

Usage:
    python -m train.refresh_stats --label mohali-tricity

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

from train.dataset import enrich_stop_events, load_segments, load_stop_events, traversal_durations  # noqa: E402

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
    args = parser.parse_args()

    if not args.database_url:
        logger.error("no --database-url given and DATABASE_URL is not set")
        sys.exit(1)

    segments = load_segments(args.label)
    events = enrich_stop_events(load_stop_events(args.label))
    events["hour"] = events["departed_dt"].dt.hour

    all_durations = traversal_durations(events, segments)
    if all_durations.empty:
        logger.error("no segment traversals reconstructed from data/backfill/%s/stop_events.csv — nothing to write", args.label)
        sys.exit(1)

    max_date = all_durations["service_date"].max()
    window_30d = all_durations[all_durations["service_date"] >= max_date - timedelta(days=29)]
    window_7d = all_durations[all_durations["service_date"] >= max_date - timedelta(days=6)]

    seg_stats_30d = _segment_stats(window_30d, "30d")
    seg_stats_7d = _segment_stats(window_7d, "7d")
    seg_stats = pd.concat([seg_stats_30d, seg_stats_7d], ignore_index=True)
    dwell_stats = _dwell_stats(events)

    n_directions = len(segments and {k[0] for k in segments})
    n_segments = len(segments)
    max_possible_seg_cells = n_segments * 24 * 2  # x2 for the two windows
    logger.info(
        "computed %d segment_travel_stats rows (%d/%d possible (segment, hour, window) cells populated, "
        "%d directions, %d segments) and %d stop_dwell_stats rows over service days %s..%s",
        len(seg_stats), len(seg_stats), max_possible_seg_cells, n_directions, n_segments,
        len(dwell_stats), all_durations["service_date"].min(), max_date,
    )

    import psycopg

    with psycopg.connect(args.database_url) as conn:
        _upsert_segment_stats(conn, seg_stats)
        _upsert_dwell_stats(conn, dwell_stats)
        conn.commit()

    logger.info("done — wrote %d segment_travel_stats rows, %d stop_dwell_stats rows", len(seg_stats), len(dwell_stats))


if __name__ == "__main__":
    main()
