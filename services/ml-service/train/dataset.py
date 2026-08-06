"""Turns the simulator's backfill corpus (data/backfill/<label>/stop_events.csv)
into a per-segment-traversal training table matching app.features.FEATURE_COLUMNS.

Design notes (read before changing the feature computations below):

Unit of prediction (docs §6.2): one row = one bus traversing one route_segment,
start to finish. `duration_sec` (the label) is the actual traversal time; a
multi-segment ETA is the caller's job — sum predicted segment durations plus
predicted dwells (see train_eta.py's horizon evaluation for exactly that sum).

Historical stats are frozen at the end of the *training* window (days
1..TRAIN_DAYS) and then reused unchanged for validation/test rows. This is not a
simplification for convenience — it's what a production system actually does (an
aggregate table is refreshed periodically from the past and scores whatever comes
next), and it's the only way to keep validation/test genuinely free of future
leakage under the docs §5.4 time-based split. Two consequences:
  - segment_avg_speed_7d/30d are not true rolling per-row windows; they are the
    training window's last-7-days and full-60-days averages respectively, looked up
    by (direction_id, segment sequence, hour-of-day bucket). Day-of-week is deliberately
    NOT part of the bucket key — at 4 trips/route/day, a same-weekday-only window has
    ~1 matching day per week, too sparse to average over.
  - `current_delay_sec` and `live_traffic_factor` are computed by walking each trip's
    OWN already-observed stops forward against those frozen historical expectations —
    exactly what a live system would do with its own trip-so-far, never using this
    trip's own not-yet-happened segments.

`live_traffic_factor` is the ratio of the immediately preceding segment's actual
speed to its historical expected speed — a momentum proxy ("how much slower than
usual was the bus a moment ago"), not the current segment's own speed (which isn't
observable before that segment happens; using it would leak the label). Defaults to
1.0 (neutral) for a trip's first segment, matching stream-processor's own
not-yet-real placeholder for "no info yet" (see app/features.py's docstring).

Every historical lookup has a documented fallback to a global or route-baseline
value for buckets with zero training-window samples, and never emits NaN.
"""
from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from datetime import timezone, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

logger = logging.getLogger("train.dataset")

REPO_ROOT = Path(__file__).resolve().parents[3]
IST = timezone(timedelta(hours=5, minutes=30))


@dataclass
class SegmentInfo:
    direction_id: str
    route_id: str
    sequence: int
    length_m: float
    baseline_sec: float | None

    @property
    def baseline_speed_mps(self) -> float:
        return self.length_m / self.baseline_sec if self.baseline_sec else 8.0


@dataclass
class Dataset:
    frame: pd.DataFrame  # one row per segment traversal, FEATURE_COLUMNS + label + split + keys
    train_days: int
    val_days: int
    test_days: int
    fallback_counts: dict[str, int]  # how often each historical lookup missed its bucket


def load_segments(label: str) -> dict[tuple[str, int], SegmentInfo]:
    path = REPO_ROOT / "data" / "snapshots" / label / "segments.geojson"
    fc = json.loads(path.read_text(encoding="utf-8"))
    out: dict[tuple[str, int], SegmentInfo] = {}
    for feat in fc["features"]:
        p = feat["properties"]
        key = (p["direction_id"], p["sequence"])
        out[key] = SegmentInfo(
            direction_id=p["direction_id"],
            route_id=p["route_id"],
            sequence=p["sequence"],
            length_m=p["length_m"],
            baseline_sec=p.get("baseline_sec"),
        )
    return out


def load_stop_events(label: str) -> pd.DataFrame:
    path = REPO_ROOT / "data" / "backfill" / label / "stop_events.csv"
    df = pd.read_csv(path)
    df = df.sort_values(["trip_id", "sequence"]).reset_index(drop=True)
    return df


