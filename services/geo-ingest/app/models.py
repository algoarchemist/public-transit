from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum


class RouteSource(str, Enum):
    OSM_RELATION = "osm_relation"  # relation gives both geometry AND an explicit ordered stop sequence
    OSM_RELATION_INFERRED_STOPS = "osm_relation_inferred_stops"  # relation gives real geometry; stop
    # order is inferred by projecting real nearby bus_stop/platform nodes onto that real line —
    # common in practice: many PTv2 relations (e.g. all CTU routes found here) tag the road corridor
    # but never add stop/platform members, even though the spec calls for them.
    OSRM_SYNTHESIZED = "osrm_synthesized"  # no usable relation at all; stops + order from an external
    # sourced list (e.g. operator timetable), geometry synthesized by snapping them to the road network


@dataclass
class OsmStopNode:
    osm_node_id: int
    name: str | None
    lat: float
    lon: float


@dataclass
class OsmRouteRelation:
    osm_relation_id: int
    ref: str | None
    name: str | None
    operator: str | None
    way_ids: list[int]
    stop_node_ids: list[int]  # role=stop / role=platform members, in relation order


@dataclass
class CanonicalStop:
    osm_node_id: int
    name: str | None
    lat: float
    lon: float
    footfall_prior: float = 0.0


@dataclass
class CanonicalSegment:
    sequence: int
    from_stop: CanonicalStop
    to_stop: CanonicalStop
    geom_lonlat: list[tuple[float, float]]
    length_m: float
    osrm_baseline_sec: float | None = None  # segment baseline duration, from whichever source
    baseline_source: str | None = None  # 'google_distance_matrix' | 'osrm' — provenance, not just a number
    dominant_highway_class: str | None = None


@dataclass
class CanonicalRoute:
    ref: str | None
    name: str | None
    operator: str | None
    source: RouteSource
    osm_relation_id: int | None
    stops: list[CanonicalStop]
    segments: list[CanonicalSegment] = field(default_factory=list)
    geom_lonlat: list[tuple[float, float]] = field(default_factory=list)
    length_m: float = 0.0
