"""Self-contained geometry helpers — deliberately not importing geo-ingest's
UTM/pyproj-based geometry.py (services/ boundaries stay decoupled; this only
needs meter-scale precision for jitter and point-at-distance, same as
stream-processor's geo.ts equirectangular approximation).
"""
from __future__ import annotations

import math
from dataclasses import dataclass

_EARTH_RADIUS_M = 6371000.0


@dataclass(frozen=True)
class LonLat:
    lon: float
    lat: float


def _to_local_m(point: LonLat, origin: LonLat) -> tuple[float, float]:
    lat_rad = math.radians(origin.lat)
    x = math.radians(point.lon - origin.lon) * _EARTH_RADIUS_M * math.cos(lat_rad)
    y = math.radians(point.lat - origin.lat) * _EARTH_RADIUS_M
    return x, y


def _from_local_m(x: float, y: float, origin: LonLat) -> LonLat:
    lat_rad = math.radians(origin.lat)
    lat = origin.lat + math.degrees(y / _EARTH_RADIUS_M)
    lon = origin.lon + math.degrees(x / (_EARTH_RADIUS_M * math.cos(lat_rad)))
    return LonLat(lon=lon, lat=lat)


def haversine_distance_m(a: LonLat, b: LonLat) -> float:
    lat1, lat2 = math.radians(a.lat), math.radians(b.lat)
    d_lat = math.radians(b.lat - a.lat)
    d_lon = math.radians(b.lon - a.lon)
    h = math.sin(d_lat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(d_lon / 2) ** 2
    return 2 * _EARTH_RADIUS_M * math.asin(math.sqrt(h))


def polyline_length_m(line: list[LonLat]) -> float:
    return sum(haversine_distance_m(line[i - 1], line[i]) for i in range(1, len(line)))


def point_at_distance(line: list[LonLat], dist_m: float) -> LonLat:
    """The real point on `line` at `dist_m` along it (clamped to the line's ends)."""
    if dist_m <= 0:
        return line[0]

    cumulative = 0.0
    for i in range(len(line) - 1):
        seg_len = haversine_distance_m(line[i], line[i + 1])
        if cumulative + seg_len >= dist_m:
            t = 0.0 if seg_len == 0 else (dist_m - cumulative) / seg_len
            origin = line[i]
            ax, ay = _to_local_m(line[i], origin)
            bx, by = _to_local_m(line[i + 1], origin)
            return _from_local_m(ax + t * (bx - ax), ay + t * (by - ay), origin)
        cumulative += seg_len
    return line[-1]


def project_onto_polyline(point: LonLat, line: list[LonLat]) -> float:
    """Distance along `line` (from its own start, vertex 0) to the nearest
    projection of `point`. This is the ONLY correct way to get a stop's position
    in the same coordinate system `point_at_distance(line, ...)` uses — a stop's
    index in the stop sequence says nothing about how far along the route's own
    polyline it actually sits. Assuming the first stop is at distance 0 is wrong
    whenever a route's first stop isn't the polyline's own starting vertex (found
    during simulator verification: one real route's first stop sits ~10km into a
    ~24km polyline, not at its start).
    """
    origin = line[0]
    best_dist = None
    best_offset = None
    cumulative = 0.0

    for i in range(len(line) - 1):
        ax, ay = _to_local_m(line[i], origin)
        bx, by = _to_local_m(line[i + 1], origin)
        px, py = _to_local_m(point, origin)

        seg_dx, seg_dy = bx - ax, by - ay
        seg_len_sq = seg_dx * seg_dx + seg_dy * seg_dy
        t = 0.0 if seg_len_sq == 0 else max(0.0, min(1.0, ((px - ax) * seg_dx + (py - ay) * seg_dy) / seg_len_sq))

        proj_x, proj_y = ax + t * seg_dx, ay + t * seg_dy
        offset = math.hypot(px - proj_x, py - proj_y)
        seg_len = math.hypot(seg_dx, seg_dy)
        dist_along = cumulative + t * seg_len

        if best_offset is None or offset < best_offset:
            best_offset = offset
            best_dist = dist_along

        cumulative += seg_len

    return best_dist if best_dist is not None else 0.0


def jitter(point: LonLat, sigma_m: float, rng) -> LonLat:
    """Gaussian GPS noise (~sigma_m std dev per axis) — a real phone's GPS reading
    is never exact, and the divergence-triggered publish decision (mirroring
    apps/mobile-app/lib/driver/location_transmitter.dart) has to operate on the
    same noisy reading a real device would see, not the simulator's ground truth.
    """
    dx = rng.normal(0, sigma_m)
    dy = rng.normal(0, sigma_m)
    return _from_local_m(dx, dy, point)