def load_live_stop_events(database_url: str, label: str) -> pd.DataFrame:
    """Same shape as load_stop_events (trip_id, direction_id, route_id,
    stop_osm_node_id, sequence, arrived_at/departed_at as epoch ms, dwell_sec,
    boarding_count, alighting_count) — read from Postgres's real stop_events
    (docs §3.2) instead of the offline backfill CSV, so every downstream function
    (enrich_stop_events, traversal_durations, refresh_stats.py's aggregations)
    works unchanged regardless of source.

    `direction_id` is reconstructed as f"r{osm_relation_id}" — the same
    convention geo-ingest's persist.py uses (each direction is its own `routes`
    row, so `trips.route_id` already uniquely identifies a direction; there's no
    separate direction_id column in Postgres to read directly). Only real pings
    that stream-processor's pgPersist.ts has actually written populate this —
    see its module docstring for what is and isn't captured (notably: a route's
    final stop never gets an event this way, and departed_at/dwell_sec are
    always NULL — pgPersist.ts only observes one coarse "confirmed passed"
    instant per stop, not a real arrival/departure pair, so real dwell isn't
    derivable from live data yet; traversal_durations() below falls back to
    consecutive arrived_at deltas when departed_at is NULL).
    """
    import psycopg

    query = """
        SELECT
            se.trip_id,
            'r' || r.osm_relation_id AS direction_id,
            r.ref AS route_id,
            s.osm_node_id AS stop_osm_node_id,
            se.sequence,
            EXTRACT(EPOCH FROM se.arrived_at) * 1000 AS arrived_at,
            EXTRACT(EPOCH FROM se.departed_at) * 1000 AS departed_at,
            se.dwell_sec,
            se.boarding_count,
            se.alighting_count
        FROM stop_events se
        JOIN trips t ON t.id = se.trip_id
        JOIN routes r ON r.id = t.route_id
        JOIN stops s ON s.id = se.stop_id
        JOIN cities c ON c.id = r.city_id
        WHERE c.name = %(label)s
          AND r.osm_relation_id IS NOT NULL
          AND se.arrived_at IS NOT NULL
        ORDER BY se.trip_id, se.sequence
    """
    # Fetched via a plain cursor (not pd.read_sql_query) — psycopg3's connection
    # isn't a DBAPI2 object pandas has been tested against, and read_sql_query
    # warns accordingly even though it happens to work.
    with psycopg.connect(database_url) as conn, conn.cursor() as cur:
        cur.execute(query, {"label": label})
        columns = [c.name for c in cur.description]
        rows = cur.fetchall()
    df = pd.DataFrame(rows, columns=columns)
    if df.empty:
        return df
    df["arrived_at"] = df["arrived_at"].round().astype("int64")
    # pd.to_numeric first: psycopg returns SQL NULL as Python None, giving an
    # object-dtype column .round() can't handle directly (None has no
    # __round__). Coercing to numeric turns None into a real NaN, which the
    # nullable Int64 (capital I) dtype can then hold — departed_at is NULL for
    # every live row today (see docstring above); a plain int64 column can't.
    df["departed_at"] = pd.to_numeric(df["departed_at"], errors="coerce").round().astype("Int64")
    return df


def enrich_stop_events(events: pd.DataFrame) -> pd.DataFrame:
    """Adds IST-local arrived_dt/departed_dt/service_date columns to a raw
    stop_events frame (CSV-backfill or live-Postgres shape — see
    load_stop_events/load_live_stop_events). Shared by build_dataset (below) and
    train/refresh_stats.py so both compute hour/dow/service-date the same way.

    Vectorized pd.to_datetime, not a per-row .map — live data's departed_at is
    NULL for every row (pgPersist.ts only observes one confirmation instant per
    stop, not a real arrival/departure pair; see its module docstring), and NaN
    can't round-trip through a plain Python datetime constructor the way NaT
    does through pandas' own conversion. service_date prefers departed_dt,
    falling back to arrived_dt when NULL — same "prefer departure, fall back to
    arrival" pattern as traversal_durations() below, for the same reason: it
    keeps offline/training behavior byte-for-byte unchanged (departed_dt is
    always present there) while still producing a real date for live data.
    """
    events = events.copy()
    events["arrived_dt"] = pd.to_datetime(events["arrived_at"], unit="ms", utc=True).dt.tz_convert(IST)
    events["departed_dt"] = pd.to_datetime(events["departed_at"], unit="ms", utc=True).dt.tz_convert(IST)
    events["service_date"] = events["departed_dt"].fillna(events["arrived_dt"]).dt.date
    return events


