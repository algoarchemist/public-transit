import { Injectable } from '@nestjs/common';
import fs from 'node:fs';
import path from 'node:path';

// TODO: back with PostGIS-backed Route/Stop entities (geometry columns,
// ST_LineLocatePoint for map-matching) instead of in-memory stubs.

export interface GeoJsonFeature {
  type: 'Feature';
  geometry: { type: string; coordinates: unknown };
  properties: Record<string, any>;
}

export interface GeoJsonCollection {
  type: 'FeatureCollection';
  features: GeoJsonFeature[];
}

function repoRoot(): string {
  // src/routes/routes.service.ts and dist/routes/routes.service.js are both
  // four levels inside the repo root, so this resolves correctly either way.
  return path.resolve(__dirname, '..', '..', '..', '..');
}

let routesSnapshotCache: GeoJsonCollection | null = null;

/** Reads the geo-ingest snapshot's real route polylines once per process; see
 * services/stream-processor/src/routeStore.ts for the same pattern used against
 * the live pipeline. */
function loadRoutesSnapshot(): GeoJsonCollection {
  if (routesSnapshotCache) return routesSnapshotCache;
  const label = process.env.SNAPSHOT_LABEL ?? 'mohali-tricity';
  const file = path.join(repoRoot(), 'data', 'snapshots', label, 'routes.geojson');
  routesSnapshotCache = JSON.parse(fs.readFileSync(file, 'utf-8'));
  return routesSnapshotCache!;
}

@Injectable()
export class RoutesService {
  findAll() {
    return [];
  }

  findOne(id: string) {
    return { id, name: null, stops: [] };
  }

  stops(id: string) {
    return { routeId: id, stops: [] };
  }

  performance(id: string) {
    return { routeId: id, onTimePercent: null, avgDelaySec: null, problemSegments: [] };
  }

  /** GeoJSON FeatureCollection of every route direction's real polyline (one
   * LineString per direction, 206 features for the mohali-tricity snapshot) — for
   * the admin dashboard's live fleet map overlay. Properties trimmed to what the
   * map actually uses. */
  geometry(): GeoJsonCollection {
    const snapshot = loadRoutesSnapshot();
    return {
      type: 'FeatureCollection',
      features: snapshot.features.map((f) => ({
        type: 'Feature',
        geometry: f.geometry,
        properties: {
          direction_id: f.properties.direction_id,
          route_id: f.properties.route_id ?? f.properties.ref ?? null,
          name: f.properties.name ?? null,
        },
      })),
    };
  }
}
