export interface RawGpsPing {
  busId: string;
  routeId: string;
  lat: number;
  lon: number;
  speedKmh: number;
  occupancy: number;
  timestamp: number;
}

// Matches the real `bus:update` Socket.IO payload stream-processor's gateway.ts
// emits — see consumer.ts's handlePing (real-ping path), etaScoringLoop.ts (the
// once-per-second batch ETA refresh, docs §6.4/§7.3) and deadReckoning.ts's
// EstimatedPosition (watchdog path). Kept as one type with etaSeconds/upcomingStops
// optional rather than a discriminated union: the wire has no `kind` field to
// narrow on, and a fresh ETA score is what differs between the paths.
export type ConfidenceTier = 'live' | 'estimated' | 'stale';

export interface UpcomingStopEta {
  stopId: string;
  stopName: string | null;
  /** Cumulative seconds from now, including predicted dwell at intermediate stops. */
  etaSeconds: number;
}

export interface BusState {
  busId: string;
  routeId: string;
  directionId: string;
  lat: number;
  lon: number;
  occupancy: number | null;
  /** Convenience alias for upcomingStops[0]?.etaSeconds. Present once the batch
   * scorer (etaScoringLoop.ts) has scored this bus at least once; absent before
   * that and on dead-reckoned watchdog updates. */
  etaSeconds?: number;
  /** Next up to 3 stops with cumulative ETAs (docs §6.4: "the passenger UI shows
   * the next three stops"). Same presence rule as etaSeconds. */
  upcomingStops?: UpcomingStopEta[];
  nextStopId: string | null;
  nextStopName: string | null;
  distanceToNextStopM: number;
  confidenceTier: ConfidenceTier;
  /** Human-facing status text, e.g. "live" or "estimated position — signal lost 42s ago". */
  badge: string;
  updatedAt: number;
}
