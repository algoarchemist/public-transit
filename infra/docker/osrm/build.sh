#!/usr/bin/env bash
# Rebuilds the self-hosted OSRM routing graph for the Chandigarh Tricity bbox
# (Mohali/Kharar/Zirakpur/Dera Bassi — matches the bbox geo-ingest uses, see
# services/geo-ingest/README.md). Re-run this whenever the bbox changes or the
# underlying OSM data goes stale; `docker compose up osrm` just serves the output.
set -euo pipefail
cd "$(dirname "$0")/data"

BBOX="30.60,76.65,30.95,76.90"
IMAGE="ghcr.io/project-osrm/osrm-backend"

echo "Fetching OSM extract for bbox $BBOX from Overpass..."
curl -sS -X POST -d @- https://overpass-api.de/api/interpreter -o tricity.osm --max-time 180 <<EOF
[out:xml][timeout:170];
(
  way["highway"]($BBOX);
);
(._;>;);
out body;
EOF

rm -f tricity.osrm*

echo "Extracting (car profile)..."
MSYS_NO_PATHCONV=1 docker run --rm -t -v "$PWD:/data" "$IMAGE" osrm-extract -p /opt/car.lua /data/tricity.osm

echo "Partitioning..."
MSYS_NO_PATHCONV=1 docker run --rm -t -v "$PWD:/data" "$IMAGE" osrm-partition /data/tricity.osrm

echo "Customizing..."
MSYS_NO_PATHCONV=1 docker run --rm -t -v "$PWD:/data" "$IMAGE" osrm-customize /data/tricity.osrm

echo "Done. Start it with: docker compose up -d osrm"
