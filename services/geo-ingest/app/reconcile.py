"""Stage 2 — Reconcile: turn raw Overpass elements into a CanonicalRoute.

Path A (relation exists): stitch the relation's way members into one LineString,
extract its stop/platform node members in relation order.

Path B (no relation, or a relation too broken to trust): take real bus_stop nodes in
an operator-published order and let OSRM snap them onto the real road network.

Both paths produce a CanonicalRoute with `source` recorded, so provenance is never
lost (see docs/IMPLEMENTATION_ARCHITECTURE.md §3.1, §4.2).
"""
from __future__ import annotations

import logging

from app.geometry import distance_m, distance_point_to_line_m, line_length_m, project_point_fraction
from app.models import CanonicalRoute, CanonicalSegment, CanonicalStop, OsmStopNode, RouteSource
from app.osrm import route_through_waypoints

logger = logging.getLogger(__name__)

_WAY_JOIN_TOLERANCE_M = 5.0
_STOP_SNAP_TOLERANCE_M = 150.0  # validation gate from docs §4.2

_STOP_ROLES = {
    "stop", "stop_entry_only", "stop_exit_only",
    "platform", "platform_entry_only", "platform_exit_only",
}


class RouteValidationError(Exception):
    """Raised when a reconstructed route fails the geometry validation gate —
    intentionally loud, since bad geometry silently destroys ETA accuracy."""


def _way_coords(member: dict) -> list[tuple[float, float]]:
    return [(pt["lon"], pt["lat"]) for pt in member.get("geometry", []) if pt is not None]


def _stitch_ways(way_members: list[dict]) -> list[tuple[float, float]]:
    ways = [_way_coords(w) for w in way_members if w.get("geometry")]
    ways = [w for w in ways if len(w) >= 2]
    if not ways:
        raise RouteValidationError("relation has no usable way geometry")

    stitched = list(ways[0])
    for way in ways[1:]:
        tail = stitched[-1]
        d_start = distance_m(tail, way[0])
        d_end = distance_m(tail, way[-1])
        if d_start <= _WAY_JOIN_TOLERANCE_M and d_start <= d_end:
            stitched.extend(way[1:])
        elif d_end <= _WAY_JOIN_TOLERANCE_M:
            stitched.extend(reversed(way[:-1]))
        else:
            logger.warning(
                "way join gap of %.1fm / %.1fm exceeds tolerance — route may be discontinuous",
                d_start, d_end,
            )
            stitched.extend(way)  # keep going; validation gate below will catch real breaks
    return stitched


def _stops_from_members(node_members: list[dict]) -> list[CanonicalStop]:
    stops: list[CanonicalStop] = []
    for m in node_members:
        if m.get("role") not in _STOP_ROLES or "lat" not in m:
            continue
        stop = CanonicalStop(
            osm_node_id=m["ref"],
            name=m.get("tags", {}).get("name"),
            lat=m["lat"],
            lon=m["lon"],
        )
        # Relations sometimes list the same stop twice (entry+exit pair); keep first.
        if not stops or stops[-1].osm_node_id != stop.osm_node_id:
            stops.append(stop)
    return stops


def build_segments(line_lonlat: list[tuple[float, float]], stops: list[CanonicalStop]) -> list[CanonicalSegment]:
    fractions = [project_point_fraction(line_lonlat, (s.lon, s.lat)) for s in stops]
    for i in range(1, len(fractions)):
        if fractions[i] < fractions[i - 1] - 0.02:  # 2% tolerance for GPS/digitization noise
            raise RouteValidationError(
                f"stop order is non-monotonic along route geometry at index {i} "
                f"({stops[i-1].name!r} -> {stops[i].name!r}) — route needs manual review"
            )

    from app.geometry import substring

    segments: list[CanonicalSegment] = []
    for i in range(len(stops) - 1):
        geom = substring(line_lonlat, fractions[i], fractions[i + 1])
        segments.append(
            CanonicalSegment(
                sequence=i,
                from_stop=stops[i],
                to_stop=stops[i + 1],
                geom_lonlat=geom,
                length_m=line_length_m(geom),
            )
        )
    return segments


def build_route_from_relation(raw_relation: dict) -> CanonicalRoute:
    """Path A: relation exists on OSM."""
    members = raw_relation.get("members", [])
    way_members = [m for m in members if m.get("type") == "way"]
    node_members = [m for m in members if m.get("type") == "node"]

    line = _stitch_ways(way_members)
    stops = _stops_from_members(node_members)
    if len(stops) < 2:
        raise RouteValidationError(
            f"relation {raw_relation.get('id')} has {len(stops)} usable stop members (need >= 2)"
        )

    # Snap each stop onto the stitched line's nearest point so `dist_along_route_m` is
    # geometrically consistent even when the raw stop node sits slightly off the way.
    for stop in stops:
        offset = min(distance_m((stop.lon, stop.lat), pt) for pt in line)
        if offset > _STOP_SNAP_TOLERANCE_M:
            raise RouteValidationError(
                f"stop {stop.name or stop.osm_node_id!r} is {offset:.0f}m from the route "
                f"line (tolerance {_STOP_SNAP_TOLERANCE_M}m) — likely a mis-stitched way"
            )

    tags = raw_relation.get("tags", {})
    route = CanonicalRoute(
        ref=tags.get("ref"),
        name=tags.get("name"),
        operator=tags.get("operator"),
        source=RouteSource.OSM_RELATION,
        osm_relation_id=raw_relation.get("id"),
        stops=stops,
        geom_lonlat=line,
        length_m=line_length_m(line),
    )
    route.segments = build_segments(line, stops)
    return route


