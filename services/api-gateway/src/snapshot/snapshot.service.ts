import { Injectable } from '@nestjs/common';
import fs from 'node:fs';
import path from 'node:path';

/**
 * Reads the committed geo-ingest snapshot (`data/snapshots/<label>/`) — the same
 * real OSM/OSRM route geometry the stream-processor map-matches against (see
 * services/stream-processor/src/routeStore.ts, which does the identical load for
 * the live pipeline). This is the api-gateway's read model for everything static:
 * the route list the driver app picks a shift from, per-route stop sequences, and
 * the polyline overlay the admin fleet map renders.
 *
 * Why the snapshot and not Postgres: `routes`/`stops`/`route_stops` in Postgres are
 * written *from* this same snapshot by geo-ingest's persist.py, so both are the same
 * data — but the live pipeline speaks `direction_id` (a string, "r" + OSM relation
 * id), not `routes.id`, and so does the driver app's trip-start payload. Serving the
 * snapshot keeps the API's identifiers identical to the ones the pipeline uses.
 * TripsService is the one place that has to bridge to Postgres integer ids, and it
 * does that explicitly.
 */

export interface GeoJsonFeature {
  type: 'Feature';
  geometry: { type: string; coordinates: unknown };
  properties: Record<string, any>;
}

export interface GeoJsonCollection {
  type: 'FeatureCollection';
  features: GeoJsonFeature[];
}

export interface RouteSummary {
  directionId: string;
  routeId: string | null;
  ref: string | null;
  name: string | null;
  operator: string | null;
  source: string | null;
  osmRelationId: number | null;
  lengthM: number | null;
  stopCount: number;
}

export interface StopSummary {
  sequence: number;
  osmNodeId: number;
  name: string | null;
  lat: number;
  lon: number;
  footfallPrior: number | null;
}

export interface ServingRoute {
  directionId: string;
  routeId: string | null;
  routeName: string | null;
  /** Where this stop falls along that route — ETA-to-this-stop needs it. */
  sequence: number;
}

export interface NearbyStop {
  osmNodeId: number;
  name: string | null;
  lat: number;
  lon: number;
  distanceM: number;
  routes: ServingRoute[];
}

interface LoadedSnapshot {
  routesByDirection: Map<string, RouteSummary>;
  stopsByDirection: Map<string, StopSummary[]>;
  geometry: GeoJsonCollection;
}

function repoRoot(): string {
  // src/snapshot/snapshot.service.ts and dist/snapshot/snapshot.service.js are both
  // four levels inside the repo root, so this resolves correctly either way.
  return path.resolve(__dirname, '..', '..', '..', '..');
}

@Injectable()
export class SnapshotService {
  private loaded: LoadedSnapshot | null = null;

  private get label(): string {
    return process.env.SNAPSHOT_LABEL ?? 'mohali-tricity';
  }

  /** Parsed once per process — the snapshot is a committed build artifact, so it
   * cannot change under a running gateway without a redeploy. */
  private snapshot(): LoadedSnapshot {
    if (this.loaded) return this.loaded;

    const dir = path.join(repoRoot(), 'data', 'snapshots', this.label);
    const routes: GeoJsonCollection = JSON.parse(
      fs.readFileSync(path.join(dir, 'routes.geojson'), 'utf-8'),
    );
    const stops: GeoJsonCollection = JSON.parse(
      fs.readFileSync(path.join(dir, 'stops.geojson'), 'utf-8'),
    );

    const stopsByDirection = new Map<string, StopSummary[]>();
    for (const f of stops.features) {
      const directionId: string = f.properties.direction_id;
      const coords = f.geometry.coordinates as [number, number];
      const list = stopsByDirection.get(directionId) ?? [];
      list.push({
        sequence: f.properties.sequence,
        osmNodeId: f.properties.osm_node_id,
        name: f.properties.name ?? null,
        lon: coords[0],
        lat: coords[1],
        footfallPrior: f.properties.footfall_prior ?? null,
      });
      stopsByDirection.set(directionId, list);
    }
    for (const list of stopsByDirection.values()) {
      list.sort((a, b) => a.sequence - b.sequence);
    }

    const routesByDirection = new Map<string, RouteSummary>();
    for (const f of routes.features) {
      const directionId: string = f.properties.direction_id;
      routesByDirection.set(directionId, {
        directionId,
        routeId: f.properties.route_id ?? f.properties.ref ?? null,
        ref: f.properties.ref ?? null,
        name: f.properties.name ?? null,
        operator: f.properties.operator ?? null,
        source: f.properties.source ?? null,
        osmRelationId: f.properties.osm_relation_id ?? null,
        lengthM: f.properties.length_m ?? null,
        stopCount: stopsByDirection.get(directionId)?.length ?? 0,
      });
    }

    this.loaded = {
      routesByDirection,
      stopsByDirection,
      geometry: {
        type: 'FeatureCollection',
        features: routes.features.map((f) => ({
          type: 'Feature',
          geometry: f.geometry,
          properties: {
            direction_id: f.properties.direction_id,
            route_id: f.properties.route_id ?? f.properties.ref ?? null,
            name: f.properties.name ?? null,
          },
        })),
      },
    };
    return this.loaded;
  }

