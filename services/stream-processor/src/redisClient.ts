import Redis from 'ioredis';
import { config } from './config';

export const redis = new Redis(config.redisUrl);

export function busPositionKey(busId: string) {
  return `bus:${busId}:position`;
}

export function busOccupancyKey(busId: string) {
  return `bus:${busId}:occupancy`;
}

// Registry of buses with at least one real ping on record — lets the degradation
// ladder's watchdog (gateway.ts) enumerate buses without scanning all Redis keys.
// Note: entries are never pruned, so a bus retired mid-demo stays in this set
// indefinitely; fine at demo fleet scale, would need a TTL/prune pass at real scale.
export const ACTIVE_BUSES_KEY = 'active-buses';
