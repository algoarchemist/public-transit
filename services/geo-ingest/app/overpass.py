"""Overpass API client: city area resolution, bus route relation discovery,
bus stop discovery. Every raw response is cached to disk keyed by query hash —
Overpass allows only 2 concurrent slots on the public instance, so an uncached
pipeline both throttles itself and is not reproducible across runs.
"""
from __future__ import annotations

import hashlib
import json
import time
from pathlib import Path

import httpx
from tenacity import retry, stop_after_attempt, wait_exponential

from app.config import CACHE_DIR, settings


def _cache_path(query: str) -> Path:
    digest = hashlib.sha256(query.encode()).hexdigest()[:24]
    return CACHE_DIR / f"overpass_{digest}.json"


# Per Overpass API etiquette (https://wiki.openstreetmap.org/wiki/Overpass_API) a
# descriptive User-Agent is expected. In practice the public instance's front end also
# intermittently 406s/504s generic HTTP clients under load — retried like any other
# transient failure, since it clears on retry rather than being a hard block.
_HEADERS = {"User-Agent": "SetuTrack-geo-ingest/0.1 (SIH25013 hackathon project)"}


@retry(stop=stop_after_attempt(6), wait=wait_exponential(multiplier=2, min=2, max=45))
def _post(query: str) -> dict:
    resp = httpx.post(
        settings.overpass_url,
        data={"data": query},
        headers=_HEADERS,
        timeout=settings.request_timeout_sec,
    )
    if resp.status_code in (406, 429, 504):
        raise httpx.HTTPStatusError(
            f"transient overpass error {resp.status_code}", request=resp.request, response=resp
        )
    resp.raise_for_status()
    return resp.json()


def run_query(query: str, *, use_cache: bool = True) -> dict:
    cache_file = _cache_path(query)
    if use_cache and cache_file.exists():
        return json.loads(cache_file.read_text(encoding="utf-8"))

    data = _post(query)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_file.write_text(json.dumps(data), encoding="utf-8")
    # Be a polite client even when the cache misses repeatedly across a batch run.
    time.sleep(1)
    return data


def resolve_city_area_id(city_name: str, state_name: str = "Punjab") -> int:
    """Returns an Overpass area id (relation_id + 3600000000) for the city boundary.

    Tries `place=city|town|municipality` first (best match for Indian small-city
    admin boundaries), falls back to any `boundary=administrative` with a matching
    name inside the given state.
    """
    query = f"""
    [out:json][timeout:{int(settings.request_timeout_sec)}];
    area["name"="{state_name}"]["admin_level"="4"]->.state;
    (
      relation(area.state)["name"="{city_name}"]["place"~"city|town|municipality"];
      relation(area.state)["name"="{city_name}"]["boundary"="administrative"];
    );
    out ids tags;
    """
    result = run_query(query)
    elements = result.get("elements", [])
    if not elements:
        raise ValueError(
            f"No OSM administrative area found for '{city_name}' in '{state_name}' — "
            "try a different city or check spelling against OSM."
        )
    # Prefer an exact `place` match over a generic administrative boundary.
    for el in elements:
        if el.get("tags", {}).get("place") in ("city", "town", "municipality"):
            return 3600000000 + el["id"]
    return 3600000000 + elements[0]["id"]


def fetch_bus_route_relations(area_id: int) -> list[dict]:
    """Bus route relations with full inline geometry for every member (nodes and ways)."""
    query = f"""
    [out:json][timeout:{int(settings.request_timeout_sec)}];
    area({area_id})->.searchArea;
    relation(area.searchArea)["type"="route"]["route"="bus"];
    out geom;
    """
    result = run_query(query)
    return result.get("elements", [])


def fetch_relations_by_id(relation_ids: list[int]) -> list[dict]:
    """Full inline geometry for specific relation IDs, bypassing area-boundary matching.

    Used when a network of interest (e.g. the Chandigarh Tricity's CTU routes) is
    already known from a broader survey and doesn't cleanly fit inside one city's
    admin polygon — some termini legitimately sit across a state/UT boundary.
    """
    id_list = ",".join(str(i) for i in relation_ids)
    query = f"""
    [out:json][timeout:{int(settings.request_timeout_sec)}];
    relation(id:{id_list});
    out geom;
    """
    result = run_query(query)
    return result.get("elements", [])


def fetch_bus_stop_nodes_bbox(south: float, west: float, north: float, east: float) -> list[dict]:
    """All bus stop / platform nodes within a raw bounding box, bypassing admin-area
    name resolution. Needed when a real network (e.g. CTU/tricity) spans multiple named
    admin units (Chandigarh UT, Mohali, Kharar) that don't resolve as one OSM area.
    """
    query = f"""
    [out:json][timeout:{int(settings.request_timeout_sec)}];
    (
      node({south},{west},{north},{east})["highway"="bus_stop"];
      node({south},{west},{north},{east})["public_transport"="platform"];
    );
    out body;
    """
    result = run_query(query)
    return result.get("elements", [])


def fetch_bus_stop_nodes(area_id: int) -> list[dict]:
    """All bus stop / platform nodes in the city, independent of route relation membership.

    This is the ground truth used for Path B (no relation exists) and for POI-density
    footfall priors regardless of path.
    """
    query = f"""
    [out:json][timeout:{int(settings.request_timeout_sec)}];
    area({area_id})->.searchArea;
    (
      node(area.searchArea)["highway"="bus_stop"];
      node(area.searchArea)["public_transport"="platform"];
    );
    out body;
    """
    result = run_query(query)
    return result.get("elements", [])


def fetch_poi_density_points(area_id: int) -> list[dict]:
    """Markets, schools, hospitals — used to derive `footfall_prior` per stop (see
    docs/IMPLEMENTATION_ARCHITECTURE.md §3.1). Real POI density, not a guessed constant.
    """
    query = f"""
    [out:json][timeout:{int(settings.request_timeout_sec)}];
    area({area_id})->.searchArea;
    (
      node(area.searchArea)["shop"~"supermarket|mall|marketplace"];
      node(area.searchArea)["amenity"~"school|college|hospital|marketplace|bus_station"];
    );
    out body;
    """
    result = run_query(query)
    return result.get("elements", [])
