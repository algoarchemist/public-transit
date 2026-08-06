import mqtt from 'mqtt';
import { Kafka } from 'kafkajs';
import { config } from './config';
import { mapMatch, type RawGpsPing } from './mapMatch';
import { redis, busPositionKey, busOccupancyKey, ACTIVE_BUSES_KEY } from './redisClient';
import { startEtaScoringLoop, latestEtaCache } from './etaScoringLoop';
import { startStatsStore } from './statsStore';

// In a production AIS-140/EMQX deployment, raw GPS pings are bridged from MQTT into the
// "raw-gps-pings" Kafka topic by EMQX's rule engine, and this process would be a pure Kafka
// consumer. For the hackathon demo (see solution doc section 5.2) the GPS simulator publishes
// straight to MQTT, so this process subscribes directly and republishes processed state to Kafka.
const kafka = new Kafka({ clientId: config.kafkaClientId, brokers: config.kafkaBrokers });
const producer = kafka.producer();

const GPS_TOPIC = 'gps/+/ping';
const BUS_STATE_TOPIC = 'bus-state-updates';

async function handlePing(ping: RawGpsPing) {
  const matched = await mapMatch(ping);
  const speedMps = ping.speedKmh / 3.6;

  await redis
    .multi()
    .hset(busPositionKey(ping.busId), {
      lat: ping.lat,
      lon: ping.lon,
      routeId: ping.routeId,
      directionId: ping.directionId,
      distAlongRouteM: matched.distAlongRouteM,
      speedMps,
      nextStopId: matched.nextStopId ?? '',
      nextStopName: matched.nextStopName ?? '',
      updatedAt: ping.timestamp,
    })
    .set(busOccupancyKey(ping.busId), ping.occupancy)
    .sadd(ACTIVE_BUSES_KEY, ping.busId)
    .exec();

  // ETA is no longer scored per-ping (docs §7.3 item 3 — a per-ping HTTP call to
  // ml-service doesn't hold up at fleet scale). etaScoringLoop.ts batches every
  // live bus into one /eta/predict-batch call on a fixed interval instead; this
  // just attaches whatever it last computed, so the position update this ping
  // triggers isn't shipped with no ETA at all between batch ticks.
  const upcomingStops = latestEtaCache.get(ping.busId);

  await producer.send({
    topic: BUS_STATE_TOPIC,
    messages: [
      {
        key: ping.busId,
        value: JSON.stringify({
          busId: ping.busId,
          routeId: ping.routeId,
          directionId: ping.directionId,
          lat: ping.lat,
          lon: ping.lon,
          occupancy: ping.occupancy,
          etaSeconds: upcomingStops?.[0]?.etaSeconds,
          upcomingStops,
          nextStopId: matched.nextStopId,
          nextStopName: matched.nextStopName,
          distanceToNextStopM: matched.distanceToNextStopM,
          confidenceTier: 'live',
          badge: 'live',
          updatedAt: ping.timestamp,
        }),
      },
    ],
  });
}

async function main() {
  await producer.connect();
  await startStatsStore();
  startEtaScoringLoop(redis, producer);

  const client = mqtt.connect(config.mqttBrokerUrl);

  client.on('connect', () => {
    client.subscribe(GPS_TOPIC, (err) => {
      if (err) throw err;
      console.log(`[consumer] subscribed to ${GPS_TOPIC}`);
    });
  });

  client.on('message', (_topic, payload) => {
    // TODO: swap JSON.parse for a compact protobuf decode (see solution doc section 1.3 —
    // ~20-40 bytes/ping on the wire vs 200+ bytes JSON).
    const ping = JSON.parse(payload.toString()) as RawGpsPing;
    handlePing(ping).catch((err) => console.error('[consumer] failed to process ping', err));
  });

  client.on('error', (err) => console.error('[consumer] mqtt error', err));
}

main().catch((err) => {
  console.error('[consumer] fatal', err);
  process.exit(1);
});
