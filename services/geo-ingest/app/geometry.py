"""Geometry helpers shared by reconciliation and enrichment. Uses UTM 43N
(EPSG:32643) for length/distance math — Punjab sits entirely within it, and
raw lon/lat degrees are not a metric space.
"""
from __future__ import annotations

from pyproj import Transformer
from shapely.geometry import LineString, Point
from shapely.ops import transform

_TO_UTM = Transformer.from_crs("EPSG:4326", "EPSG:32643", always_xy=True).transform
_TO_WGS84 = Transformer.from_crs("EPSG:32643", "EPSG:4326", always_xy=True).transform


def line_length_m(coords_lonlat: list[tuple[float, float]]) -> float:
    if len(coords_lonlat) < 2:
        return 0.0
    line_utm = transform(_TO_UTM, LineString(coords_lonlat))
    return line_utm.length


def project_point_fraction(line_lonlat: list[tuple[float, float]], point_lonlat: tuple[float, float]) -> float:
    """Fractional distance [0,1] of `point`'s nearest projection along `line`."""
    line_utm = transform(_TO_UTM, LineString(line_lonlat))
    point_utm = transform(_TO_UTM, Point(point_lonlat))
    if line_utm.length == 0:
        return 0.0
    return line_utm.project(point_utm) / line_utm.length


def distance_m(a_lonlat: tuple[float, float], b_lonlat: tuple[float, float]) -> float:
    a_utm = transform(_TO_UTM, Point(a_lonlat))
    b_utm = transform(_TO_UTM, Point(b_lonlat))
    return a_utm.distance(b_utm)


def distance_point_to_line_m(line_lonlat: list[tuple[float, float]], point_lonlat: tuple[float, float]) -> float:
    """Perpendicular distance from `point` to the nearest point on `line` — not
    point-to-point distance to an endpoint. Used to find real stop nodes that sit
    near a route's real geometry when the relation itself has no stop members."""
    line_utm = transform(_TO_UTM, LineString(line_lonlat))
    point_utm = transform(_TO_UTM, Point(point_lonlat))
    return line_utm.distance(point_utm)


def interpolate_point_at_distance(line_lonlat: list[tuple[float, float]], dist_m: float) -> tuple[float, float]:
    """Real (lon, lat) at `dist_m` along `line` — used to sample search points along a
    route corridor (e.g. for Google Places Nearby Search) at fixed real-world spacing."""
    line_utm = transform(_TO_UTM, LineString(line_lonlat))
    point_utm = line_utm.interpolate(min(dist_m, line_utm.length))
    point_wgs84 = transform(_TO_WGS84, point_utm)
    return (point_wgs84.x, point_wgs84.y)


def substring(line_lonlat: list[tuple[float, float]], start_frac: float, end_frac: float) -> list[tuple[float, float]]:
    """Real sub-polyline of `line` between two fractional positions (used to derive
    per-segment geometry from a route's full LineString, i.e. ST_LineSubstring)."""
    from shapely.ops import substring as shapely_substring

    line_utm = transform(_TO_UTM, LineString(line_lonlat))
    sub_utm = shapely_substring(line_utm, start_frac * line_utm.length, end_frac * line_utm.length)
    sub_wgs84 = transform(_TO_WGS84, sub_utm)
    return list(sub_wgs84.coords)
