import 'dotenv/config';

export const config = {
  mqttBrokerUrl: process.env.MQTT_BROKER_URL ?? 'mqtt://localhost:1883',
  kafkaBrokers: (process.env.KAFKA_BROKERS ?? 'localhost:9092').split(','),
  kafkaClientId: process.env.KAFKA_CLIENT_ID ?? 'setutrack-stream-processor',
  redisUrl: process.env.REDIS_URL ?? 'redis://localhost:6379',
  databaseUrl: process.env.DATABASE_URL ?? 'postgres://setutrack:setutrack@localhost:5432/setutrack',
  mlServiceUrl: process.env.ML_SERVICE_URL ?? 'http://localhost:8000',
  websocketPort: Number(process.env.WEBSOCKET_PORT ?? 4001),
  // Which geo-ingest snapshot (data/snapshots/<label>/) to load route/stop/segment
  // geometry from. See routeStore.ts — this is what map-matching and the
  // degradation ladder's dead reckoning are computed against.
  snapshotLabel: process.env.SNAPSHOT_LABEL ?? 'mohali-tricity',
  // Age thresholds for the passenger-facing confidence ladder (see deadReckoning.ts
  // and docs/IMPLEMENTATION_ARCHITECTURE.md §7.4).
  liveMaxAgeSec: Number(process.env.LIVE_MAX_AGE_SEC ?? 60),
  estimatedMaxAgeSec: Number(process.env.ESTIMATED_MAX_AGE_SEC ?? 180),
  // How often etaScoringLoop.ts scores every live bus in one /eta/predict-batch
  // call (docs §6.4/§7.3 item 3 — replaces the old per-ping /eta/predict call).
  etaBatchIntervalMs: Number(process.env.ETA_BATCH_INTERVAL_MS ?? 1000),
};
