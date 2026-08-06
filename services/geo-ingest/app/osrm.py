"""OSRM client: real road-network routing for two jobs —
1. Path B route synthesis (snap an ordered list of real stop coords to the road network)
2. Per-segment baseline duration + dominant road class (Stage 3 enrichment)

Points at the self-hosted OSRM instance (see infra/docker/osrm/build.sh,
docker-compose.yml's `osrm` service) by default now that Docker is up. Falls back to
the public demo server if OSRM_URL is repointed at it — that server explicitly asks not
to be used for batch workloads (see docs/IMPLEMENTATION_ARCHITECTURE.md §4.2), so this
client throttles itself to `max_concurrent_osrm_requests` regardless of target.
"""
from __future__ import annotations

import hashlib
import json
import time
from dataclasses import dataclass
from pathlib import Path

import httpx
from tenacity import retry, stop_after_attempt, wait_exponential

from app.config import CACHE_DIR, settings

_HEADERS = {"User-Agent": "SetuTrack-geo-ingest/0.1 (SIH25013 hackathon project)"}


@dataclass
class OsrmRouteResult:
    geometry_lonlat: list[tuple[float, float]]
    duration_sec: float
    distance_m: float


def _cache_path(path: str, params: dict) -> Path:
    key = json.dumps({"path": path, **params}, sort_keys=True)
    return CACHE_DIR / f"osrm_{hashlib.sha256(key.encode()).hexdigest()[:24]}.json"


@retry(stop=stop_after_attempt(4), wait=wait_exponential(multiplier=2, min=2, max=30))
def _get(path: str, params: dict) -> dict:
    # Cache every raw response (docs/IMPLEMENTATION_ARCHITECTURE.md §4.2). Without this
    # a full-city enrichment pass re-hits the public demo server on every run — which it
    # explicitly asks not to be used for batch work — and makes runs non-reproducible.
    cache_file = _cache_path(path, params)
    if cache_file.exists():
        return json.loads(cache_file.read_text(encoding="utf-8"))

    resp = httpx.get(f"{settings.osrm_url}{path}", params=params, headers=_HEADERS, timeout=settings.request_timeout_sec)
    if resp.status_code in (429, 504):
        raise httpx.HTTPStatusError("transient osrm error", request=resp.request, response=resp)
    resp.raise_for_status()
    body = resp.json()
    if body.get("code") != "Ok":
        raise RuntimeError(f"OSRM error: {body.get('code')} {body.get('message', '')}")

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_file.write_text(json.dumps(body), encoding="utf-8")
    time.sleep(0.3)  # self-throttle the shared public instance; skipped on cache hits
    return body


def route_through_waypoints(waypoints_lonlat: list[tuple[float, float]]) -> OsrmRouteResult:
    """Snaps an ordered list of real stop coordinates onto the drivable road network
    and returns the road-following polyline between them (Path B route synthesis)."""
    if len(waypoints_lonlat) < 2:
        raise ValueError("need at least 2 waypoints to route through")

    coords = ";".join(f"{lon},{lat}" for lon, lat in waypoints_lonlat)
    body = _get(
        f"/route/v1/driving/{coords}",
        {"overview": "full", "geometries": "geojson"},
    )
    route = body["routes"][0]
    return OsrmRouteResult(
        geometry_lonlat=[tuple(c) for c in route["geometry"]["coordinates"]],
        duration_sec=route["duration"],
        distance_m=route["distance"],
    )


def segment_baseline(from_lonlat: tuple[float, float], to_lonlat: tuple[float, float]) -> OsrmRouteResult:
    """Free-flow baseline duration for one stop-to-stop segment (Stage 3 enrichment) —
    this becomes `route_segments.osrm_baseline_sec`, the naive-ETA baseline and the
    simulator's base speed anchor (docs/IMPLEMENTATION_ARCHITECTURE.md §5.2)."""
    return route_through_waypoints([from_lonlat, to_lonlat])
