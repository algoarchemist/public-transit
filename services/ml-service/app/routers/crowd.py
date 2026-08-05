from fastapi import APIRouter

from app.models.crowd import predict_boarding_alighting
from app.schemas import CrowdRequest, CrowdResponse

router = APIRouter(prefix="/crowd", tags=["crowd"])


@router.post("/predict", response_model=CrowdResponse)
def predict(req: CrowdRequest) -> CrowdResponse:
    boarding, alighting = predict_boarding_alighting(req)
    return CrowdResponse(
        bus_id=req.bus_id,
        stop_id=req.stop_id,
        predicted_boarding=boarding,
        predicted_alighting=alighting,
    )
