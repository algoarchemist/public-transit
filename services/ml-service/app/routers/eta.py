from fastapi import APIRouter

from app.models.eta import predict_eta_seconds
from app.schemas import EtaRequest, EtaResponse

router = APIRouter(prefix="/eta", tags=["eta"])


@router.post("/predict", response_model=EtaResponse)
def predict(req: EtaRequest) -> EtaResponse:
    eta_seconds = predict_eta_seconds(req)
    return EtaResponse(bus_id=req.bus_id, eta_seconds=eta_seconds)
