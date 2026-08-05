"""CLI entrypoint for the GPS simulator.

    # Live mode — publishes to MQTT for the real pipeline to consume
    # (needs Docker/EMQX running)
    python -m app.main --mode live --buses 5 --speed-multiplier 1.0

    # Backfill mode — writes a training corpus to data/backfill/<label>/
    python -m app.main --mode backfill --days 7 --trips-per-day 4

See docs/IMPLEMENTATION_ARCHITECTURE.md §5 for the full design, and
services/simulator/README.md for verification results against the real
mohali-tricity snapshot.
"""
from __future__ import annotations

import argparse
import asyncio
import logging
from datetime import datetime
from zoneinfo import ZoneInfo

from app.backfill_writer import generate_backfill
from app.live_publisher import run_fleet
from app.snapshot_loader import load_snapshot

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("simulator")

IST = ZoneInfo("Asia/Kolkata")


def main() -> None:
    parser = argparse.ArgumentParser(description="SetuTrack GPS simulator")
    parser.add_argument("--label", default="mohali-tricity", help="geo-ingest snapshot to simulate against")
    parser.add_argument("--mode", choices=["live", "backfill"], required=True)
    parser.add_argument("--seed", type=int, default=None)

    # live mode
    parser.add_argument("--buses", type=int, default=5, help="[live] number of concurrent simulated buses")
    parser.add_argument(
        "--speed-multiplier", type=float, default=1.0,
        help="[live] 1.0 = real time; e.g. 60 = 1 simulated hour per real minute (for demos, use 1.0)",
    )
    parser.add_argument("--start-hour", type=int, default=None, help="[live] hour (IST) to start trips at; default now")

    # backfill mode
    parser.add_argument("--days", type=int, default=7, help="[backfill] number of simulated service days")
    parser.add_argument("--trips-per-day", type=int, default=4, help="[backfill] trips per route per day")
    parser.add_argument(
        "--routes-limit", type=int, default=None,
        help="[backfill] only simulate the first N routes (for a quick trial run — omit for all)",
    )

    args = parser.parse_args()
    routes = load_snapshot(args.label)
    logger.info("loaded %d route directions from snapshot %r", len(routes), args.label)

    if args.mode == "live":
        now = datetime.now(IST)
        start_dt = now.replace(hour=args.start_hour) if args.start_hour is not None else now
        asyncio.run(run_fleet(args.label, routes, args.buses, start_dt, args.speed_multiplier, args.seed))
    else:
        if args.routes_limit:
            routes = dict(list(routes.items())[: args.routes_limit])
        start_date = datetime.now(IST).replace(hour=0, minute=0, second=0, microsecond=0)
        stats = generate_backfill(args.label, routes, args.days, args.trips_per_day, start_date, args.seed)
        logger.info(
            "backfill done: %d trips, %d gps_pings, %d stop_events",
            stats.trips, stats.gps_ping_rows, stats.stop_event_rows,
        )


if __name__ == "__main__":
    main()
