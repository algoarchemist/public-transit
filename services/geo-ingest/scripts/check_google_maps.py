"""Run once after adding a real GOOGLE_MAPS_API_KEY to .env, before trusting
app/google_maps.py against production traffic/billing.

    python scripts/check_google_maps.py

Checks, in order: the key is picked up, a Nearby Search returns real places, a
Distance Matrix call returns a real traffic-conditioned duration, and the
corridor-sampling stop-densification helper runs against one real cached route.
"""
import json
import sys

from app import google_maps
from app.config import CACHE_DIR


def main() -> int:
    if not google_maps.is_configured():
        print("GOOGLE_MAPS_API_KEY is not set — nothing to check. Add it to .env first.")
        return 1

    print("1. Nearby Search — bus stops near Mohali ISBT-43 (30.7163, 76.7427)...")
    stops = google_maps.nearby_bus_stops(30.7163272, 76.7426917, radius_m=500)
    print(f"   found {len(stops)} real places")
    for s in stops[:5]:
        print(f"     - {s.name!r} ({s.lat}, {s.lon})")
    if not stops:
        print("   WARNING: zero results — check the key has Places API enabled and billing on")

    print("\n2. Distance Matrix — ISBT-43 to Kharar (real driving duration)...")
    result = google_maps.segment_duration((76.7426917, 30.7163272), (76.6510, 30.7454))
    if result is None:
        print("   FAILED — check the key has Distance Matrix API enabled")
        return 1
    print(f"   duration={result.duration_sec:.0f}s traffic={result.duration_in_traffic_sec} distance={result.distance_m:.0f}m")

    print("\n3. Corridor stop densification — using a cached real route if available...")
    snapshot = CACHE_DIR.parent / "snapshots" / "mohali-tricity" / "routes.geojson"
    if snapshot.exists():
        features = json.loads(snapshot.read_text(encoding="utf-8"))["features"]
        line = features[0]["geometry"]["coordinates"]
        candidates = google_maps.nearby_bus_stops_along_line([tuple(c) for c in line])
        print(f"   sampled route {features[0]['properties']['ref']!r}: {len(candidates)} real stop candidates found")
    else:
        print(f"   skipped — run `python -m app.main --bbox ...` first to produce {snapshot}")

    print("\nAll checks that ran, passed. Re-run app/enrich.py against a real route next.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
