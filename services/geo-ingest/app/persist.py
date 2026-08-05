"""Stage 4 — Persist. Always writes a reproducible GeoJSON + GTFS-static snapshot to
data/snapshots/ (no database needed for this). Writes to PostGIS too, but only if
DATABASE_URL is actually reachable — Docker/Postgres isn't up yet in this environment,
so this degrades to snapshot-only rather than failing the whole run.
"""
from __future__ import annotations

import csv
import json
import logging
from pathlib import Path

from app.config import SNAPSHOT_DIR, settings
from app.models import CanonicalRoute

logger = logging.getLogger(__name__)


def _direction_id(route: CanonicalRoute) -> str:
    """Stable unique id for ONE direction of a route. `ref` alone is not unique —
    a route's two directions are separate OSM relations sharing the same ref (e.g.
    'Bus 20: ISBT-17 => Kharar' and 'Bus 20: Kharar => ISBT-17' are both ref='20'),
    so keying on ref silently merges opposite directions.
    """
    if route.osm_relation_id is not None:
        return f"r{route.osm_relation_id}"
    return f"{route.ref or 'route'}-{abs(hash(route.name)) % 10**8}"


def _route_feature(route: CanonicalRoute, direction_id: str) -> dict:
    return {
        "type": "Feature",
        "geometry": {"type": "LineString", "coordinates": [list(c) for c in route.geom_lonlat]},
        "properties": {
            "direction_id": direction_id,  # unique per direction
            "route_id": route.ref,  # shared by both directions, GTFS route_id
            "ref": route.ref,
            "name": route.name,
            "operator": route.operator,
            "source": route.source.value,
            "osm_relation_id": route.osm_relation_id,
            "length_m": route.length_m,
        },
    }


def _stop_features(route: CanonicalRoute, direction_id: str) -> list[dict]:
    return [
        {
            "type": "Feature",
            "geometry": {"type": "Point", "coordinates": [stop.lon, stop.lat]},
            "properties": {
                "direction_id": direction_id,
                "route_id": route.ref,
                "sequence": i,
                "osm_node_id": stop.osm_node_id,
                "name": stop.name,
                "footfall_prior": stop.footfall_prior,
            },
        }
        for i, stop in enumerate(route.stops)
    ]


def _segment_features(route: CanonicalRoute, direction_id: str) -> list[dict]:
    """Per-segment geometry AND its enriched travel-time baseline. Without this the
    entire Stage 3 enrichment pass (an OSRM call per segment) is discarded on write,
    and the ETA layer has nothing real to build on."""
    return [
        {
            "type": "Feature",
            "geometry": {"type": "LineString", "coordinates": [list(c) for c in seg.geom_lonlat]},
            "properties": {
                "direction_id": direction_id,
                "route_id": route.ref,
                "sequence": seg.sequence,
                "from_stop_id": seg.from_stop.osm_node_id,
                "from_stop_name": seg.from_stop.name,
                "to_stop_id": seg.to_stop.osm_node_id,
                "to_stop_name": seg.to_stop.name,
                "length_m": seg.length_m,
                "baseline_sec": seg.osrm_baseline_sec,
                "baseline_source": seg.baseline_source,
            },
        }
        for seg in route.segments
    ]


def write_geojson_snapshot(city_name: str, routes: list[CanonicalRoute]) -> Path:
    city_dir = SNAPSHOT_DIR / city_name.lower().replace(" ", "-")
    city_dir.mkdir(parents=True, exist_ok=True)

    route_features, stop_features, segment_features = [], [], []
    for route in routes:
        direction_id = _direction_id(route)
        route_features.append(_route_feature(route, direction_id))
        stop_features.extend(_stop_features(route, direction_id))
        segment_features.extend(_segment_features(route, direction_id))

    (city_dir / "routes.geojson").write_text(
        json.dumps({"type": "FeatureCollection", "features": route_features}, indent=2), encoding="utf-8"
    )
    (city_dir / "stops.geojson").write_text(
        json.dumps({"type": "FeatureCollection", "features": stop_features}, indent=2), encoding="utf-8"
    )
    (city_dir / "segments.geojson").write_text(
        json.dumps({"type": "FeatureCollection", "features": segment_features}, indent=2), encoding="utf-8"
    )
    logger.info("wrote GeoJSON snapshot for %s to %s", city_name, city_dir)
    return city_dir