  listRoutes(): RouteSummary[] {
    return [...this.snapshot().routesByDirection.values()].sort((a, b) =>
      (a.name ?? a.directionId).localeCompare(b.name ?? b.directionId),
    );
  }

  getRoute(directionId: string): RouteSummary | undefined {
    return this.snapshot().routesByDirection.get(directionId);
  }

  stopsFor(directionId: string): StopSummary[] {
    return this.snapshot().stopsByDirection.get(directionId) ?? [];
  }

  /** Every direction's real polyline, for the admin fleet map's route overlay. */
  geometry(): GeoJsonCollection {
    return this.snapshot().geometry;
  }

  /** One direction's polyline. The passenger app draws exactly one route at a time,
   * and the full collection is several MB — far too much for a phone on a 2G-ish
   * connection, which is the whole premise of this project. */
  routeGeometry(directionId: string): GeoJsonFeature | undefined {
    return this.snapshot().geometry.features.find((f) => f.properties.direction_id === directionId);
  }

  /**
   * Real stops within `radiusM` of a point, nearest first.
   *
   * Linear scan over the snapshot's ~620 stop features. That is genuinely fine here
   * — it is one pass over an in-memory array per request, and PostGIS's GiST index
   * only starts paying for itself at a scale this dataset is nowhere near. If the
   * city set grows, `stops_geom_idx` is already in the schema to move this onto.
   *
   * Distance is equirectangular-approximated rather than great-circle: over a
   * neighbourhood-sized radius the error is centimetres, and it avoids a trig-heavy
   * haversine per stop.
   */
  stopsNear(lat: number, lon: number, radiusM: number): NearbyStop[] {
    const metresPerDegLat = 111_320;
    const metresPerDegLon = metresPerDegLat * Math.cos((lat * Math.PI) / 180);
    const byNode = new Map<number, NearbyStop>();

    for (const [directionId, stops] of this.snapshot().stopsByDirection) {
      for (const stop of stops) {
        const dx = (stop.lon - lon) * metresPerDegLon;
        const dy = (stop.lat - lat) * metresPerDegLat;
        const distanceM = Math.hypot(dx, dy);
        if (distanceM > radiusM) continue;

        // One physical stop appears once per direction that serves it. Passengers
        // think in stops, not in (stop, direction) pairs — so collapse to the stop
        // and hang the serving routes off it. `sequence` is kept per route because
        // ETA-to-this-stop needs to know where it falls along each one.
        const existing = byNode.get(stop.osmNodeId);
        const serving = {
          directionId,
          routeId: this.snapshot().routesByDirection.get(directionId)?.routeId ?? null,
          routeName: this.snapshot().routesByDirection.get(directionId)?.name ?? null,
          sequence: stop.sequence,
        };
        if (existing) {
          existing.routes.push(serving);
        } else {
          byNode.set(stop.osmNodeId, {
            osmNodeId: stop.osmNodeId,
            name: stop.name,
            lat: stop.lat,
            lon: stop.lon,
            distanceM,
            routes: [serving],
          });
        }
      }
    }

    return [...byNode.values()].sort((a, b) => a.distanceM - b.distanceM);
  }
}