def build_dataset(
    label: str = "mohali-tricity",
    train_days: int = 60,
    val_days: int = 15,
    test_days: int = 15,
) -> Dataset:
    segments = load_segments(label)
    events = enrich_stop_events(load_stop_events(label))

    all_dates = sorted(events["service_date"].unique())
    available_days = len(all_dates)
    requested_days = train_days + val_days + test_days
    if available_days < requested_days:
        # Smoke-test mode: scale the split down proportionally rather than fail, so
        # this can run against a partial in-progress backfill. A real training run
        # should pass the full 90/no-scaling split — see train_eta.py's --require-full-days.
        scale = available_days / requested_days
        train_days = max(1, int(train_days * scale))
        val_days = max(1, int(val_days * scale))
        test_days = max(1, available_days - train_days - val_days)
        logger.warning(
            "only %d service days available (%d requested) — scaled split to %d/%d/%d",
            available_days, requested_days, train_days, val_days, test_days,
        )

    train_dates = set(all_dates[:train_days])
    val_dates = set(all_dates[train_days:train_days + val_days])
    test_dates = set(all_dates[train_days + val_days:train_days + val_days + test_days])

    events["split"] = events["service_date"].map(
        lambda d: "train" if d in train_dates else "val" if d in val_dates else "test" if d in test_dates else None
    )
    events = events[events["split"].notna()].reset_index(drop=True)

    train_mask = events["split"] == "train"
    train_events = events[train_mask]

    # --- Pass 1: historical stats, frozen to the training window only ---
    global_dwell_median = float(train_events["dwell_sec"].median()) if len(train_events) else 15.0

    dwell_by_stop_hour = (
        train_events.assign(hour=train_events["arrived_dt"].dt.hour)
        .groupby(["stop_osm_node_id", "hour"])["dwell_sec"].median()
        .to_dict()
    )
    dwell_by_stop = train_events.groupby("stop_osm_node_id")["dwell_sec"].median().to_dict()

    # Segment traversal durations, joined against segments.geojson for (direction_id, sequence).
    train_events = train_events.copy()
    train_events["hour"] = train_events["departed_dt"].dt.hour
    # duration_sec computed per-trip below is needed for both the label AND these
    # aggregates, so pass 1 also builds the per-row traversal table for train rows.
    seg_durations = traversal_durations(train_events, segments)
    if not seg_durations.empty:
        recent_cutoff = max(train_dates) - timedelta(days=6) if train_dates else None
        speed_30d = (
            seg_durations.groupby(["direction_id", "sequence", "hour"])["speed_mps"].mean().to_dict()
        )
        recent = seg_durations[seg_durations["service_date"] >= recent_cutoff] if recent_cutoff else seg_durations
        speed_7d = recent.groupby(["direction_id", "sequence", "hour"])["speed_mps"].mean().to_dict()
        duration_by_seg_hour = (
            seg_durations.groupby(["direction_id", "sequence", "hour"])["duration_sec"].mean().to_dict()
        )
    else:
        speed_30d, speed_7d, duration_by_seg_hour = {}, {}, {}

    fallback_counts = {"speed_30d": 0, "speed_7d": 0, "dwell_prior": 0, "expected_duration": 0}

    def hist_speed(table: dict, direction_id: str, sequence: int, hour: int, seg: SegmentInfo) -> float:
        v = table.get((direction_id, sequence, hour))
        if v is None:
            fallback_counts["speed_30d" if table is speed_30d else "speed_7d"] += 1
            return seg.baseline_speed_mps
        return v

    def hist_dwell(stop_id: int, hour: int) -> float:
        v = dwell_by_stop_hour.get((stop_id, hour))
        if v is not None:
            return v
        v = dwell_by_stop.get(stop_id)
        if v is not None:
            return v
        fallback_counts["dwell_prior"] += 1
        return global_dwell_median

    def hist_expected_duration(direction_id: str, sequence: int, hour: int, seg: SegmentInfo) -> float:
        v = duration_by_seg_hour.get((direction_id, sequence, hour))
        if v is not None:
            return v
        fallback_counts["expected_duration"] += 1
        return seg.baseline_sec if seg.baseline_sec else seg.length_m / 8.0

    # --- Pass 2: per-trip feature rows for every split, using only the frozen stats above ---
    rows: list[dict] = []
    for trip_id, grp in events.groupby("trip_id", sort=False):
        grp = grp.sort_values("sequence")
        recs = grp.to_dict("records")
        if len(recs) < 2:
            continue
        direction_id = recs[0]["direction_id"]
        route_id = recs[0]["route_id"]
        split = recs[0]["split"]

        t_actual_ms = 0.0
        t_expected_ms = 0.0
        trip_start_ms = recs[0]["departed_at"]
        prev_actual_speed_mps: float | None = None
        prev_hist_speed_mps: float | None = None

        for i in range(len(recs) - 1):
            seg = segments.get((direction_id, i))
            if seg is None:
                continue
            dep_i = recs[i]["departed_at"]
            arr_i1 = recs[i + 1]["arrived_at"]
            dep_i1 = recs[i + 1]["departed_at"]
            hour_dep_i = recs[i]["departed_dt"].hour
            dow_dep_i = recs[i]["departed_dt"].weekday()
            hour_arr_i1 = recs[i + 1]["arrived_dt"].hour
            upcoming_stop_id = recs[i + 1]["stop_osm_node_id"]

            actual_duration = (arr_i1 - dep_i) / 1000.0
            if actual_duration <= 0:
                continue  # simulator dropout edge case; not a valid traversal to train on

            live_traffic_factor = (
                1.0 if prev_hist_speed_mps is None or prev_hist_speed_mps == 0
                else prev_actual_speed_mps / prev_hist_speed_mps
            )

            rows.append({
                "trip_id": trip_id,
                "direction_id": direction_id,
                "route_id": route_id,
                "sequence": i,
                "split": split,
                "service_date": recs[i]["service_date"],
                "segment_avg_speed_7d": hist_speed(speed_7d, direction_id, i, hour_dep_i, seg),
                "segment_avg_speed_30d": hist_speed(speed_30d, direction_id, i, hour_dep_i, seg),
                "time_of_day_bucket": hour_dep_i,
                "day_of_week": dow_dep_i,
                "distance_to_stop_m": seg.length_m,
                "current_delay_sec": (t_actual_ms - t_expected_ms) / 1000.0,
                "weather_bucket": 0,  # no weather modeled anywhere in the simulator — real, documented gap
                "upcoming_stop_dwell_prior_sec": hist_dwell(upcoming_stop_id, hour_arr_i1),
                "live_traffic_factor": live_traffic_factor,
                "duration_sec": actual_duration,  # label
                # Ground truth, for train_eta.py's horizon evaluation only — NEVER a
                # feature (it's the real outcome, not a prior known before the stop).
                "actual_dwell_at_upcoming_stop_sec": recs[i + 1]["dwell_sec"],
            })

            expected_seg_dur = hist_expected_duration(direction_id, i, hour_dep_i, seg)
            expected_dwell = hist_dwell(upcoming_stop_id, hour_arr_i1)
            t_expected_ms += (expected_seg_dur + expected_dwell) * 1000
            t_actual_ms = dep_i1 - trip_start_ms

            prev_actual_speed_mps = seg.length_m / actual_duration
            prev_hist_speed_mps = hist_speed(speed_30d, direction_id, i, hour_dep_i, seg)

    frame = pd.DataFrame(rows)
    logger.info(
        "dataset: %d segment-traversal rows (%d train / %d val / %d test), fallbacks=%s",
        len(frame),
        (frame["split"] == "train").sum() if len(frame) else 0,
        (frame["split"] == "val").sum() if len(frame) else 0,
        (frame["split"] == "test").sum() if len(frame) else 0,
        fallback_counts,
    )
    return Dataset(frame=frame, train_days=train_days, val_days=val_days, test_days=test_days,
                    fallback_counts=fallback_counts)


