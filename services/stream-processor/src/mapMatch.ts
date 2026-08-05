import { matchPoint } from './routeStore';

export interface RawGpsPing {
  busId: string;
  routeId: string;
  directionId: string; // which OSM relation / GTFS trip direction the bus is running
  lat: number;
  lon: number;
  speedKmh: number;
  occupancy: number;
  timestamp: number;
}

export interface MapMatchedPosition {
  busId: string;
  routeId: string;
  directionId: string;
  distAlongRouteM: number;
  routeFractionComplete: number;
  offsetM: number; // perpendicular distance from the raw fix to the matched route line
  distanceToNextStopM: number;
  nextStopId: number | null;
  nextStopName: string | null;
}

/**
 * Projects a raw GPS fix onto the bus's real route geometry (loaded from the
 * geo-ingest snapshot via routeStore.ts) using `ST_LineLocatePoint`-equivalent
 * planar projection, so "% of route completed" and "distance to next stop" are
 * geometrically accurate even with noisy GPS — see
 * docs/IMPLEMENTATION_ARCHITECTURE.md §5.1.3 for the original PostGIS-based design
 * this replaces the stub of; this in-process version is the pre-Docker equivalent.
 */
export async function mapMatch(ping: RawGpsPing): Promise<MapMatchedPosition> {
  const match = matchPoint(ping.directionId, { lon: ping.lon, lat: ping.lat });

  if (!match) {
    // Unknown direction_id (route not in the loaded snapshot) — fail honestly rather
    // than fabricate a position; callers should treat this bus as unmatched.
    return {
      busId: ping.busId,
      routeId: ping.routeId,
      directionId: ping.directionId,
      distAlongRouteM: 0,
      routeFractionComplete: 0,
      offsetM: -1,
      distanceToNextStopM: 0,
      nextStopId: null,
      nextStopName: null,
    };
  }

  return {
    busId: ping.busId,
    routeId: ping.routeId,
    directionId: ping.directionId,
    distAlongRouteM: match.distAlongRouteM,
    routeFractionComplete: match.fractionComplete,
    offsetM: match.offsetM,
    distanceToNextStopM: match.distanceToNextStopM,
    nextStopId: match.nextStop?.osmNodeId ?? null,
    nextStopName: match.nextStop?.name ?? null,
  };
}
