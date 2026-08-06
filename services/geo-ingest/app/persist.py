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
from app.models import CanonicalRoute, CanonicalStop

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


def _point_wkt(lon: float, lat: float) -> str:
    return f"POINT({lon} {lat})"


def _linestring_wkt(coords: list[tuple[float, float]]) -> str:
    return "LINESTRING(" + ", ".join(f"{lon} {lat}" for lon, lat in coords) + ")"


def _upsert_city(cur, city_name: str) -> int:
    # DO UPDATE (not DO NOTHING) so RETURNING always yields a row, including on a
    # second run against an already-seeded city — DO NOTHING returns nothing on
    # conflict, which would leave city_id unbound for every route insert below.
    cur.execute(
        "INSERT INTO cities (name, state) VALUES (%s, %s) "
        "ON CONFLICT (name) DO UPDATE SET state = EXCLUDED.state "
        "RETURNING id",
        (city_name, "Punjab"),
    )
    return cur.fetchone()[0]


def _upsert_route(cur, city_id: int, route: CanonicalRoute) -> int:
    # GTFS-style headsign as a stand-in for `direction` — same derivation
    # write_gtfs_static already uses for trip_headsign.
    direction = (route.name or "").split("=>")[-1].strip() or None
    cur.execute(
        """
        INSERT INTO routes (city_id, ref, name, operator, direction, osm_relation_id, source, geom, length_m)
        VALUES (%(city_id)s, %(ref)s, %(name)s, %(operator)s, %(direction)s, %(osm_relation_id)s,
                %(source)s, ST_GeomFromText(%(geom_wkt)s, 4326), %(length_m)s)
        ON CONFLICT (city_id, osm_relation_id) WHERE osm_relation_id IS NOT NULL
        DO UPDATE SET ref = EXCLUDED.ref, name = EXCLUDED.name, operator = EXCLUDED.operator,
                       direction = EXCLUDED.direction, source = EXCLUDED.source,
                       geom = EXCLUDED.geom, length_m = EXCLUDED.length_m
        RETURNING id
        """,
        {
            "city_id": city_id,
            "ref": route.ref,
            "name": route.name,
            "operator": route.operator,
            "direction": direction,
            "osm_relation_id": route.osm_relation_id,
            "source": route.source.value,
            "geom_wkt": _linestring_wkt(route.geom_lonlat),
            "length_m": route.length_m,
        },
    )
    return cur.fetchone()[0]


def _upsert_stop(cur, city_id: int, stop: CanonicalStop) -> int:
    cur.execute(
        """
        INSERT INTO stops (city_id, osm_node_id, name, geom, footfall_prior)
        VALUES (%s, %s, %s, ST_GeomFromText(%s, 4326), %s)
        ON CONFLICT (city_id, osm_node_id) DO UPDATE
        SET name = EXCLUDED.name, geom = EXCLUDED.geom, footfall_prior = EXCLUDED.footfall_prior
        RETURNING id
        """,
        (city_id, stop.osm_node_id, stop.name, _point_wkt(stop.lon, stop.lat), stop.footfall_prior),
    )
    return cur.fetchone()[0]


def _replace_route_stops(cur, route_id: int, route: CanonicalRoute, stop_ids: list[int]) -> None:
    """Delete-then-reinsert rather than an upsert: the ordered stop list can shrink or
    reorder between runs, and diffing that is more code than just replacing it — this
    table has no other tables depending on its rows surviving, so it's safe."""
    cur.execute("DELETE FROM route_stops WHERE route_id = %s", (route_id,))
    for sequence, stop_id in enumerate(stop_ids):
        # dist_along_route_m computed here (not in Python) so it's the exact same
        # ST_LineLocatePoint projection docs/IMPLEMENTATION_ARCHITECTURE.md §3.1
        # specifies, and the same one stream-processor/simulator project stops onto —
        # summing segment lengths instead was the bug both of those fixed (see
        # services/simulator/README.md "Bugs found").
        cur.execute(
            """
            INSERT INTO route_stops (route_id, stop_id, sequence, dist_along_route_m)
            SELECT %(route_id)s, %(stop_id)s, %(sequence)s,
                   ST_LineLocatePoint(r.geom, s.geom) * r.length_m
            FROM routes r, stops s
            WHERE r.id = %(route_id)s AND s.id = %(stop_id)s
            """,
            {"route_id": route_id, "stop_id": stop_id, "sequence": sequence},
        )


def _replace_route_segments(
    cur, route_id: int, route: CanonicalRoute, stop_id_by_osm_node: dict[int, int]
) -> None:
    cur.execute("DELETE FROM route_segments WHERE route_id = %s", (route_id,))
    for seg in route.segments:
        cur.execute(
            """
            INSERT INTO route_segments
                (route_id, sequence, from_stop_id, to_stop_id, geom, length_m,
                 osrm_baseline_sec, dominant_highway_class)
            VALUES (%s, %s, %s, %s, ST_GeomFromText(%s, 4326), %s, %s, %s)
            """,
            (
                route_id,
                seg.sequence,
                stop_id_by_osm_node[seg.from_stop.osm_node_id],
                stop_id_by_osm_node[seg.to_stop.osm_node_id],
                _linestring_wkt(seg.geom_lonlat),
                seg.length_m,
                seg.osrm_baseline_sec,
                seg.dominant_highway_class,
            ),
        )


def try_write_postgis(city_name: str, routes: list[CanonicalRoute]) -> bool:
    """Returns True if the write succeeded, False if PostGIS just isn't reachable yet
    (soft-fail, not a pipeline abort — the GeoJSON/GTFS snapshot above is already
    written regardless). Full route/stop/segment upsert against db/migrations/
    (docs/IMPLEMENTATION_ARCHITECTURE.md §3); idempotent by (city, osm_relation_id)
    for routes and (city, osm_node_id) for stops — see §4.2."""
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
                city_id = _upsert_city(cur, city_name)
                for route in routes:
                    route_id = _upsert_route(cur, city_id, route)
                    stop_ids = [_upsert_stop(cur, city_id, stop) for stop in route.stops]
                    stop_id_by_osm_node = dict(zip((s.osm_node_id for s in route.stops), stop_ids))
                    _replace_route_stops(cur, route_id, route, stop_ids)
                    _replace_route_segments(cur, route_id, route, stop_id_by_osm_node)
            conn.commit()
        logger.info(
            "wrote %d routes (%d stops, %d segments) to PostGIS for %s",
            len(routes),
            sum(len(r.stops) for r in routes),
            sum(len(r.segments) for r in routes),
            city_name,
        )
        return True
    except Exception:
        logger.warning("PostGIS write failed — snapshot-only for now", exc_info=True)
        return False
