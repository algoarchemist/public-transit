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
from datetime import datetime, timezone, timedelta
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


def _load_segments(label: str) -> dict[tuple[str, int], SegmentInfo]:
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


def _load_stop_events(label: str) -> pd.DataFrame:
    path = REPO_ROOT / "data" / "backfill" / label / "stop_events.csv"
    df = pd.read_csv(path)
    df = df.sort_values(["trip_id", "sequence"]).reset_index(drop=True)
    return df


def _ist(ms: int) -> datetime:
    return datetime.fromtimestamp(ms / 1000, tz=IST)


def build_dataset(
    label: str = "mohali-tricity",
    train_days: int = 60,
    val_days: int = 15,
    test_days: int = 15,
) -> Dataset:
    segments = _load_segments(label)
    events = _load_stop_events(label)

    events["arrived_dt"] = events["arrived_at"].map(_ist)
    events["departed_dt"] = events["departed_at"].map(_ist)
    events["service_date"] = events["departed_dt"].dt.date

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
    seg_durations = _traversal_durations(train_events, segments)
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


def _traversal_durations(train_events: pd.DataFrame, segments: dict[tuple[str, int], SegmentInfo]) -> pd.DataFrame:
    """One row per completed segment traversal within the training window — used only
    to build the frozen historical-stats tables in pass 1, never as feature rows
    themselves (pass 2 rebuilds features for every split from scratch)."""
    out = []
    for trip_id, grp in train_events.groupby("trip_id", sort=False):
        grp = grp.sort_values("sequence")
        recs = grp.to_dict("records")
        direction_id = recs[0]["direction_id"] if recs else None
        for i in range(len(recs) - 1):
            seg = segments.get((direction_id, i))
            if seg is None:
                continue
            dep_i = recs[i]["departed_at"]
            arr_i1 = recs[i + 1]["arrived_at"]
            duration = (arr_i1 - dep_i) / 1000.0
            if duration <= 0:
                continue
            out.append({
                "direction_id": direction_id,
                "sequence": i,
                "hour": recs[i]["departed_dt"].hour,
                "service_date": recs[i]["service_date"],
                "duration_sec": duration,
                "speed_mps": seg.length_m / duration,
            })
    return pd.DataFrame(out)
