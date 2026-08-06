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
// emits — see consumer.ts's handlePing (real-ping path) and deadReckoning.ts's
// EstimatedPosition (watchdog path). Kept as one type with etaSeconds optional
// rather than a discriminated union: the wire has no `kind` field to narrow on,
// and a fresh ETA score is the only field that differs between the two paths.
export type ConfidenceTier = 'live' | 'estimated' | 'stale';

export interface BusState {
  busId: string;
  routeId: string;
  directionId: string;
  lat: number;
  lon: number;
  occupancy: number | null;
  /** Present on real pings; absent on dead-reckoned watchdog updates. */
  etaSeconds?: number;
  nextStopId: string | null;
  nextStopName: string | null;
  distanceToNextStopM: number;
  confidenceTier: ConfidenceTier;
  /** Human-facing status text, e.g. "live" or "estimated position — signal lost 42s ago". */
  badge: string;
  updatedAt: number;
}
