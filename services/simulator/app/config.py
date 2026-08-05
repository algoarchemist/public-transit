import os
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
SNAPSHOT_DIR = REPO_ROOT / "data" / "snapshots"
BACKFILL_DIR = REPO_ROOT / "data" / "backfill"


@dataclass
class Settings:
    mqtt_broker_host: str = os.environ.get("MQTT_BROKER_HOST", "localhost")
    mqtt_broker_port: int = int(os.environ.get("MQTT_BROKER_PORT", "1883"))
    snapshot_label: str = os.environ.get("SNAPSHOT_LABEL", "mohali-tricity")
    database_url: str | None = os.environ.get("DATABASE_URL")


settings = Settings()
