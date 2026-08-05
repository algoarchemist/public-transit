"""Passenger boarding/alighting prediction (see solution doc section 2.4).
Falls back to a flat time-of-day heuristic until the GBM crowd model is trained.
"""
from pathlib import Path

from app.schemas import CrowdRequest

MODEL_PATH = Path(__file__).resolve().parent.parent.parent / "artifacts" / "crowd_model.onnx"

_session = None
if MODEL_PATH.exists():
    import onnxruntime as ort

    _session = ort.InferenceSession(str(MODEL_PATH))

PEAK_HOUR_BUCKETS = {7, 8, 9, 17, 18, 19}


def predict_boarding_alighting(req: CrowdRequest) -> tuple[float, float]:
    if _session is not None:
        # TODO: map CrowdRequest fields to the model's input tensor layout.
        raise NotImplementedError("wire up ONNX input/output once crowd_model.onnx is trained")

    is_peak = req.time_of_day_bucket in PEAK_HOUR_BUCKETS
    boarding = 14.0 if is_peak else 5.0
    alighting = 6.0 if is_peak else 3.0
    return boarding, alighting
