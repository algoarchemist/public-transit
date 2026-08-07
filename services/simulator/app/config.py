import os
from dataclasses import dataclass
from pathlib import Path

# REPO_ROOT env var wins when set — a Docker image only ships services/simulator/
# (see the Dockerfile), not the real checkout's app/->simulator->services->root
# nesting the parents[3] fallback below assumes, so it can't find data/snapshots
# inside a container. docker-compose sets this to wherever it bind-mounts data/.
REPO_ROOT = Path(os.environ["REPO_ROOT"]) if os.environ.get("REPO_ROOT") else Path(__file__).resolve().parents[3]
SNAPSHOT_DIR = REPO_ROOT / "data" / "snapshots"
BACKFILL_DIR = REPO_ROOT / "data" / "backfill"


@dataclass
class Settings:
    mqtt_broker_host: str = os.environ.get("MQTT_BROKER_HOST", "localhost")
    mqtt_broker_port: int = int(os.environ.get("MQTT_BROKER_PORT", "1883"))
    snapshot_label: str = os.environ.get("SNAPSHOT_LABEL", "mohali-tricity")
    database_url: str | None = os.environ.get("DATABASE_URL")


settings = Settings()
