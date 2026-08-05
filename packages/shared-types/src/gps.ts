export interface RawGpsPing {
  busId: string;
  routeId: string;
  lat: number;
  lon: number;
  speedKmh: number;
  occupancy: number;
  timestamp: number;
}

export type BusStatus = 'on-time' | 'delayed' | 'crowded' | 'signal-lost';

export interface BusState {
  busId: string;
  routeId: string;
  lat: number;
  lon: number;
  occupancy: number;
  etaSeconds: number;
  nextStopId: string | null;
  status: BusStatus;
  updatedAt: number;
}
