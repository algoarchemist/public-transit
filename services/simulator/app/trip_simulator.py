"""Core generative model: walks one simulated bus trip along a REAL route
(geometry + stops + OSRM segment baselines from geo-ingest), yielding a fine-grained
(2s) tick stream. Both live-mode (MQTT) and backfill-mode (training corpus) consume
this same generator — only what they DO with each tick differs. See
docs/IMPLEMENTATION_ARCHITECTURE.md §5.2.

Timestamps use Asia/Kolkata explicitly (not the host machine's local timezone) since
the congestion/crowd models are keyed on real Punjab wall-clock hour/day-of-week —
running this simulator on a UTC server must not shift rush hour by 5.5 hours.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import numpy as np

from app.congestion import congestion_multiplier
from app.crowd_model import alighting_mu, boarding_lambda, dwell_seconds
from app.geometry import LonLat, jitter, point_at_distance
from app.snapshot_loader import SimRoute, SimStop

IST = ZoneInfo("Asia/Kolkata")

TICK_SEC = 2.0
GPS_NOISE_SIGMA_M = 8.0
MAX_SPEED_MPS = 25.0  # ~90 km/h safety clamp against tail-heavy lognormal noise draws

# Roughly one dropout episode per ~10-15 minutes of driving on average — enough to
# regularly exercise the degradation ladder's estimated/stale tiers without making
# every trip mostly dark.
DROPOUT_ENTER_PROB_PER_TICK = 0.0008
DROPOUT_DURATION_RANGE_SEC = (30.0, 180.0)

# How often to emit a "still parked" tick during a long dwell — see the dwell
# branch below for why this exists. Kept tight (well under the 60s heartbeat) since
# it only adds a handful of extra ticks per dwell (30-55s typical), not per cruising
# tick — cheap insurance against the heartbeat overshoot this was built to close.
PARKED_TICK_INTERVAL_SEC = 8.0


@dataclass
class StopEvent:
    stop: SimStop
    boarding: int
    alighting: int
    dwell_sec: float
    arrived_at_ms: int
    departed_at_ms: int


@dataclass
class SimTick:
    timestamp_ms: int
    true_dist_m: float
    sensed_lat: float
    sensed_lon: float
    speed_mps: float
    occupancy: int
    in_dropout: bool
    stop_event: StopEvent | None


def simulate_trip(route: SimRoute, start_dt: datetime, bus_capacity: int = 50, rng: np.random.Generator | None = None):
    """Yields SimTick objects for one full trip along `route`, starting at `start_dt`
    (must be tz-aware). `stop_event` is set on the single tick where a stop is
    reached; all other ticks are regular cruising samples.

    The trip runs from the first real stop to the last, NOT the full route
    polyline — a route's geometry commonly extends before/after the mapped stops
    (depot access roads, turning loops) with no real speed or footfall data, and
    with the first stop's real position along the polyline occasionally far from
    the polyline's own start (found during verification: one real route's first
    stop sits ~10km into a ~24km line). There's nothing to simulate meaningfully
    outside [first stop, last stop], so we don't.
    """
    if start_dt.tzinfo is None:
        start_dt = start_dt.replace(tzinfo=IST)
    rng = rng or np.random.default_rng()
    if len(route.stops) < 2:
        return

    dist_m = route.stops[0].dist_along_route_m
    occupancy = 0
    elapsed_sec = 0.0
    stop_idx = 0
    dropout_until_sec: float | None = None

    # Driven by stop_idx, not distance: a distance-based loop condition ends the
    # trip the instant `dist_m` reaches the last stop, before that stop's own
    # arrival/boarding/alighting/dwell is ever processed (found during
    # verification — a 5-stop route was yielding only 4 stop events). Looping
    # until every stop, including the last, has been handled fixes that.
    while stop_idx < len(route.stops):
        current_dt = start_dt + timedelta(seconds=elapsed_sec)
        hour, dow = current_dt.hour, current_dt.weekday()

        # Reached (or passed) the next real stop — a dwell event, not a cruising tick.
        if dist_m >= route.stops[stop_idx].dist_along_route_m:
            stop = route.stops[stop_idx]
            boarding = int(rng.poisson(boarding_lambda(stop.footfall_prior, hour, dow)))
            alighting = int(min(occupancy, rng.poisson(alighting_mu(occupancy, stop.footfall_prior, hour))))
            occupancy = max(0, min(bus_capacity, occupancy + boarding - alighting))
            dwell = dwell_seconds(boarding, alighting, rng)

            arrived_ms = int(current_dt.timestamp() * 1000)
            in_dropout = dropout_until_sec is not None and elapsed_sec < dropout_until_sec

            yield SimTick(
                timestamp_ms=arrived_ms,
                true_dist_m=dist_m,
                sensed_lat=stop.lat,
                sensed_lon=stop.lon,
                speed_mps=0.0,
                occupancy=occupancy,
                in_dropout=in_dropout,
                stop_event=StopEvent(
                    stop=stop,
                    boarding=boarding,
                    alighting=alighting,
                    dwell_sec=dwell,
                    arrived_at_ms=arrived_ms,
                    departed_at_ms=arrived_ms + int(dwell * 1000),
                ),
            )

            # A dwell is otherwise a single instantaneous time-jump with no
            # intermediate ticks — found during verification to let a gap between
            # transmitted pings occasionally stretch past the 60s heartbeat purely
            # because no tick existed at the 60s mark to fire it. A real phone keeps
            # sampling GPS while parked, so periodic "still here" ticks during any
            # dwell long enough to matter keep that heartbeat guarantee honest.
            parked_elapsed = PARKED_TICK_INTERVAL_SEC
            while parked_elapsed < dwell:
                parked_dt = current_dt + timedelta(seconds=parked_elapsed)
                parked_in_dropout = dropout_until_sec is not None and (elapsed_sec + parked_elapsed) < dropout_until_sec
                yield SimTick(
                    timestamp_ms=int(parked_dt.timestamp() * 1000),
                    true_dist_m=dist_m,
                    sensed_lat=stop.lat,
                    sensed_lon=stop.lon,
                    speed_mps=0.0,
                    occupancy=occupancy,
                    in_dropout=parked_in_dropout,
                    stop_event=None,
                )
                parked_elapsed += PARKED_TICK_INTERVAL_SEC

            elapsed_sec += dwell
            stop_idx += 1
            continue

        segment = route.segment_at_distance(dist_m)
        base_speed = segment.avg_speed_mps if segment and segment.avg_speed_mps else route.average_speed_mps
        multiplier = congestion_multiplier(hour, dow)
        noise = rng.lognormal(0, 0.15)
        speed_mps = min(MAX_SPEED_MPS, max(0.5, base_speed * multiplier * noise))

        # Dropout state machine — exercises the passenger-facing degradation ladder
        # (services/stream-processor/src/deadReckoning.ts) on the consuming end.
        in_dropout = dropout_until_sec is not None and elapsed_sec < dropout_until_sec
        if in_dropout and elapsed_sec >= (dropout_until_sec or 0):
            in_dropout = False
            dropout_until_sec = None
        if not in_dropout and rng.random() < DROPOUT_ENTER_PROB_PER_TICK:
            dropout_until_sec = elapsed_sec + rng.uniform(*DROPOUT_DURATION_RANGE_SEC)
            in_dropout = True

        # Clamp to the upcoming stop specifically (not just the trip's final stop) —
        # a real single tick's movement is always well under real stop spacing here,
        # but clamping to the immediate next stop is the robust choice regardless.
        dist_m = min(dist_m + speed_mps * TICK_SEC, route.stops[stop_idx].dist_along_route_m)
        elapsed_sec += TICK_SEC

        true_point = point_at_distance(route.geometry, dist_m)
        sensed_point = jitter(true_point, GPS_NOISE_SIGMA_M, rng)

        yield SimTick(
            timestamp_ms=int((start_dt + timedelta(seconds=elapsed_sec)).timestamp() * 1000),
            true_dist_m=dist_m,
            sensed_lat=sensed_point.lat,
            sensed_lon=sensed_point.lon,
            speed_mps=speed_mps,
            occupancy=occupancy,
            in_dropout=in_dropout,
            stop_event=None,
        )
