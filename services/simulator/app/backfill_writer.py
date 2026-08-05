"""Backfill mode: full-fidelity training corpus generation — the SAME
trip_simulator.simulate_trip core as live mode, but with none of live mode's
concerns (no divergence filtering, no wall-clock pacing, no MQTT). See
docs/IMPLEMENTATION_ARCHITECTURE.md §5.3 ("two sinks, one core") and §2.2.

Writes two CSVs matching the schema in docs §3.2:
  gps_pings.csv   — one row per non-dropout tick (a real blackout means no real
                    transmission ever happened, so there is genuinely nothing to
                    record for those ticks — unlike live mode's divergence
                    filtering, this is not a choice, it's what "no signal" means)
  stop_events.csv — one row per stop, regardless of dropout: arrival/departure/
                    dwell/boarding/alighting are captured via the conductor's
                    ticket-validation/tally channel (see solution doc §2.4), which
                    doesn't depend on GPS signal at all.

Also attempts a best-effort TimescaleDB write if DATABASE_URL is reachable,
soft-failing to CSV-only otherwise — same pattern as geo-ingest's persist.py.
"""
from __future__ import annotations

import csv
import logging
from dataclasses import dataclass
from datetime import datetime, timedelta

import numpy as np

from app.config import BACKFILL_DIR, settings
from app.snapshot_loader import SimRoute
from app.trip_simulator import simulate_trip

logger = logging.getLogger(__name__)

SERVICE_START_HOUR = 6
SERVICE_END_HOUR = 22


@dataclass
class BackfillStats:
    trips: int = 0
    gps_ping_rows: int = 0
    stop_event_rows: int = 0


def _trip_departure_times(day: datetime, trips_per_day: int, rng: np.random.Generator) -> list[datetime]:
    service_seconds = (SERVICE_END_HOUR - SERVICE_START_HOUR) * 3600
    offsets = sorted(rng.uniform(0, service_seconds, size=trips_per_day))
    base = day.replace(hour=SERVICE_START_HOUR, minute=0, second=0, microsecond=0)
    return [base + timedelta(seconds=float(o)) for o in offsets]


def generate_backfill(
    label: str,
    routes: dict[str, SimRoute],
    days: int,
    trips_per_day_per_route: int,
    start_date: datetime,
    seed: int | None = None,
) -> BackfillStats:
    out_dir = BACKFILL_DIR / label
    out_dir.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(seed)
    stats = BackfillStats()

    with open(out_dir / "gps_pings.csv", "w", newline="", encoding="utf-8") as pings_f, \
         open(out_dir / "stop_events.csv", "w", newline="", encoding="utf-8") as stops_f:
        pings_w = csv.writer(pings_f)
        pings_w.writerow(["trip_id", "direction_id", "route_id", "timestamp", "lat", "lon", "speed_kmh", "source"])

        stops_w = csv.writer(stops_f)
        stops_w.writerow([
            "trip_id", "direction_id", "route_id", "stop_osm_node_id", "stop_name", "sequence",
            "arrived_at", "departed_at", "dwell_sec", "boarding_count", "alighting_count",
        ])

        trip_seq = 0
        for day_offset in range(days):
            day = start_date + timedelta(days=day_offset)
            for direction_id, route in routes.items():
                if len(route.stops) < 2:
                    continue
                for departure in _trip_departure_times(day, trips_per_day_per_route, rng):
                    trip_id = f"{direction_id}-{trip_seq}"
                    trip_seq += 1
                    trip_rng = np.random.default_rng(rng.integers(0, 2**32 - 1))

                    for tick in simulate_trip(route, departure, rng=trip_rng):
                        if tick.stop_event:
                            se = tick.stop_event
                            stops_w.writerow([
                                trip_id, direction_id, route.route_id, se.stop.osm_node_id, se.stop.name,
                                route.stops.index(se.stop), se.arrived_at_ms, se.departed_at_ms,
                                round(se.dwell_sec, 1), se.boarding, se.alighting,
                            ])
                            stats.stop_event_rows += 1
                            continue

                        if tick.in_dropout:
                            continue  # a real blackout: no transmission occurred, nothing to record

                        pings_w.writerow([
                            trip_id, direction_id, route.route_id, tick.timestamp_ms,
                            round(tick.sensed_lat, 6), round(tick.sensed_lon, 6),
                            round(tick.speed_mps * 3.6, 2), "sim",
                        ])
                        stats.gps_ping_rows += 1

                    stats.trips += 1

    logger.info(
        "wrote backfill for %s: %d trips, %d gps_pings rows, %d stop_events rows -> %s",
        label, stats.trips, stats.gps_ping_rows, stats.stop_event_rows, out_dir,
    )
    _try_write_timescaledb(label, stats)
    return stats


def _try_write_timescaledb(label: str, stats: BackfillStats) -> bool:
    if not settings.database_url:
        logger.warning("DATABASE_URL not set — backfill is CSV-only for now (data/backfill/%s/)", label)
        return False
    try:
        import psycopg  # noqa: F401
    except ImportError:
        logger.warning("psycopg not installed — backfill is CSV-only for now")
        return False

    try:
        import psycopg

        with psycopg.connect(settings.database_url, connect_timeout=5):
            pass
        logger.warning(
            "DATABASE_URL is reachable but bulk gps_pings/stop_events COPY isn't wired up yet "
            "(needs db/migrations' schema, see docs/IMPLEMENTATION_ARCHITECTURE.md §3.2) — "
            "backfill stays CSV-only until then"
        )
        return False
    except Exception:
        logger.warning("PostGIS/TimescaleDB not reachable (Docker not up?) — CSV-only for now", exc_info=True)
        return False
