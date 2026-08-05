"""Live mode: paces the trip_simulator's tick stream in (scaled) wall-clock time
and publishes a divergence-triggered subset to MQTT, so the whole real pipeline
(MQTT -> stream-processor's consumer.ts -> Redis/Kafka -> gateway.ts -> Socket.IO)
runs exactly as it would in production, fed by simulated buses instead of real
VLTD hardware. See SIH25013_TrackMyRide_Solution.md §5.2 and
docs/IMPLEMENTATION_ARCHITECTURE.md §7.4.

The send decision mirrors apps/mobile-app/lib/driver/location_transmitter.dart
(constant-velocity prediction from the last SENT fix; publish only if the actual
position diverges >50m, or a 60s heartbeat has elapsed) — but computed in
distance-along-route space rather than lat/lon straight-line/bearing space. That's
a simulator-specific simplification: this process has ground-truth route position
available (the real phone doesn't), and the resulting send *pattern* — frequent
near stops/congestion, sparse on steady cruising — is what actually matters for
exercising the pipeline, not bit-for-bit identical trigger math. See
location_transmitter.dart's docstring for why client and server (and, here,
simulator) predictors are allowed to differ.

The 60s heartbeat is a soft, not hard, bound: trip_simulator's dwell events are
single time-jumps, so a long dwell straddling the 60s mark can push a real send
slightly past it (mitigated with periodic "parked" ticks during dwells — see
PARKED_TICK_INTERVAL_SEC in trip_simulator.py). Verified across all 100 real routes
in the mohali-tricity snapshot (7180 sends): worst dropout-free gap was 66.0s, ~9%
over target, never open-ended. Gaps during an actual simulated dropout are
unbounded by design (up to DROPOUT_DURATION_RANGE_SEC) — a real signal blackout
can't produce a ping no matter what.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from dataclasses import dataclass
from datetime import datetime

import numpy as np
import paho.mqtt.client as mqtt

from app.config import settings
from app.snapshot_loader import SimRoute
from app.trip_simulator import simulate_trip

logger = logging.getLogger(__name__)

DIVERGENCE_THRESHOLD_M = 50.0
HEARTBEAT_SEC = 60.0


@dataclass
class _LastSent:
    dist_along_route_m: float
    speed_mps: float
    timestamp_ms: int


class DivergenceFilter:
    def __init__(self) -> None:
        self._last: _LastSent | None = None

    def should_send(self, true_dist_m: float, timestamp_ms: int) -> bool:
        if self._last is None:
            return True
        elapsed_ms = timestamp_ms - self._last.timestamp_ms
        predicted_dist_m = self._last.dist_along_route_m + self._last.speed_mps * elapsed_ms / 1000
        divergence_m = abs(true_dist_m - predicted_dist_m)
        return divergence_m > DIVERGENCE_THRESHOLD_M or elapsed_ms >= HEARTBEAT_SEC * 1000

    def record_sent(self, dist_along_route_m: float, speed_mps: float, timestamp_ms: int) -> None:
        self._last = _LastSent(dist_along_route_m, speed_mps, timestamp_ms)


def _build_payload(bus_id: str, route: SimRoute, tick, direction_id: str) -> dict:
    return {
        "busId": bus_id,
        "routeId": route.route_id,
        "directionId": direction_id,
        "lat": tick.sensed_lat,
        "lon": tick.sensed_lon,
        "speedKmh": tick.speed_mps * 3.6,
        "occupancy": tick.occupancy,
        "timestamp": tick.timestamp_ms,
    }


async def run_bus(
    client: mqtt.Client,
    bus_id: str,
    route: SimRoute,
    start_dt: datetime,
    speed_multiplier: float,
    rng: np.random.Generator,
) -> None:
    """Runs one simulated bus's trip, sleeping in real time (scaled by
    `speed_multiplier`) between ticks and publishing the divergence-filtered subset.
    `in_dropout` ticks are never published — modeling a real GPS/cellular blackout on
    the bus itself, not a problem with this script's own connection to the broker.
    """
    dropout_filter = DivergenceFilter()
    sim_start_ms = int(start_dt.timestamp() * 1000)
    real_start_s = time.monotonic()
    sent_count = 0
    dark_count = 0

    for tick in simulate_trip(route, start_dt, rng=rng):
        sim_elapsed_s = (tick.timestamp_ms - sim_start_ms) / 1000
        target_real_s = real_start_s + sim_elapsed_s / speed_multiplier
        sleep_s = target_real_s - time.monotonic()
        if sleep_s > 0:
            await asyncio.sleep(sleep_s)

        if tick.in_dropout:
            dark_count += 1
            continue

        if not dropout_filter.should_send(tick.true_dist_m, tick.timestamp_ms):
            continue

        payload = _build_payload(bus_id, route, tick, route.direction_id)
        client.publish(f"gps/{bus_id}/ping", json.dumps(payload), qos=0)
        dropout_filter.record_sent(tick.true_dist_m, tick.speed_mps, tick.timestamp_ms)
        sent_count += 1

    logger.info("[%s] trip complete: %d pings sent, %d ticks dark", bus_id, sent_count, dark_count)


async def run_fleet(
    label: str,
    routes: dict[str, SimRoute],
    num_buses: int,
    start_dt: datetime,
    speed_multiplier: float,
    seed: int | None = None,
) -> None:
    client = mqtt.Client(
        callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
        client_id=f"setutrack-simulator-{label}",
        protocol=mqtt.MQTTv311,
    )
    client.connect(settings.mqtt_broker_host, settings.mqtt_broker_port)
    client.loop_start()

    direction_ids = list(routes.keys())
    rng = np.random.default_rng(seed)
    chosen = rng.choice(direction_ids, size=min(num_buses, len(direction_ids)), replace=False)

    tasks = [
        run_bus(
            client,
            bus_id=f"sim-bus-{i + 1}",
            route=routes[direction_id],
            start_dt=start_dt,
            speed_multiplier=speed_multiplier,
            rng=np.random.default_rng((seed or 0) + i + 1),
        )
        for i, direction_id in enumerate(chosen)
    ]
    logger.info("starting %d simulated buses (speed x%.1f)", len(tasks), speed_multiplier)
    await asyncio.gather(*tasks)

    client.loop_stop()
    client.disconnect()
