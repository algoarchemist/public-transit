import { createServer } from 'node:http';
import { Server } from 'socket.io';
import { createAdapter } from '@socket.io/redis-adapter';
import { Kafka } from 'kafkajs';
import Redis from 'ioredis';
import { config } from './config';
import { ACTIVE_BUSES_KEY, busEtaKey, busOccupancyKey, busPositionKey } from './redisClient';
import { estimatePosition, type LastKnownState } from './deadReckoning';

const BUS_STATE_TOPIC = 'bus-state-updates';
const WATCHDOG_INTERVAL_MS = 5000;

/**
 * The degradation ladder's active half: real pings are pushed the instant they
 * arrive (via the Kafka consumer below), but a bus that's gone quiet needs *someone*
 * to keep telling passengers something — otherwise the marker just freezes, which
 * reads as "the bus is exactly here" when it's really "we haven't heard from it in
 * 3 minutes". This ticks independently of any real ping and broadcasts a decaying-
 * confidence estimate for every bus whose last ping is older than `liveMaxAgeSec`
 * (see docs/IMPLEMENTATION_ARCHITECTURE.md §7.4, deadReckoning.ts).
 */
function startDegradationWatchdog(io: Server, redisClient: Redis) {
  setInterval(async () => {
    const busIds = await redisClient.smembers(ACTIVE_BUSES_KEY);
    const now = Date.now();

    for (const busId of busIds) {
      const hash = await redisClient.hgetall(busPositionKey(busId));
      if (!hash.updatedAt) continue;

      const updatedAt = Number(hash.updatedAt);
      const ageSec = (now - updatedAt) / 1000;
      if (ageSec <= config.liveMaxAgeSec) continue; // still live — the ping-driven push below covers it

      const last: LastKnownState = {
        directionId: hash.directionId,
        distAlongRouteM: Number(hash.distAlongRouteM ?? 0),
        speedMps: Number(hash.speedMps ?? 0),
        timestampMs: updatedAt,
        lastKnownLat: Number(hash.lat),
        lastKnownLon: Number(hash.lon),
        nextStopName: hash.nextStopName || null,
      };
      const estimate = estimatePosition(last, now);
      const occupancy = await redisClient.get(busOccupancyKey(busId));
      // etaScoringLoop.ts (consumer.ts's process) mirrors its last score here
      // specifically so this watchdog — a different process — can still show it.
      // Without this, every bus that goes quiet would silently lose its ETA the
      // instant this loop starts publishing for it, even though the number is
      // still perfectly usable for the next couple of minutes.
      const rawEta = await redisClient.get(busEtaKey(busId));
      const upcomingStops = rawEta ? JSON.parse(rawEta) : [];

      const payload = {
        busId,
        routeId: hash.routeId,
        directionId: hash.directionId,
        lat: estimate.lat,
        lon: estimate.lon,
        occupancy: occupancy ? Number(occupancy) : null,
        etaSeconds: upcomingStops[0]?.etaSeconds,
        upcomingStops,
        // Prefer the cached ETA's own stop over dead reckoning's fresh
        // recompute when both exist — the app shows "Heading to X, ETA Y" as
        // one pair, and if the bus has spatially moved past the stop the
        // cached ETA is for, showing dead reckoning's newer stop name next to
        // that older ETA would pair a time with the wrong destination.
        // Falls back to dead reckoning's own estimate only when this bus was
        // never actually scored (e.g. went quiet before the first tick).
        nextStopId: upcomingStops[0]?.stopId ?? hash.nextStopId ?? null,
        nextStopName: upcomingStops[0]?.stopName ?? estimate.nextStopName,
        distanceToNextStopM: estimate.distanceToNextStopM,
        confidenceTier: estimate.tier,
        badge: estimate.badge,
        updatedAt, // the last REAL ping time, not `now` — honest about how stale this is
      };

      io.to(`bus:${busId}`).emit('bus:update', payload);
      io.to(`route:${hash.routeId}`).emit('bus:update', payload);
      // admin:fleet mirrors the two rooms above — keep all three in sync on future edits.
      io.to('admin:fleet').emit('bus:update', payload);
    }
  }, WATCHDOG_INTERVAL_MS);
}

async function main() {
  const httpServer = createServer();
  const io = new Server(httpServer, { cors: { origin: '*' } });

  // Redis pub/sub backplane so the gateway scales out horizontally behind a load balancer
  // (see solution doc section 5.1 step 6) without buses/rooms being pinned to one instance.
  const pubClient = new Redis(config.redisUrl);
  const subClient = pubClient.duplicate();
  io.adapter(createAdapter(pubClient, subClient));

  io.on('connection', (socket) => {
    // Every client sees the whole fleet by default — there's no meaningful "opt out
    // of the whole fleet" case for an admin view, so this is an unconditional join
    // rather than a subscribe:fleet round-trip like the per-bus/per-route rooms below.
    socket.join('admin:fleet');
    socket.on('subscribe:bus', (busId: string) => socket.join(`bus:${busId}`));
    socket.on('subscribe:route', (routeId: string) => socket.join(`route:${routeId}`));
    socket.on('unsubscribe:bus', (busId: string) => socket.leave(`bus:${busId}`));
    socket.on('unsubscribe:route', (routeId: string) => socket.leave(`route:${routeId}`));
  });

  const kafka = new Kafka({ clientId: `${config.kafkaClientId}-gateway`, brokers: config.kafkaBrokers });
  const consumer = kafka.consumer({ groupId: 'realtime-gateway' });
  await consumer.connect();
  await consumer.subscribe({ topic: BUS_STATE_TOPIC, fromBeginning: false });

  await consumer.run({
    eachMessage: async ({ message }) => {
      if (!message.value) return;
      const state = JSON.parse(message.value.toString());
      // Only clients actually viewing this bus/route receive it — payload volume stays
      // proportional to active viewers, not total fleet size (solution doc section 5.1 step 5).
      io.to(`bus:${state.busId}`).emit('bus:update', state);
      io.to(`route:${state.routeId}`).emit('bus:update', state);
      // admin:fleet mirrors the two rooms above — keep all three in sync on future edits.
      io.to('admin:fleet').emit('bus:update', state);
    },
  });

  startDegradationWatchdog(io, pubClient.duplicate());

  httpServer.listen(config.websocketPort, () => {
    console.log(`[gateway] listening on :${config.websocketPort}`);
  });
}

main().catch((err) => {
  console.error('[gateway] fatal', err);
  process.exit(1);
});
