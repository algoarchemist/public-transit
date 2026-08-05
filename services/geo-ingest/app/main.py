"""CLI entrypoint: run the full geo-ingest pipeline for one city or network.

    python -m app.main --city Bathinda
    python -m app.main --name Mohali --bbox 30.64,76.70,30.90,76.84 --relation-ids-from-operator "Chandigarh Transport Undertaking"

Stage 1 (Discover) -> Stage 2 (Reconcile: Path A explicit stops, falling back to the
inferred-stops hybrid, falling back to skip) -> Stage 3 (Enrich: segment baselines,
optional Google stop densification, footfall priors) -> Stage 4 (Persist).

Two discovery modes:
- Area-name based (default): resolves a single OSM admin boundary and queries inside it.
  Works for a city with its own clean OSM boundary.
- bbox based (--bbox): needed when the real network spans multiple admin boundaries and
  doesn't resolve as one area — this is what the Chandigarh Tricity (CTU routes across
  Mohali/Kharar/Zirakpur/Dera Bassi, plus Chandigarh UT itself) actually required; see
  docs/IMPLEMENTATION_ARCHITECTURE.md §11.1 and the geo-ingest coverage findings.

See docs/IMPLEMENTATION_ARCHITECTURE.md §4 for the full pipeline spec.
"""
from __future__ import annotations

import argparse
import logging

from app.enrich import densify_stops_with_google, enrich_footfall_priors, enrich_segment_baselines
from app.models import CanonicalRoute
from app.overpass import (
    fetch_bus_route_relations,
    fetch_bus_stop_nodes,
    fetch_bus_stop_nodes_bbox,
    fetch_poi_density_points,
    resolve_city_area_id,
    run_query,
)
from app.persist import try_write_postgis, write_geojson_snapshot, write_gtfs_static
from app.reconcile import RouteValidationError, build_route_from_relation, build_route_with_inferred_stops

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("geo-ingest")


def _reconcile_one(rel: dict, candidate_stops: list) -> CanonicalRoute:
    """Path A (explicit stop members) first; falls back to the inferred-stops hybrid
    (real relation geometry + real nearby stop nodes projected onto it) — this is the
    path every CTU relation checked in this project actually needed, since none of
    them tag stop/platform members despite being PTv2 relations."""
    try:
        return build_route_from_relation(rel)
    except RouteValidationError:
        return build_route_with_inferred_stops(rel, candidate_stops)


def ingest(
    *,
    label: str,
    city_name: str | None = None,
    state_name: str = "Punjab",
    bbox: tuple[float, float, float, float] | None = None,
) -> list[CanonicalRoute]:
    """`label` is the snapshot directory name. `city_name` resolves a single OSM area
    (default mode); `bbox` (south, west, north, east) bypasses area resolution for
    networks that span multiple admin boundaries.
    """
    if bbox is not None:
        logger.info("stage 1 (discover): bbox mode %s", bbox)
        south, west, north, east = bbox
        raw_relations = run_query(
            f"""
            [out:json][timeout:120];
            relation({south},{west},{north},{east})["type"="route"]["route"="bus"];
            out geom;
            """
        ).get("elements", [])
        stop_nodes = fetch_bus_stop_nodes_bbox(south, west, north, east)
        # POI density needs an area id for the existing query shape; skipped in bbox
        # mode for now (footfall_prior stays 0 — a real gap, not silently faked).
        poi_points: list[tuple[float, float]] = []
    else:
        if not city_name:
            raise ValueError("city_name is required when bbox is not given")
        logger.info("resolving OSM area for %s, %s", city_name, state_name)
        area_id = resolve_city_area_id(city_name, state_name)
        logger.info("stage 1 (discover): fetching bus route relations + stops + POIs")
        raw_relations = fetch_bus_route_relations(area_id)
        stop_nodes = fetch_bus_stop_nodes(area_id)
        poi_nodes = fetch_poi_density_points(area_id)
        poi_points = [(n["lon"], n["lat"]) for n in poi_nodes if "lon" in n]

    from app.models import OsmStopNode

    candidate_stops = [
        OsmStopNode(osm_node_id=n["id"], name=n.get("tags", {}).get("name"), lat=n["lat"], lon=n["lon"])
        for n in stop_nodes
    ]
    logger.info(
        "found %d route relations, %d candidate real stop nodes, %d POI points",
        len(raw_relations), len(candidate_stops), len(poi_points),
    )

    logger.info("stage 2 (reconcile): Path A explicit stops, falling back to inferred-stops hybrid")
    routes: list[CanonicalRoute] = []
    for rel in raw_relations:
        try:
            route = _reconcile_one(rel, candidate_stops)
            routes.append(route)
            logger.info(
                "  OK [%s] relation %s (%s): %d stops, %.0fm",
                route.source.value, rel.get("id"), rel.get("tags", {}).get("ref", "?"),
                len(route.stops), route.length_m,
            )
        except RouteValidationError as e:
            logger.warning("  SKIP relation %s: %s", rel.get("id"), e)

    if not raw_relations:
        logger.warning(
            "%s has zero OSM bus route relations — Path B needed: a real, sourced stop "
            "list (e.g. an operator timetable) via app.reconcile.build_route_from_stop_sequence, "
            "since there is nothing here to reconcile automatically.",
            label,
        )

    logger.info("stage 3 (enrich): segment baselines, Google stop densification, footfall priors")
    for route in routes:
        added = densify_stops_with_google(route)
        if added:
            logger.info("  +%d Google-discovered stops on route %s", added, route.ref)
        enrich_segment_baselines(route)
        if poi_points:
            enrich_footfall_priors(route, poi_points)

    logger.info("stage 4 (persist): writing snapshot")
    write_geojson_snapshot(label, routes)
    write_gtfs_static(label, routes)
    wrote_db = try_write_postgis(label, routes)
    logger.info("done. %d routes ingested. postgis_write=%s", len(routes), wrote_db)
    return routes


def main() -> None:
    parser = argparse.ArgumentParser(description="SetuTrack geo-ingest")
    parser.add_argument("--city", help="City name as it appears in OSM, e.g. Bathinda (area-resolution mode)")
    parser.add_argument("--state", default="Punjab")
    parser.add_argument(
        "--bbox", help="south,west,north,east — bypass area resolution (needed for networks spanning "
        "multiple admin boundaries, e.g. the Chandigarh Tricity)"
    )
    parser.add_argument("--label", help="snapshot directory name; defaults to --city")
    args = parser.parse_args()

    if args.bbox:
        south, west, north, east = (float(x) for x in args.bbox.split(","))
        ingest(label=args.label or "network", bbox=(south, west, north, east))
    else:
        if not args.city:
            parser.error("either --city or --bbox is required")
        ingest(label=args.label or args.city, city_name=args.city, state_name=args.state)


if __name__ == "__main__":
    main()
