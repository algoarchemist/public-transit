"""Shared ETA feature contract (docs/IMPLEMENTATION_ARCHITECTURE.md §6.1): the one
place that defines the model's input layout, imported by both the training pipeline
(train/train_eta.py, computing these from historical backfill data) and the serving
path (models/eta.py, receiving them pre-computed on each request). Neither path
computes a feature a second, independently-drifting way.

Known gap this module does not fix: `services/stream-processor/src/etaClient.ts` —
the only real caller today — does not yet compute real values for most of these. It
sends the live ping's own instantaneous speed as BOTH segment_avg_speed_7d and
segment_avg_speed_30d, current_delay_sec=0, weather_bucket=0,
upcoming_stop_dwell_prior_sec=30 (flat constant), live_traffic_factor=1 (neutral) —
see docs §7.3 items 2-3, both marked "not yet built". Training against real
historical aggregates (this module's contract) is still the correct thing to do, but
the model cannot realize its accuracy gain in production until that TS-side
computation is built to actually match what it's being trained against here.
"""
from __future__ import annotations

FEATURE_COLUMNS: tuple[str, ...] = (
    "segment_avg_speed_7d",
    "segment_avg_speed_30d",
    "time_of_day_bucket",
    "day_of_week",
    "distance_to_stop_m",
    "current_delay_sec",
    "weather_bucket",
    "upcoming_stop_dwell_prior_sec",
    "live_traffic_factor",
)


def feature_vector(req: object) -> list[float]:
    """`req` is anything exposing FEATURE_COLUMNS as plain-number attributes —
    EtaRequest at serve time, a training-set row (namedtuple/Series) at train time.
    Order matches the ONNX model's input tensor exactly; changing FEATURE_COLUMNS
    means retraining, since onnxmltools bakes the column order into the graph."""
    return [float(getattr(req, col)) for col in FEATURE_COLUMNS]
