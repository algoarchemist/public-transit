/**
 * Loads the geo-ingest snapshot (data/snapshots/<label>/{routes,stops,segments}.geojson
 * — real OSM route geometry, real stops, real OSRM segment baselines, see
 * services/geo-ingest/README.md) into memory, indexed per `direction_id`.
 *
 * This is what closes the mapMatch.ts stub and gives the degradation ladder
 * (deadReckoning.ts) real geometry + real segment speeds to extrapolate against,
 * instead of freezing or guessing when a bus goes dark.
 */
import fs from 'node:fs';
import path from 'node:path';
import { config } from './config';
import { type LonLat, polylineLengthM, projectOntoPolyline, pointAtDistanceAlongPolyline } from './geo';

export interface RouteSegmentInfo {
  sequence: number;
  fromStopId: number | null;
  fromStopName: string | null;
  toStopId: number | null;
  toStopName: string | null;
  geometry: LonLat[];
  lengthM: number;
  baselineSec: number | null;
  avgSpeedMps: number | null;
  fromDistAlongRouteM: number;
  toDistAlongRouteM: number;
}

export interface RouteStopInfo {
  sequence: number;
  osmNodeId: number;
  name: string | null;
  lat: number;
  lon: number;
  distAlongRouteM: number;
}

export interface RouteDirection {
  directionId: string;
  routeId: string | null; // GTFS ref, shared by both directions
  name: string | null;
  geometry: LonLat[];
  totalLengthM: number;
  stops: RouteStopInfo[];
  segments: RouteSegmentInfo[];
}

interface GeoJsonFeature<P> {
  type: 'Feature';
  geometry: { type: string; coordinates: any };
  properties: P;
}

interface GeoJsonCollection<P> {
  type: 'FeatureCollection';
  features: GeoJsonFeature<P>[];
}

function repoRoot(): string {
  // src/routeStore.ts and dist/routeStore.js are both two levels inside
  // services/stream-processor, so this resolves correctly either way.
  return path.resolve(__dirname, '..', '..', '..');
}

function toLonLatLine(coords: [number, number][]): LonLat[] {
  return coords.map(([lon, lat]) => ({ lon, lat }));
}

let cache: Map<string, RouteDirection> | null = null;

/** Reads and indexes the snapshot once per process; subsequent calls are free. */
export function loadSnapshot(label: string = config.snapshotLabel): Map<string, RouteDirection> {
  if (cache) return cache;

  const dir = path.join(repoRoot(), 'data', 'snapshots', label);
  const routes: GeoJsonCollection<any> = JSON.parse(
    fs.readFileSync(path.join(dir, 'routes.geojson'), 'utf-8'),
  );
  const stops: GeoJsonCollection<any> = JSON.parse(
    fs.readFileSync(path.join(dir, 'stops.geojson'), 'utf-8'),
  );
  const segments: GeoJsonCollection<any> = JSON.parse(
    fs.readFileSync(path.join(dir, 'segments.geojson'), 'utf-8'),
  );

  const byDirection = new Map<string, RouteDirection>();

  for (const routeFeature of routes.features) {
    const directionId: string = routeFeature.properties.direction_id;
    const geometry = toLonLatLine(routeFeature.geometry.coordinates);

    const segFeatures = segments.features
      .filter((f) => f.properties.direction_id === directionId)
      .sort((a, b) => a.properties.sequence - b.properties.sequence);

    let cumulative = 0;
    const segs: RouteSegmentInfo[] = segFeatures.map((f) => {
      const lengthM: number = f.properties.length_m;
      const fromDist = cumulative;
      cumulative += lengthM;
      const baselineSec: number | null = f.properties.baseline_sec;
      return {
        sequence: f.properties.sequence,
        fromStopId: f.properties.from_stop_id,
        fromStopName: f.properties.from_stop_name,
        toStopId: f.properties.to_stop_id,
        toStopName: f.properties.to_stop_name,
        geometry: toLonLatLine(f.geometry.coordinates),
        lengthM,
        baselineSec,
        avgSpeedMps: baselineSec ? lengthM / baselineSec : null,
        fromDistAlongRouteM: fromDist,
        toDistAlongRouteM: cumulative,
      };
    });

    const stopFeatures = stops.features
      .filter((f) => f.properties.direction_id === directionId)
      .sort((a, b) => a.properties.sequence - b.properties.sequence);

    const stopInfos: RouteStopInfo[] = stopFeatures.map((f, i) => ({
      sequence: f.properties.sequence,
      osmNodeId: f.properties.osm_node_id,
      name: f.properties.name,
      lon: f.geometry.coordinates[0],
      lat: f.geometry.coordinates[1],
      distAlongRouteM: i === 0 ? 0 : (segs[i - 1]?.toDistAlongRouteM ?? 0),
    }));

    byDirection.set(directionId, {
      directionId,
      routeId: routeFeature.properties.ref,
      name: routeFeature.properties.name,
      geometry,
      totalLengthM: routeFeature.properties.length_m ?? polylineLengthM(geometry),
      stops: stopInfos,
      segments: segs,
    });
  }

  cache = byDirection;
  return byDirection;
}

export function getDirection(directionId: string): RouteDirection | undefined {
  return loadSnapshot().get(directionId);
}

/** Which stop-to-stop segment covers a given cumulative distance along the route. */
export function findSegmentAtDistance(direction: RouteDirection, distAlongRouteM: number): RouteSegmentInfo | null {
  for (const seg of direction.segments) {
    if (distAlongRouteM <= seg.toDistAlongRouteM) return seg;
  }
  return direction.segments[direction.segments.length - 1] ?? null;
}

/** The next stop (and distance to it) given a position expressed as distance-along-route. */
export function nextStopFrom(
  direction: RouteDirection,
  distAlongRouteM: number,
): { stop: RouteStopInfo | null; distanceToStopM: number } {
  for (const stop of direction.stops) {
    if (stop.distAlongRouteM >= distAlongRouteM) {
      return { stop, distanceToStopM: stop.distAlongRouteM - distAlongRouteM };
    }
  }
  const last = direction.stops[direction.stops.length - 1] ?? null;
  return { stop: last, distanceToStopM: 0 };
}

export interface MatchResult {
  distAlongRouteM: number;
  offsetM: number;
  fractionComplete: number;
  segment: RouteSegmentInfo | null;
  nextStop: RouteStopInfo | null;
  distanceToNextStopM: number;
}

/** Projects a raw GPS fix onto the direction's real route geometry. */
export function matchPoint(directionId: string, point: LonLat): MatchResult | null {
  const direction = getDirection(directionId);
  if (!direction || direction.geometry.length < 2) return null;

  const projection = projectOntoPolyline(point, direction.geometry);
  const segment = findSegmentAtDistance(direction, projection.distAlongLineM);
  const { stop, distanceToStopM } = nextStopFrom(direction, projection.distAlongLineM);

  return {
    distAlongRouteM: projection.distAlongLineM,
    offsetM: projection.offsetM,
    fractionComplete: direction.totalLengthM > 0 ? projection.distAlongLineM / direction.totalLengthM : 0,
    segment,
    nextStop: stop,
    distanceToNextStopM: distanceToStopM,
  };
}

export function pointAtDistance(directionId: string, distAlongRouteM: number): LonLat | null {
  const direction = getDirection(directionId);
  if (!direction) return null;
  return pointAtDistanceAlongPolyline(direction.geometry, distAlongRouteM);
}