_INFERRED_STOP_BUFFER_M = 40.0
_MIN_INFERRED_STOP_SPACING_M = 80.0


def infer_stops_along_line(
    line_lonlat: list[tuple[float, float]], candidate_stops: list[OsmStopNode]
) -> list[CanonicalStop]:
    """Real bus_stop/platform nodes that sit within `_INFERRED_STOP_BUFFER_M` of a
    real route line, ordered by their projection onto it. Two candidates that land
    very close together along the line (e.g. a bus_stop and a platform node for the
    same physical stop, or opposite-curb duplicates) are deduped, keeping whichever
    sits closer to the line."""
    near: list[tuple[float, OsmStopNode, float]] = []
    for s in candidate_stops:
        offset = distance_point_to_line_m(line_lonlat, (s.lon, s.lat))
        if offset <= _INFERRED_STOP_BUFFER_M:
            frac = project_point_fraction(line_lonlat, (s.lon, s.lat))
            near.append((frac, s, offset))
    near.sort(key=lambda t: t[0])

    line_len = line_length_m(line_lonlat)
    deduped: list[tuple[float, OsmStopNode, float]] = []
    for frac, s, offset in near:
        if deduped and (frac - deduped[-1][0]) * line_len < _MIN_INFERRED_STOP_SPACING_M:
            if offset < deduped[-1][2]:
                deduped[-1] = (frac, s, offset)
            continue
        deduped.append((frac, s, offset))

    return [CanonicalStop(osm_node_id=s.osm_node_id, name=s.name, lat=s.lat, lon=s.lon) for _, s, _ in deduped]


def build_route_with_inferred_stops(raw_relation: dict, candidate_stops: list[OsmStopNode]) -> CanonicalRoute:
    """Middle case between Path A and Path B: the relation has real, complete way
    geometry (a real road corridor) but — as turned out to be true for every CTU
    relation checked — tags zero stop/platform members, even though PTv2 calls for
    them. Rather than falling back to a fabricated stop order, this projects real
    standalone bus_stop/platform nodes onto the real line and orders them by position.
    Recorded as `OSM_RELATION_INFERRED_STOPS`, never conflated with a relation that
    gave an explicit stop sequence.
    """
    members = raw_relation.get("members", [])
    way_members = [m for m in members if m.get("type") == "way"]
    line = _stitch_ways(way_members)

    stops = infer_stops_along_line(line, candidate_stops)
    if len(stops) < 2:
        raise RouteValidationError(
            f"relation {raw_relation.get('id')}: only {len(stops)} real stop node(s) found "
            f"within {_INFERRED_STOP_BUFFER_M:.0f}m of the route geometry (need >= 2) — "
            "this route needs a manually sourced stop list (Path B) instead"
        )

    tags = raw_relation.get("tags", {})
    route = CanonicalRoute(
        ref=tags.get("ref"),
        name=tags.get("name"),
        operator=tags.get("operator"),
        source=RouteSource.OSM_RELATION_INFERRED_STOPS,
        osm_relation_id=raw_relation.get("id"),
        stops=stops,
        geom_lonlat=line,
        length_m=line_length_m(line),
    )
    route.segments = build_segments(line, stops)
    return route


def build_route_from_stop_sequence(
    *, ref: str | None, name: str | None, operator: str | None, ordered_stops: list[OsmStopNode]
) -> CanonicalRoute:
    """Path B: no usable relation. `ordered_stops` must come from a real, sourced
    ordering (an operator-published route list) — this function does not invent an
    order, it only snaps a given real order onto the real road network via OSRM.
    """
    if len(ordered_stops) < 2:
        raise RouteValidationError("need >= 2 ordered stops to synthesize a route")

    waypoints = [(s.lon, s.lat) for s in ordered_stops]
    osrm_result = route_through_waypoints(waypoints)

    stops = [CanonicalStop(osm_node_id=s.osm_node_id, name=s.name, lat=s.lat, lon=s.lon) for s in ordered_stops]
    route = CanonicalRoute(
        ref=ref,
        name=name,
        operator=operator,
        source=RouteSource.OSRM_SYNTHESIZED,
        osm_relation_id=None,
        stops=stops,
        geom_lonlat=osrm_result.geometry_lonlat,
        length_m=osrm_result.distance_m,
    )
    route.segments = build_segments(osrm_result.geometry_lonlat, stops)
    return route
