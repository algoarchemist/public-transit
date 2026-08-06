#!/usr/bin/env bash
# Applies db/migrations/*.sql against the running postgres container, in order,
# tracking applied versions in schema_migrations so re-runs are a no-op.
set -euo pipefail
cd "$(dirname "$0")"

CONTAINER=setutrack-postgres-1
PSQL=(psql -U setutrack -d setutrack -v ON_ERROR_STOP=1)

docker exec -i "$CONTAINER" "${PSQL[@]}" -c \
  "CREATE TABLE IF NOT EXISTS schema_migrations (version text PRIMARY KEY, applied_at timestamptz DEFAULT now());"

for f in migrations/*.sql; do
  version=$(basename "$f")
  applied=$(docker exec -i "$CONTAINER" "${PSQL[@]}" -tAc \
    "SELECT 1 FROM schema_migrations WHERE version = '$version'")
  if [ "$applied" = "1" ]; then
    echo "skip  $version (already applied)"
    continue
  fi
  echo "apply $version"
  docker exec -i "$CONTAINER" "${PSQL[@]}" -f - < "$f"
  docker exec -i "$CONTAINER" "${PSQL[@]}" -c \
    "INSERT INTO schema_migrations (version) VALUES ('$version');"
done
