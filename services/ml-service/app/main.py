from fastapi import FastAPI

from app.routers import crowd, eta

app = FastAPI(title="SetuTrack ML Service", version="0.1.0")

app.include_router(eta.router)
app.include_router(crowd.router)


@app.get("/health")
def health():
    return {"status": "ok"}
