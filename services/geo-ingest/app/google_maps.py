"""Google Maps Platform client: denser real bus-stop discovery (Places Nearby Search)
and traffic-conditioned segment durations (Distance Matrix) — an optional upgrade over
the free OSRM/OSM path for when a GOOGLE_MAPS_API_KEY is configured.

Every function here no-ops (returns None / []) when the key isn't set, so callers
treat this purely as "better data if available" — the pipeline's validated default
stays the free OSRM/OSM path from Phase 1 (docs/IMPLEMENTATION_ARCHITECTURE.md §4, §5.2).

NOT YET LIVE-TESTED: no API key was available in this environment when this was
written. Wire in a real GOOGLE_MAPS_API_KEY and run scripts/check_google_maps.py
before trusting this against production traffic/billing.
"""
from __future__ import annotations

import hashlib
import json
import logging
from dataclasses import dataclass
from pathlib import Path

import httpx
from tenacity import retry, stop_after_attempt, wait_exponential

from app.config import CACHE_DIR, settings
from app.geometry import interpolate_point_at_distance, line_length_m

logger = logging.getLogger(__name__)

PLACES_NEARBY_URL = "https://maps.googleapis.com/maps/api/place/nearbysearch/json"
DISTANCE_MATRIX_URL = "https://maps.googleapis.com/maps/api/distancematrix/json"

_BUS_STOP_PLACE_TYPES = ("bus_station", "transit_station")
# Public (no underscore): app.enrich reads CORRIDOR_SEARCH_RADIUS_M when merging
# Google-discovered stops against existing real OSM stops.
CORRIDOR_SAMPLE_SPACING_M = 400.0
CORRIDOR_SEARCH_RADIUS_M = 250


@dataclass
class GoogleStopCandidate:
    place_id: str
    name: str
    lat: float
    lon: float


@dataclass
class GoogleSegmentDuration:
    duration_sec: float
    duration_in_traffic_sec: float | None
    distance_m: float


def is_configured() -> bool:
    return bool(settings.google_maps_api_key)


def _cache_path(url: str, params: dict) -> Path:
    key = json.dumps({"url": url, **{k: v for k, v in params.items() if k != "key"}}, sort_keys=True)
    digest = hashlib.sha256(key.encode()).hexdigest()[:24]
    return CACHE_DIR / f"gmaps_{digest}.json"


@retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=2, min=2, max=20))
def _get(url: str, params: dict) -> dict:
    cache_file = _cache_path(url, params)
    if cache_file.exists():
        return json.loads(cache_file.read_text(encoding="utf-8"))

    resp = httpx.get(url, params={**params, "key": settings.google_maps_api_key}, timeout=settings.request_timeout_sec)
    resp.raise_for_status()
    body = resp.json()
    status = body.get("status")
    if status in ("OVER_QUERY_LIMIT", "UNKNOWN_ERROR"):
        raise httpx.HTTPStatusError(f"transient google maps error: {status}", request=resp.request, response=resp)
    if status not in ("OK", "ZERO_RESULTS"):
        raise RuntimeError(f"Google Maps API error: {status} {body.get('error_message', '')}")

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_file.write_text(json.dumps(body), encoding="utf-8")
    return body


def nearby_bus_stops(lat: float, lon: float, radius_m: int = 300) -> list[GoogleStopCandidate]:
    """Real bus_station/transit_station places Google has indexed near a point."""
    if not is_configured():
        logger.debug("GOOGLE_MAPS_API_KEY not set — skipping Google stop discovery")
        return []

    found: dict[str, GoogleStopCandidate] = {}
    for place_type in _BUS_STOP_PLACE_TYPES:
        body = _get(PLACES_NEARBY_URL, {"location": f"{lat},{lon}", "radius": radius_m, "type": place_type})
        for r in body.get("results", []):
            loc = r["geometry"]["location"]
            found[r["place_id"]] = GoogleStopCandidate(
                place_id=r["place_id"], name=r.get("name", ""), lat=loc["lat"], lon=loc["lng"]
            )
    return list(found.values())


def nearby_bus_stops_along_line(line_lonlat: list[tuple[float, float]]) -> list[GoogleStopCandidate]:
    """Samples real points along a route's real geometry at fixed spacing and runs a
    Places search at each, merging duplicates by place_id. This is how a route with
    only 2-3 OSM-tagged stops (the finding for this network — 38 tagged stops across
    62 real CTU relations) gets densified toward its actual real-world stop count.
    """
    if not is_configured():
        return []

    length = line_length_m(line_lonlat)
    if length == 0:
        return []

    found: dict[str, GoogleStopCandidate] = {}
    dist = 0.0
    while dist <= length:
        lon, lat = interpolate_point_at_distance(line_lonlat, dist)
        for cand in nearby_bus_stops(lat, lon, radius_m=CORRIDOR_SEARCH_RADIUS_M):
            found[cand.place_id] = cand
        dist += CORRIDOR_SAMPLE_SPACING_M
    return list(found.values())


def segment_duration(
    origin_lonlat: tuple[float, float], dest_lonlat: tuple[float, float], *, departure_time: str = "now"
) -> GoogleSegmentDuration | None:
    """Real, traffic-conditioned travel duration between two points — stronger
    calibration signal for the simulator's base_speed than OSRM's free-flow-only
    estimate. Returns None if unconfigured or the API can't route it, so callers
    fall back to `app.osrm.segment_baseline` (see enrich.enrich_segment_baselines).
    """
    if not is_configured():
        return None

    origin = f"{origin_lonlat[1]},{origin_lonlat[0]}"
    dest = f"{dest_lonlat[1]},{dest_lonlat[0]}"
    body = _get(
        DISTANCE_MATRIX_URL,
        {"origins": origin, "destinations": dest, "mode": "driving", "departure_time": departure_time},
    )
    try:
        element = body["rows"][0]["elements"][0]
    except (KeyError, IndexError):
        return None
    if element.get("status") != "OK":
        return None

    return GoogleSegmentDuration(
        duration_sec=element["duration"]["value"],
        duration_in_traffic_sec=(element.get("duration_in_traffic") or {}).get("value"),
        distance_m=element["distance"]["value"],
    )
