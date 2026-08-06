from fastapi import APIRouter

from app.models.eta import predict_eta_batch, predict_eta_seconds
from app.schemas import EtaBatchRequest, EtaBatchResponse, EtaRequest, EtaResponse

router = APIRouter(prefix="/eta", tags=["eta"])


@router.post("/predict", response_model=EtaResponse)
def predict(req: EtaRequest) -> EtaResponse:
    """Single-segment, single-bus prediction. Kept for compatibility with existing
    callers (stream-processor's etaClient.ts still calls this per-ping, see docs §7.3
    item 3) — new callers scoring more than one bus per request should use
    /eta/predict-batch instead (docs §6.4)."""
    eta_seconds = predict_eta_seconds(req)
    return EtaResponse(bus_id=req.bus_id, eta_seconds=eta_seconds)


@router.post("/predict-batch", response_model=EtaBatchResponse)
def predict_batch(req: EtaBatchRequest) -> EtaBatchResponse:
    results = predict_eta_batch(req.buses)
    return EtaBatchResponse(results=results)
