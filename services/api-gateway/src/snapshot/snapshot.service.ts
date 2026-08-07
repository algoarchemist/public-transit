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

/** Every real stop in the snapshot, with every direction that serves it — the
 * passenger app's origin/destination picker (route_search_screen.dart) searches
 * this by name rather than needing a location fix, unlike `stopsNear`. */
export interface AllStop {
  osmNodeId: number;
  name: string | null;
  lat: number;
  lon: number;
  routes: ServingRoute[];
}

interface SegmentSummary {
  sequence: number;
  lengthM: number;
  baselineSec: number | null;
}

/** A single real direct route (no transfers) between two real stops that share a
 * direction, with a real distance and — where every segment between them has a
 * real OSRM baseline — a real duration. `durationSec` is null rather than guessed
 * when a baseline is missing for any covered segment; callers must not fabricate
 * a number to fill the gap (same rule as everywhere else real data is partial in
 * this system — see docs/IMPLEMENTATION_ARCHITECTURE.md's honesty conventions).
 * There is deliberately no fare here: ticketing was descoped (docs §10), so no
 * real price exists to report. */
export interface JourneyOption {
  directionId: string;
  routeId: string | null;
  routeName: string | null;
  fromStopId: number;
  toStopId: number;
  stopsBetween: number;
  distanceM: number;
  durationSec: number | null;
}

interface LoadedSnapshot {
  routesByDirection: Map<string, RouteSummary>;
  stopsByDirection: Map<string, StopSummary[]>;
  segmentsByDirection: Map<string, SegmentSummary[]>;
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
    const segments: GeoJsonCollection = JSON.parse(
      fs.readFileSync(path.join(dir, 'segments.geojson'), 'utf-8'),
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

    // Real per-segment length + OSRM baseline duration (stream-processor's
    // routeStore.ts reads the identical file for the live pipeline — same
    // property names, deliberately not re-derived a second way).
    const segmentsByDirection = new Map<string, SegmentSummary[]>();
    for (const f of segments.features) {
      const directionId: string = f.properties.direction_id;
      const list = segmentsByDirection.get(directionId) ?? [];
      list.push({
        sequence: f.properties.sequence,
        lengthM: f.properties.length_m,
        baselineSec: f.properties.baseline_sec ?? null,
      });
      segmentsByDirection.set(directionId, list);
    }
    for (const list of segmentsByDirection.values()) {
      list.sort((a, b) => a.sequence - b.sequence);
    }

    this.loaded = {
      routesByDirection,
      stopsByDirection,
      segmentsByDirection,
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

  /** Every real stop in the snapshot, name-sorted — the passenger app's
   * origin/destination search (route_search_screen.dart) filters this client-side
   * by name rather than needing a `GET /stops/nearby` location fix, since picking
   * a departure/arrival stop by typing its name has nothing to do with where the
   * phone currently is. Same one-row-per-physical-stop collapse as `stopsNear`. */
  listAllStops(): AllStop[] {
    const byNode = new Map<number, AllStop>();
    for (const [directionId, stops] of this.snapshot().stopsByDirection) {
      const route = this.snapshot().routesByDirection.get(directionId);
      for (const stop of stops) {
        const serving = { directionId, routeId: route?.routeId ?? null, routeName: route?.name ?? null, sequence: stop.sequence };
        const existing = byNode.get(stop.osmNodeId);
        if (existing) existing.routes.push(serving);
        else byNode.set(stop.osmNodeId, { osmNodeId: stop.osmNodeId, name: stop.name, lat: stop.lat, lon: stop.lon, routes: [serving] });
      }
    }
    return [...byNode.values()].sort((a, b) => (a.name ?? `Stop ${a.osmNodeId}`).localeCompare(b.name ?? `Stop ${b.osmNodeId}`));
  }

  /**
   * Direct (single-route, no-transfer) journeys between two real stops — the
   * passenger app's "Find Routes" search. Only considers directions that serve
   * both stops with the origin strictly before the destination in sequence;
   * multi-route transfers aren't attempted (no fare/transfer model exists to
   * price one anyway, ticketing is descoped — docs §10).
   *
   * `distanceM` sums real `route_segments.length_m` between the two stops;
   * `durationSec` sums real OSRM `baseline_sec` the same way, but only when every
   * covered segment actually has one — a partial sum would understate the trip
   * and look like a real number when it isn't, so the whole field is null instead
   * (same rule etaScoringLoop.ts's fallback logging follows on the live-tracking
   * side: an honest gap beats a plausible-looking guess).
   */
  findJourneys(fromOsmNodeId: number, toOsmNodeId: number): JourneyOption[] {
    const results: JourneyOption[] = [];

    for (const [directionId, stops] of this.snapshot().stopsByDirection) {
      const fromStop = stops.find((s) => s.osmNodeId === fromOsmNodeId);
      const toStop = stops.find((s) => s.osmNodeId === toOsmNodeId);
      if (!fromStop || !toStop || fromStop.sequence >= toStop.sequence) continue;

      const covered = (this.snapshot().segmentsByDirection.get(directionId) ?? []).filter(
        (seg) => seg.sequence >= fromStop.sequence && seg.sequence < toStop.sequence,
      );
      if (covered.length === 0) continue;

      const distanceM = covered.reduce((sum, s) => sum + s.lengthM, 0);
      const allHaveBaseline = covered.every((s) => s.baselineSec !== null);
      const durationSec = allHaveBaseline ? covered.reduce((sum, s) => sum + (s.baselineSec ?? 0), 0) : null;
      const route = this.snapshot().routesByDirection.get(directionId);

      results.push({
        directionId,
        routeId: route?.routeId ?? null,
        routeName: route?.name ?? null,
        fromStopId: fromStop.osmNodeId,
        toStopId: toStop.osmNodeId,
        stopsBetween: toStop.sequence - fromStop.sequence,
        distanceM,
        durationSec,
      });
    }

    // Real duration first when known; unknown-duration matches sort after every
    // known one rather than being (falsely) treated as instant.
    return results.sort((a, b) => (a.durationSec ?? Infinity) - (b.durationSec ?? Infinity));
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
