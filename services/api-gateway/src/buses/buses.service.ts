import { Inject, Injectable } from '@nestjs/common';
import type Redis from 'ioredis';
import { REDIS_CLIENT } from '../redis/redis.module';
import { ACTIVE_BUSES_KEY, busOccupancyKey, busPositionKey, tierForAge, type ConfidenceTier } from '../redis/fleet-keys';

export interface BusSummary {
  busId: string;
  routeId: string | null;
  directionId: string | null;
  nextStopId: string | null;
  nextStopName: string | null;
  occupancy: number | null;
  lastPingAt: string | null;
  ageSec: number | null;
  confidenceTier: ConfidenceTier;
}

/**
 * The REST polling fallback for fleet state (docs §8: `GET /api/buses`,
 * `/buses/:id`) — live clients should hold the stream-processor gateway's
 * WebSocket open instead (docs §5.1.5), but this exists for the low-bandwidth
 * degraded mode and for anything that can't hold a live connection. Reads the
 * exact same Redis state that socket is populated from (`active-buses` set +
 * `bus:{id}:position/occupancy` hashes, docs §7.3 item 4) — no separate store,
 * no risk of disagreeing with what the live map shows.
 */
@Injectable()
export class BusesService {
  constructor(@Inject(REDIS_CLIENT) private readonly redis: Redis) {}

  async findAll(): Promise<BusSummary[]> {
    const busIds = await this.redis.smembers(ACTIVE_BUSES_KEY);
    const buses = await Promise.all(busIds.map((id) => this.loadOne(id)));
    return buses.filter((b): b is BusSummary => b !== null);
  }

  async findOne(id: string): Promise<BusSummary | null> {
    return this.loadOne(id);
  }

  eta(id: string) {
    // stream-processor's etaScoringLoop.ts caches its last-scored per-stop ETAs at
    // bus:{id}:eta (docs §7.3 item 3) — not read here yet; live clients get it
    // over the WebSocket payload directly. Left as the documented stub until a
    // caller actually needs the REST path for this specific field.
    return { busId: id, upcomingStops: [] };
  }

  private async loadOne(busId: string): Promise<BusSummary | null> {
    const [hash, occupancy] = await Promise.all([
      this.redis.hgetall(busPositionKey(busId)),
      this.redis.get(busOccupancyKey(busId)),
    ]);
    if (!hash || Object.keys(hash).length === 0) return null;

    const updatedAtMs = Number(hash.updatedAt);
    const hasTimestamp = Number.isFinite(updatedAtMs) && updatedAtMs > 0;
    const ageSec = hasTimestamp ? (Date.now() - updatedAtMs) / 1000 : null;

    return {
      busId,
      routeId: hash.routeId || null,
      directionId: hash.directionId || null,
      nextStopId: hash.nextStopId || null,
      nextStopName: hash.nextStopName || null,
      occupancy: occupancy !== null && occupancy !== '' ? Number(occupancy) : null,
      lastPingAt: hasTimestamp ? new Date(updatedAtMs).toISOString() : null,
      ageSec: ageSec !== null ? Math.round(ageSec) : null,
      confidenceTier: tierForAge(ageSec),
    };
  }
}
