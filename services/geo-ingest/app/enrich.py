"""Stage 3 — Enrich: attach OSRM baseline durations and POI-derived footfall priors
to an already-reconciled CanonicalRoute. Both are real measurements (a routing engine
over the real road network; real POI density near a real stop), not invented constants
— they're what makes the simulator's speed/dwell distributions defensible
(docs/IMPLEMENTATION_ARCHITECTURE.md §5.2, §5.4).
"""
from __future__ import annotations

import logging

from app import google_maps
from app.geometry import distance_m, distance_point_to_line_m, line_length_m, project_point_fraction
from app.models import CanonicalRoute, CanonicalStop
from app.osrm import segment_baseline
from app.reconcile import build_segments

logger = logging.getLogger(__name__)

FOOTFALL_RADIUS_M = 200.0
_MIN_STOP_SPACING_M = 80.0  # same de-dup spacing used in reconcile.infer_stops_along_line


def enrich_segment_baselines(route: CanonicalRoute) -> None:
    """Fills `osrm_baseline_sec` on every segment. Prefers Google Distance Matrix
    (real, traffic-conditioned duration) when GOOGLE_MAPS_API_KEY is configured;
    falls back to OSRM's free-flow-only baseline otherwise — either way this is used
    three places: the naive ETA (distance/avg-speed), `route_segments.osrm_baseline_sec`
    in the schema, and the simulator's `base_speed` anchor.
    """
    for seg in route.segments:
        origin = (seg.from_stop.lon, seg.from_stop.lat)
        dest = (seg.to_stop.lon, seg.to_stop.lat)

        google_result = None
        if google_maps.is_configured():
            try:
                google_result = google_maps.segment_duration(origin, dest)
            except Exception:
                logger.exception(
                    "Google Distance Matrix failed for segment %d (%s -> %s); falling back to OSRM",
                    seg.sequence, seg.from_stop.name, seg.to_stop.name,
                )

        if google_result is not None:
            seg.osrm_baseline_sec = google_result.duration_in_traffic_sec or google_result.duration_sec
            seg.baseline_source = "google_distance_matrix"
            continue

        try:
            result = segment_baseline(origin, dest)
            seg.osrm_baseline_sec = result.duration_sec
            seg.baseline_source = "osrm"
        except Exception:
            logger.exception(
                "OSRM baseline failed for segment %d (%s -> %s); leaving unset",
                seg.sequence, seg.from_stop.name, seg.to_stop.name,
            )


def densify_stops_with_google(route: CanonicalRoute) -> int:
    """Adds real Google-indexed bus_station/transit_station places along the route's
    real geometry to `route.stops`, deduped against existing OSM-derived stops and
    against each other. No-op (returns 0) if GOOGLE_MAPS_API_KEY isn't configured —
    the pipeline's validated default is the OSM-only stop list from Phase 1, where
    most routes surfaced only 2-5 real stops (only 38 OSM bus_stop/platform nodes
    exist across this entire 62-route network). Returns the number of stops added.

    NOT YET LIVE-TESTED — see app/google_maps.py module docstring.
    """
    if not google_maps.is_configured():
        return 0

    candidates = google_maps.nearby_bus_stops_along_line(route.geom_lonlat)
    if not candidates:
        return 0

    existing_fracs = sorted(project_point_fraction(route.geom_lonlat, (s.lon, s.lat)) for s in route.stops)
    line_len = line_length_m(route.geom_lonlat)

    new_stops: list[tuple[float, CanonicalStop]] = []
    for cand in candidates:
        offset = distance_point_to_line_m(route.geom_lonlat, (cand.lon, cand.lat))
        if offset > google_maps.CORRIDOR_SEARCH_RADIUS_M:
            continue  # snapped too far off the actual route to be a stop on it
        frac = project_point_fraction(route.geom_lonlat, (cand.lon, cand.lat))
        if any(abs(frac - ef) * line_len < _MIN_STOP_SPACING_M for ef in existing_fracs):
            continue  # already have a real stop here (OSM-tagged)
        new_stops.append(
            (frac, CanonicalStop(osm_node_id=-hash(cand.place_id) % (2**31), name=cand.name, lat=cand.lat, lon=cand.lon))
        )

    if not new_stops:
        return 0

    all_stops = [(project_point_fraction(route.geom_lonlat, (s.lon, s.lat)), s) for s in route.stops] + new_stops
    all_stops.sort(key=lambda t: t[0])
    route.stops = [s for _, s in all_stops]
    # Stop list changed — segments (built from the pre-densification stop list) are now
    # stale and must be regenerated against the same route geometry.
    route.segments = build_segments(route.geom_lonlat, route.stops)
    return len(new_stops)


def enrich_footfall_priors(route: CanonicalRoute, poi_points: list[tuple[float, float]]) -> None:
    """`footfall_prior` = count of real OSM POIs (markets/schools/hospitals/bus
    stations, see overpass.fetch_poi_density_points) within FOOTFALL_RADIUS_M of each
    stop. Normalized to [0, 1] against the busiest stop on this route so it composes
    cleanly into the simulator's Poisson boarding lambda.
    """
    raw_counts = []
    for stop in route.stops:
        count = sum(1 for poi in poi_points if distance_m((stop.lon, stop.lat), poi) <= FOOTFALL_RADIUS_M)
        raw_counts.append(count)

    peak = max(raw_counts) or 1
    for stop, count in zip(route.stops, raw_counts):
        stop.footfall_prior = count / peak
