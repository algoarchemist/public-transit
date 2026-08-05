import { createServer } from 'node:http';
import { Server } from 'socket.io';
import { createAdapter } from '@socket.io/redis-adapter';
import { Kafka } from 'kafkajs';
import Redis from 'ioredis';
import { config } from './config';

const BUS_STATE_TOPIC = 'bus-state-updates';

async function main() {
  const httpServer = createServer();
  const io = new Server(httpServer, { cors: { origin: '*' } });

  // Redis pub/sub backplane so the gateway scales out horizontally behind a load balancer
  // (see solution doc section 5.1 step 6) without buses/rooms being pinned to one instance.
  const pubClient = new Redis(config.redisUrl);
  const subClient = pubClient.duplicate();
  io.adapter(createAdapter(pubClient, subClient));

  io.on('connection', (socket) => {
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
    },
  });

  httpServer.listen(config.websocketPort, () => {
    console.log(`[gateway] listening on :${config.websocketPort}`);
  });
}

main().catch((err) => {
  console.error('[gateway] fatal', err);
  process.exit(1);
});