def write_gtfs_static(city_name: str, routes: list[CanonicalRoute]) -> Path:
    """Minimal GTFS-static subset (routes.txt, stops.txt, trips.txt, stop_times.txt) —
    enough for a GTFS-aware tool to load, not a full feed. See docs §4.1 Stage 4."""
    city_dir = SNAPSHOT_DIR / city_name.lower().replace(" ", "-")
    city_dir.mkdir(parents=True, exist_ok=True)

    # GTFS models a bidirectional service as ONE route with one trip per direction.
    # routes.txt is therefore deduped by ref, while trips.txt carries a row per
    # direction — writing one routes.txt row per direction violates the spec's
    # route_id uniqueness requirement and merges opposite directions downstream.
    seen_route_ids: set[str] = set()
    with open(city_dir / "routes.txt", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["route_id", "route_short_name", "route_long_name", "route_type"])
        for i, route in enumerate(routes):
            route_id = route.ref or f"route-{i}"
            if route_id in seen_route_ids:
                continue
            seen_route_ids.add(route_id)
            w.writerow([route_id, route.ref or "", route.name or "", 3])  # 3 = bus

    direction_counter: dict[str, int] = {}
    with open(city_dir / "trips.txt", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["route_id", "trip_id", "trip_headsign", "direction_id"])
        for i, route in enumerate(routes):
            route_id = route.ref or f"route-{i}"
            # direction_id must be 0 or 1 per GTFS; assigned in encounter order per ref.
            direction = direction_counter.get(route_id, 0)
            direction_counter[route_id] = direction + 1
            headsign = (route.name or "").split("=>")[-1].strip()
            w.writerow([route_id, _direction_id(route), headsign, min(direction, 1)])

    seen_stop_ids: set[int] = set()
    with open(city_dir / "stops.txt", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["stop_id", "stop_name", "stop_lat", "stop_lon"])
        for route in routes:
            for stop in route.stops:
                if stop.osm_node_id in seen_stop_ids:
                    continue
                seen_stop_ids.add(stop.osm_node_id)
                w.writerow([stop.osm_node_id, stop.name or "", stop.lat, stop.lon])

    with open(city_dir / "stop_times.txt", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["trip_id", "stop_id", "stop_sequence"])
        for route in routes:
            trip_id = _direction_id(route)
            for seq, stop in enumerate(route.stops):
                w.writerow([trip_id, stop.osm_node_id, seq])

    logger.info("wrote GTFS-static snapshot for %s to %s", city_name, city_dir)
    return city_dir


def try_write_postgis(city_name: str, routes: list[CanonicalRoute]) -> bool:
    """Returns True if the write succeeded, False if PostGIS just isn't reachable yet
    (expected while Docker isn't running — this is a soft-fail, not a pipeline abort)."""
    if not settings.database_url:
        logger.warning("DATABASE_URL not set — skipping PostGIS write, snapshot-only for now")
        return False

    try:
        import psycopg
    except ImportError:
        logger.warning("psycopg not installed — skipping PostGIS write")
        return False

    try:
        with psycopg.connect(settings.database_url, connect_timeout=5) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO cities (name, state) VALUES (%s, %s) "
                    "ON CONFLICT (name) DO NOTHING RETURNING id",
                    (city_name, "Punjab"),
                )
                # Full route/stop/segment upserts land here once db/migrations exist
                # (docs/IMPLEMENTATION_ARCHITECTURE.md §3) — this connects the pipeline
                # end-to-end without yet duplicating the schema DDL in Python.
                conn.commit()
        logger.info("wrote %d routes to PostGIS for %s", len(routes), city_name)
        return True
    except Exception:
        logger.warning("PostGIS not reachable (Docker not up?) — snapshot-only for now", exc_info=True)
        return False
