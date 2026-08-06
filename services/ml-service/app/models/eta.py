"""ETA prediction: GBM-on-features model (docs/IMPLEMENTATION_ARCHITECTURE.md §6.2),
falling back to the naive distance/avg-speed baseline until train/train_eta.py has
been run and produced artifacts/eta_model.onnx.

Predicts one segment's traversal duration, per the feature contract in
app/features.py — the same module train/train_eta.py trains against, so this file
never has its own, potentially-drifting idea of what the model's inputs mean.
"""
from pathlib import Path

import numpy as np

from app.features import feature_vector
from app.schemas import BusEtaBatchResult, BusEtaQuery, EtaRequest, StopEta

MODEL_PATH = Path(__file__).resolve().parent.parent.parent / "artifacts" / "eta_model.onnx"

_session = None
_input_name: str | None = None
if MODEL_PATH.exists():
    import onnxruntime as ort

    _session = ort.InferenceSession(str(MODEL_PATH))
    _input_name = _session.get_inputs()[0].name


def _naive_baseline_sec(req) -> float:
    """`req` just needs segment_avg_speed_7d/distance_to_stop_m/current_delay_sec —
    both EtaRequest and SegmentEtaFeatures (predict-batch) satisfy that."""
    avg_speed = max(req.segment_avg_speed_7d, 1.0)
    baseline = req.distance_to_stop_m / avg_speed
    return baseline + req.current_delay_sec


def predict_eta_seconds(req: EtaRequest) -> float:
    if _session is not None:
        x = np.array([feature_vector(req)], dtype=np.float32)
        pred = _session.run(None, {_input_name: x})[0]
        return max(float(np.asarray(pred).ravel()[0]), 0.0)

    return _naive_baseline_sec(req)


def predict_eta_batch(buses: list[BusEtaQuery]) -> list[BusEtaBatchResult]:
    """docs §6.4: the stream processor scores every active bus about once a second —
    this exists so that's one HTTP call and one model inference for the whole fleet's
    segments, not one call per bus per ping. Returns cumulative ETA to each of a
    bus's upcoming stops (segments[0] should carry the REMAINING distance for the
    bus's current segment; segments[1:] are full upcoming segments — see
    BusEtaQuery's docstring), including predicted dwell at intermediate stops.
    """
    flat_segments = [seg for bus in buses for seg in bus.segments]
    if not flat_segments:
        return [BusEtaBatchResult(bus_id=b.bus_id, stops=[]) for b in buses]

    if _session is not None:
        x = np.array([feature_vector(s) for s in flat_segments], dtype=np.float32)
        durations = np.maximum(_session.run(None, {_input_name: x})[0].ravel(), 0.0)
    else:
        durations = np.array([_naive_baseline_sec(s) for s in flat_segments])

    results: list[BusEtaBatchResult] = []
    cursor = 0
    for bus in buses:
        segs = bus.segments
        stops: list[StopEta] = []
        cum = 0.0
        for i in range(len(segs)):
            if i > 0:
                # Dwell at the PREVIOUS segment's destination stop, charged before
                # continuing on to this one — same convention as train_eta.py's
                # horizon evaluation, so serving and offline evaluation agree.
                cum += segs[i - 1].upcoming_stop_dwell_prior_sec
            cum += float(durations[cursor])
            stops.append(StopEta(stop_id=segs[i].stop_id, eta_seconds=cum))
            cursor += 1
        results.append(BusEtaBatchResult(bus_id=bus.bus_id, stops=stops))
    return results
