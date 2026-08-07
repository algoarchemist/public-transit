import { Global, Module } from '@nestjs/common';
import Redis from 'ioredis';

export const REDIS_CLIENT = 'REDIS_CLIENT';

/**
 * One shared ioredis client for anything in api-gateway that reads the live
 * fleet state stream-processor writes (docs §7.3 item 4: `bus:{id}:position`,
 * `bus:{id}:occupancy`, `active-buses`) — same Redis, same key shapes as
 * services/stream-processor/src/redisClient.ts, just a second reader. Global so
 * BusesService and AdminAnalyticsService don't each need their own connection.
 */
@Global()
@Module({
  providers: [
    {
      provide: REDIS_CLIENT,
      useFactory: () => new Redis(process.env.REDIS_URL ?? 'redis://localhost:6379'),
    },
  ],
  exports: [REDIS_CLIENT],
})
export class RedisModule {}
