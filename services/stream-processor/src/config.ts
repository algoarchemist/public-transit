import 'dotenv/config';

export const config = {
  mqttBrokerUrl: process.env.MQTT_BROKER_URL ?? 'mqtt://localhost:1883',
  kafkaBrokers: (process.env.KAFKA_BROKERS ?? 'localhost:9092').split(','),
  kafkaClientId: process.env.KAFKA_CLIENT_ID ?? 'setutrack-stream-processor',
  redisUrl: process.env.REDIS_URL ?? 'redis://localhost:6379',
  databaseUrl: process.env.DATABASE_URL ?? 'postgres://setutrack:setutrack@localhost:5432/setutrack',
  mlServiceUrl: process.env.ML_SERVICE_URL ?? 'http://localhost:8000',
  websocketPort: Number(process.env.WEBSOCKET_PORT ?? 4001),
};
