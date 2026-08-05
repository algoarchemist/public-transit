"""ETA prediction: GBM-on-features model, falling back to the naive
distance/avg-speed baseline until a trained ONNX model is exported (see
SIH25013_TrackMyRide_Solution.md section 2.3).
"""
from pathlib import Path

from app.schemas import EtaRequest

MODEL_PATH = Path(__file__).resolve().parent.parent.parent / "artifacts" / "eta_model.onnx"

_session = None
if MODEL_PATH.exists():
    import onnxruntime as ort

    _session = ort.InferenceSession(str(MODEL_PATH))


def predict_eta_seconds(req: EtaRequest) -> float:
    if _session is not None:
        # TODO: map EtaRequest fields to the model's input tensor layout.
        raise NotImplementedError("wire up ONNX input/output once eta_model.onnx is trained")

    avg_speed = max(req.segment_avg_speed_7d, 1.0)
    baseline = req.distance_to_stop_m / avg_speed
    return baseline + req.current_delay_sec
