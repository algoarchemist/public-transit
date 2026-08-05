export interface EtaRequest {
  bus_id: string;
  route_id: string;
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

export interface EtaResponse {
  bus_id: string;
  stop_id: string | null;
  eta_seconds: number;
  model: string;
}

export interface CrowdRequest {
  bus_id: string;
  route_id: string;
  stop_id: string;
  time_of_day_bucket: number;
  day_of_week: number;
  current_occupancy: number;
}

export interface CrowdResponse {
  bus_id: string;
  stop_id: string;
  predicted_boarding: number;
  predicted_alighting: number;
  model: string;
}
