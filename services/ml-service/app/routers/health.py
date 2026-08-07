import json
from pathlib import Path

from fastapi import APIRouter, HTTPException

router = APIRouter(prefix="/health", tags=["health"])

# train/train_eta.py's ARTIFACTS_DIR — see its own module docstring.
METRICS_PATH = Path(__file__).resolve().parent.parent.parent / "artifacts" / "metrics.json"


@router.get("/metrics")
def metrics():
    """The last training run's real evaluation metrics (horizon-bucketed MAE,
    model vs. naive baseline, feature importance) — a snapshot written by
    train/train_eta.py, not a live per-request recompute. Powers the admin
    dashboard's Model Health page."""
    if not METRICS_PATH.exists():
        raise HTTPException(status_code=404, detail="no trained model metrics yet — run train/train_eta.py")
    return json.loads(METRICS_PATH.read_text())
