from pydantic import BaseModel


class EtaRequest(BaseModel):
    bus_id: str
    route_id: str
    segment_avg_speed_7d: float
    segment_avg_speed_30d: float
    time_of_day_bucket: int
    day_of_week: int
    distance_to_stop_m: float
    current_delay_sec: float
    weather_bucket: int
    upcoming_stop_dwell_prior_sec: float
    live_traffic_factor: float


class EtaResponse(BaseModel):
    bus_id: str
    stop_id: str | None = None
    eta_seconds: float
    model: str = "gbm-v0"


class CrowdRequest(BaseModel):
    bus_id: str
    route_id: str
    stop_id: str
    time_of_day_bucket: int
    day_of_week: int
    current_occupancy: int


class CrowdResponse(BaseModel):
    bus_id: str
    stop_id: str
    predicted_boarding: float
    predicted_alighting: float
    model: str = "gbm-v0"
