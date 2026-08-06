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


class SegmentEtaFeatures(BaseModel):
    """One upcoming segment's features — same fields as EtaRequest minus bus_id/route_id
    (those live once per BusEtaQuery), plus which stop this segment ends at. Field
    names match app.features.FEATURE_COLUMNS exactly so feature_vector() works on
    this too."""
    stop_id: str
    segment_avg_speed_7d: float
    segment_avg_speed_30d: float
    time_of_day_bucket: int
    day_of_week: int
    distance_to_stop_m: float
    current_delay_sec: float
    weather_bucket: int
    upcoming_stop_dwell_prior_sec: float
    live_traffic_factor: float


class BusEtaQuery(BaseModel):
    bus_id: str
    route_id: str
    # Ordered nearest-first: segments[0] is the one the bus is currently on (its
    # distance_to_stop_m should be the REMAINING distance, not the full segment
    # length); segments[1:] are the full upcoming segments to later stops.
    segments: list[SegmentEtaFeatures]


class EtaBatchRequest(BaseModel):
    buses: list[BusEtaQuery]


class StopEta(BaseModel):
    stop_id: str
    eta_seconds: float  # cumulative from now, including predicted dwell at intermediate stops


class BusEtaBatchResult(BaseModel):
    bus_id: str
    stops: list[StopEta]


class EtaBatchResponse(BaseModel):
    results: list[BusEtaBatchResult]
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
