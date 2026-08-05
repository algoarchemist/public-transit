export interface RawGpsPing {
  busId: string;
  routeId: string;
  lat: number;
  lon: number;
  speedKmh: number;
  occupancy: number;
  timestamp: number;
}

export interface MapMatchedPosition {
  busId: string;
  routeId: string;
  routeFractionComplete: number;
  distanceToNextStopM: number;
  nextStopId: string | null;
}

// TODO: replace with a PostGIS query (ST_LineLocatePoint / ST_ClosestPoint against the
// route's stored LINESTRING geometry) so noisy raw GPS snaps onto the correct route.
export async function mapMatch(ping: RawGpsPing): Promise<MapMatchedPosition> {
  return {
    busId: ping.busId,
    routeId: ping.routeId,
    routeFractionComplete: 0,
    distanceToNextStopM: 0,
    nextStopId: null,
  };
}
