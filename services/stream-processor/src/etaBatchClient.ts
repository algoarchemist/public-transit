/**
 * Client for ml-service's POST /eta/predict-batch (docs §6.4). Scores every live
 * bus's upcoming segments in ONE HTTP call / ONE model inference, replacing the old
 * per-ping /eta/predict call this file used to make (see git history — that call
 * also sent placeholder features; etaScoringLoop.ts computes real ones from
 * routeStore's loaded OSRM baselines and each bus's live observed speed).
 *
 * Field names here mirror ml-service/app/schemas.py's SegmentEtaFeatures/BusEtaQuery
 * exactly (snake_case, matching the JSON wire format) — this is a wire contract
 * between two languages, not a place to impose TS naming conventions.
 */
import { config } from './config';

export interface SegmentEtaFeatures {
  stop_id: string;
  segment_avg_speed_7d: number;
  segment_avg_speed_30d: number;
  time_of_day_bucket: number;
  day_of_week: number;
  distance_to_stop_m: number;
  current_delay_sec: number;
  weather_bucket: number;
  upcoming_stop_dwell_prior_sec: number;
  live_traffic_factor: number;
}

export interface BusEtaQuery {
  bus_id: string;
  route_id: string;
  segments: SegmentEtaFeatures[];
}

export interface StopEtaResult {
  stop_id: string;
  eta_seconds: number;
}

interface BusEtaBatchResult {
  bus_id: string;
  stops: StopEtaResult[];
}

interface EtaBatchResponse {
  results: BusEtaBatchResult[];
  model: string;
}

/** Empty map on any failure (network error, non-2xx, etc.) — callers treat "no
 * fresh score this tick" as a normal, self-healing condition, not fatal. */
export async function predictEtaBatch(buses: BusEtaQuery[]): Promise<Map<string, StopEtaResult[]>> {
  if (buses.length === 0) return new Map();

  const res = await fetch(`${config.mlServiceUrl}/eta/predict-batch`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ buses }),
  });
  if (!res.ok) {
    throw new Error(`/eta/predict-batch returned ${res.status}`);
  }
  const body = (await res.json()) as EtaBatchResponse;
  return new Map(body.results.map((r) => [r.bus_id, r.stops]));
}
