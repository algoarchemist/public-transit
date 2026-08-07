import Redis from 'ioredis';
import { config } from './config';

export const redis = new Redis(config.redisUrl);

export function busPositionKey(busId: string) {
  return `bus:${busId}:position`;
}

export function busOccupancyKey(busId: string) {
  return `bus:${busId}:occupancy`;
}

// etaScoringLoop.ts's latest-scored upcomingStops for a bus, JSON-encoded. Reads
// need to cross a process boundary that plain in-memory state can't:
// consumer.ts (which scores) and gateway.ts (whose degradation watchdog needs the
// last known ETA for a bus that's gone quiet) are two separate processes/
// containers, not two modules in the same one — see etaScoringLoop.ts's own note
// on why this key exists at all.
export function busEtaKey(busId: string) {
  return `bus:${busId}:eta`;
}

// Registry of buses with at least one real ping on record — lets the degradation
// ladder's watchdog (gateway.ts) enumerate buses without scanning all Redis keys.
// Note: entries are never pruned, so a bus retired mid-demo stays in this set
// indefinitely; fine at demo fleet scale, would need a TTL/prune pass at real scale.
export const ACTIVE_BUSES_KEY = 'active-buses';
