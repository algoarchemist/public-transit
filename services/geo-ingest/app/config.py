import os
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
CACHE_DIR = REPO_ROOT / "data" / "cache"
SNAPSHOT_DIR = REPO_ROOT / "data" / "snapshots"


@dataclass
class Settings:
    overpass_url: str = os.environ.get("OVERPASS_URL", "https://overpass-api.de/api/interpreter")
    # Swap to a self-hosted instance once Docker/OSRM is up (see docs/IMPLEMENTATION_ARCHITECTURE.md §4.2) —
    # the public demo server is not for batch use and will throttle a full-city enrichment pass.
    osrm_url: str = os.environ.get("OSRM_URL", "https://router.project-osrm.org")
    # Optional upgrade over the free OSRM/OSM path: denser real stop discovery (Places
    # Nearby Search) and traffic-conditioned segment durations (Distance Matrix). Every
    # app.google_maps function no-ops (returns None/[]) when this is unset, so the
    # pipeline's default remains the free OSRM/OSM path validated in Phase 1.
    google_maps_api_key: str | None = os.environ.get("GOOGLE_MAPS_API_KEY")
    database_url: str | None = os.environ.get("DATABASE_URL")
    request_timeout_sec: float = 60.0
    max_concurrent_osrm_requests: int = 2


settings = Settings()
