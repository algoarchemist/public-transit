"""Loads the geo-ingest snapshot (data/snapshots/<label>/{routes,stops,segments}.geojson)
into the same shape stream-processor's routeStore.ts uses — real OSM route geometry,
real stops, real OSRM segment baselines. Kept as a from-scratch Python port rather than
importing geo-ingest directly: these are separate services and stay decoupled, same
reasoning as stream-processor's independent geo.ts.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field

from app.config import SNAPSHOT_DIR
from app.geometry import LonLat, polyline_length_m, project_onto_polyline


@dataclass
class SimStop:
    osm_node_id: int
    name: str | None
    lat: float
    lon: float
    footfall_prior: float
    dist_along_route_m: float


@dataclass
class SimSegment:
    sequence: int
    from_stop_name: str | None
    to_stop_name: str | None
    length_m: float
    baseline_sec: float | None
    from_dist_m: float
    to_dist_m: float

    @property
    def avg_speed_mps(self) -> float | None:
        return self.length_m / self.baseline_sec if self.baseline_sec else None


@dataclass
class SimRoute:
    direction_id: str
    route_id: str | None
    name: str | None
    geometry: list[LonLat]
    total_length_m: float
    stops: list[SimStop] = field(default_factory=list)
    segments: list[SimSegment] = field(default_factory=list)

    def segment_at_distance(self, dist_m: float) -> SimSegment | None:
        for seg in self.segments:
            if dist_m <= seg.to_dist_m:
                return seg
        return self.segments[-1] if self.segments else None

    @property
    def average_speed_mps(self) -> float:
        """Real average speed across all baselined segments — the fallback used
        when a specific segment has no `baseline_sec` of its own. Deliberately a
        route-wide average, not e.g. the nearest segment's speed: a short, locally
        slow segment (right next to a stop) would badly misrepresent a longer
        unbaselined stretch if extrapolated — this was caught during simulator
        verification (an 89-minute simulated trip for a route with a 21-minute
        OSRM free-flow baseline, traced to exactly that)."""
        total_len = sum(s.length_m for s in self.segments if s.baseline_sec)
        total_sec = sum(s.baseline_sec for s in self.segments if s.baseline_sec)
        return total_len / total_sec if total_sec else 8.0


def _line_from_coords(coords: list[list[float]]) -> list[LonLat]:
    return [LonLat(lon=c[0], lat=c[1]) for c in coords]


def load_snapshot(label: str) -> dict[str, SimRoute]:
    snap_dir = SNAPSHOT_DIR / label
    routes_fc = json.loads((snap_dir / "routes.geojson").read_text(encoding="utf-8"))
    stops_fc = json.loads((snap_dir / "stops.geojson").read_text(encoding="utf-8"))
    segments_fc = json.loads((snap_dir / "segments.geojson").read_text(encoding="utf-8"))

    by_direction: dict[str, SimRoute] = {}

    for feat in routes_fc["features"]:
        direction_id = feat["properties"]["direction_id"]
        geometry = _line_from_coords(feat["geometry"]["coordinates"])

        # Each stop's real distance along THIS route's own polyline — via direct
        # projection, not "cumulative sum of segment lengths starting from 0".
        # Assuming the first stop sits at distance 0 is wrong whenever it isn't
        # the polyline's own starting vertex: found during verification that one
        # real route's first stop sits ~10km into a ~24km polyline. Both this and
        # stream-processor's routeStore.ts had the same flawed assumption; both
        # are fixed together (see geometry.py's project_onto_polyline docstring).
        stop_feats = sorted(
            (f for f in stops_fc["features"] if f["properties"]["direction_id"] == direction_id),
            key=lambda f: f["properties"]["sequence"],
        )
        stops: list[SimStop] = []
        for f in stop_feats:
            p = f["properties"]
            lon, lat = f["geometry"]["coordinates"]
            stops.append(
                SimStop(
                    osm_node_id=p["osm_node_id"],
                    name=p["name"],
                    lat=lat,
                    lon=lon,
                    footfall_prior=p.get("footfall_prior", 0.0),
                    dist_along_route_m=project_onto_polyline(LonLat(lon=lon, lat=lat), geometry),
                )
            )

        seg_feats = sorted(
            (f for f in segments_fc["features"] if f["properties"]["direction_id"] == direction_id),
            key=lambda f: f["properties"]["sequence"],
        )
        segments: list[SimSegment] = []
        for i, f in enumerate(seg_feats):
            p = f["properties"]
            segments.append(
                SimSegment(
                    sequence=p["sequence"],
                    from_stop_name=p["from_stop_name"],
                    to_stop_name=p["to_stop_name"],
                    length_m=p["length_m"],
                    baseline_sec=p["baseline_sec"],
                    from_dist_m=stops[i].dist_along_route_m,
                    to_dist_m=stops[i + 1].dist_along_route_m,
                )
            )

        by_direction[direction_id] = SimRoute(
            direction_id=direction_id,
            route_id=feat["properties"]["ref"],
            name=feat["properties"]["name"],
            geometry=geometry,
            total_length_m=feat["properties"].get("length_m") or polyline_length_m(geometry),
            stops=stops,
            segments=segments,
        )

    return by_direction