def traversal_durations(
    events: pd.DataFrame, segments: dict[tuple[str, int], SegmentInfo]
) -> pd.DataFrame:
    """One row per completed segment traversal in `events` — real (direction_id,
    sequence, hour, service_date, duration_sec, speed_mps) ground truth. Used by
    build_dataset (below, over the training-window slice only, to build frozen
    historical-stats tables in pass 1 — never as feature rows themselves) and by
    train/refresh_stats.py (over the whole corpus, to populate segment_travel_stats).

    Segment identity comes from each row's actual `sequence` value, and a pair is
    only used if the next row's sequence is EXACTLY one more than the current
    row's — not from positional (0, 1, 2, ...) enumeration within the trip. The
    simulator's backfill corpus never has gaps (every stop always gets an event),
    so positional and real sequence agree there, but real live data
    (stream-processor's pgPersist.ts) can have gaps: if map-matching's nextStopId
    jumps two stops between pings, the middle stop's event is never recorded, and
    attributing "sequence i" to the i-th row seen would silently assign a
    multi-segment span to the wrong single segment. Gapped/out-of-order pairs are
    skipped, not guessed at.

    Duration AND hour both prefer `departed_at[i]`/`departed_dt[i]` (offline
    backfill: a real, separately observed departure instant) but fall back to
    `arrived_at[i]`/`arrived_dt[i]` when NULL (live data: pgPersist.ts only
    records one coarse "confirmed passed" instant per stop — see its module
    docstring — so there's no separate departure). This isn't just about this
    function: build_dataset()'s pass 2 looks up the SAME historical tables this
    function builds using its own departed_dt-based hour — if this function
    silently used a different reference point, the two would disagree on which
    hour bucket a segment belongs to, always slightly and rarely obviously.
    Preferring departed_at keeps offline/training behavior byte-for-byte
    unchanged (it's always present there) while still working for live data.
    """
    out = []
    skipped_gaps = 0
    for trip_id, grp in events.groupby("trip_id", sort=False):
        grp = grp.sort_values("sequence")
        recs = grp.to_dict("records")
        direction_id = recs[0]["direction_id"] if recs else None
        for i in range(len(recs) - 1):
            seq_i = recs[i]["sequence"]
            seq_i1 = recs[i + 1]["sequence"]
            if seq_i1 != seq_i + 1:
                skipped_gaps += 1
                continue
            seg = segments.get((direction_id, seq_i))
            if seg is None:
                continue
            dep_i = recs[i]["departed_at"]
            arr_i = recs[i]["arrived_at"]
            arr_i1 = recs[i + 1]["arrived_at"]
            has_departure = pd.notna(dep_i)
            start = dep_i if has_departure else arr_i
            duration = (arr_i1 - start) / 1000.0
            if duration <= 0:
                continue
            out.append({
                "direction_id": direction_id,
                "sequence": seq_i,
                "route_id": seg.route_id,
                "hour": (recs[i]["departed_dt"] if has_departure else recs[i]["arrived_dt"]).hour,
                "service_date": recs[i]["service_date"],
                "duration_sec": duration,
                "speed_mps": seg.length_m / duration,
            })
    if skipped_gaps:
        logger.warning("traversal_durations: skipped %d non-adjacent-sequence stop_events pair(s)", skipped_gaps)
    return pd.DataFrame(out)
