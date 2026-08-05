import { config } from './config';
import type { MapMatchedPosition, RawGpsPing } from './mapMatch';

export interface EtaResult {
  busId: string;
  etaSeconds: number;
}

// Batched ~1x/sec across active buses in production (see solution doc section 5.1 step 4),
// not called per-ping, to keep ml-service load proportional to fleet size.
export async function scoreEta(ping: RawGpsPing, matched: MapMatchedPosition): Promise<EtaResult> {
  const res = await fetch(`${config.mlServiceUrl}/eta/predict`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      bus_id: ping.busId,
      route_id: ping.routeId,
      segment_avg_speed_7d: ping.speedKmh,
      segment_avg_speed_30d: ping.speedKmh,
      time_of_day_bucket: new Date(ping.timestamp).getHours(),
      day_of_week: new Date(ping.timestamp).getDay(),
      distance_to_stop_m: matched.distanceToNextStopM,
      current_delay_sec: 0,
      weather_bucket: 0,
      upcoming_stop_dwell_prior_sec: 30,
      live_traffic_factor: 1,
    }),
  });

  const body = (await res.json()) as { eta_seconds: number };
  return { busId: ping.busId, etaSeconds: body.eta_seconds };
}
