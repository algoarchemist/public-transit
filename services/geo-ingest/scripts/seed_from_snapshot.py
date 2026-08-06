"""Load a committed geo-ingest snapshot into PostGIS, without re-running Overpass/OSRM.

Why this exists: `python -m app.main` writes both the snapshot *and* PostGIS, but the
snapshot is the committed artifact and the database is not — a fresh clone, a recreated
docker volume, or any machine that has never run the full ingest ends up with the §3
schema and zero rows. Everything that needs Postgres integer ids then fails: the
api-gateway's `POST /api/trips` cannot resolve a route, and stream-processor's
pgPersist.ts disables itself with "no cities row".

Re-running the full pipeline to fix that is minutes of Overpass/OSRM traffic to
reproduce bytes we already have on disk. This rehydrates `CanonicalRoute` objects from
the snapshot and hands them to the same `persist.try_write_postgis` the real pipeline
uses — same idempotent upserts, same code path, no second SQL dialect to keep in sync.

    python -m scripts.seed_from_snapshot --label mohali-tricity

Idempotent: safe to re-run (upserts keyed on osm_relation_id / osm_node_id, §4.2).
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.config import SNAPSHOT_DIR  # noqa: E402
from app.models import CanonicalRoute, CanonicalSegment, CanonicalStop, RouteSource  # noqa: E402
from app.persist import try_write_postgis  # noqa: E402

logger = logging.getLogger("seed_from_snapshot")


def _load(path: Path) -> list[dict]:
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)["features"]


def _group_by_direction(features: list[dict]) -> dict[str, list[dict]]:
    grouped: dict[str, list[dict]] = {}
    for feature in features:
        grouped.setdefault(feature["properties"]["direction_id"], []).append(feature)
    for group in grouped.values():
        group.sort(key=lambda f: f["properties"]["sequence"])
    return grouped


def rehydrate(label: str) -> list[CanonicalRoute]:
    """Snapshot GeoJSON -> the same CanonicalRoute objects stage 4 was handed.

    Note the deliberate asymmetry with the snapshot writer: stops are re-read per
    direction rather than deduplicated globally, because `route_stops.sequence` is
    per-route and the snapshot already stores one stop feature per (direction,
    sequence). `_upsert_stop` collapses them back to one `stops` row per
    `osm_node_id`, which is exactly what the schema wants.
    """
    snapshot_dir = SNAPSHOT_DIR / label
    if not snapshot_dir.is_dir():
        raise SystemExit(f"no snapshot at {snapshot_dir} — run `python -m app.main` first")

    stops_by_direction = _group_by_direction(_load(snapshot_dir / "stops.geojson"))
    segments_by_direction = _group_by_direction(_load(snapshot_dir / "segments.geojson"))

    routes: list[CanonicalRoute] = []
    for feature in _load(snapshot_dir / "routes.geojson"):
        props = feature["properties"]
        direction_id = props["direction_id"]

        stops = [
            CanonicalStop(
                osm_node_id=s["properties"]["osm_node_id"],
                name=s["properties"].get("name"),
                lon=s["geometry"]["coordinates"][0],
                lat=s["geometry"]["coordinates"][1],
                footfall_prior=s["properties"].get("footfall_prior") or 0.0,
            )
            for s in stops_by_direction.get(direction_id, [])
        ]
        stop_by_node_id = {stop.osm_node_id: stop for stop in stops}

        segments: list[CanonicalSegment] = []
        for s in segments_by_direction.get(direction_id, []):
            sp = s["properties"]
            from_stop = stop_by_node_id.get(sp["from_stop_id"])
            to_stop = stop_by_node_id.get(sp["to_stop_id"])
            if from_stop is None or to_stop is None:
                # A segment whose endpoints aren't in this direction's stop list would
                # violate route_segments' FKs. Skip loudly rather than write a broken row.
                logger.warning(
                    "%s segment %s references stops not in the snapshot's stop list — skipped",
                    direction_id,
                    sp["sequence"],
                )
                continue
            segments.append(
                CanonicalSegment(
                    sequence=sp["sequence"],
                    from_stop=from_stop,
                    to_stop=to_stop,
                    geom_lonlat=[tuple(c) for c in s["geometry"]["coordinates"]],
                    length_m=sp["length_m"],
                    osrm_baseline_sec=sp.get("baseline_sec"),
                    baseline_source=sp.get("baseline_source"),
                    dominant_highway_class=sp.get("dominant_highway_class"),
                )
            )

        routes.append(
            CanonicalRoute(
                ref=props.get("ref"),
                name=props.get("name"),
                operator=props.get("operator"),
                source=RouteSource(props["source"]),
                osm_relation_id=props.get("osm_relation_id"),
                stops=stops,
                segments=segments,
                geom_lonlat=[tuple(c) for c in feature["geometry"]["coordinates"]],
                length_m=props.get("length_m") or 0.0,
            )
        )
    return routes


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", default="mohali-tricity", help="snapshot directory under data/snapshots/")
    args = parser.parse_args()

    routes = rehydrate(args.label)
    logger.info(
        "rehydrated %d route directions (%d stop rows, %d segments) from the %s snapshot",
        len(routes),
        sum(len(r.stops) for r in routes),
        sum(len(r.segments) for r in routes),
        args.label,
    )

    if not try_write_postgis(args.label, routes):
        raise SystemExit("PostGIS write failed — is docker compose up, and DATABASE_URL correct?")
    logger.info("PostGIS seeded from the %s snapshot", args.label)


if __name__ == "__main__":
    main()
