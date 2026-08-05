import Redis from 'ioredis';
import { config } from './config';

export const redis = new Redis(config.redisUrl);

export function busPositionKey(busId: string) {
  return `bus:${busId}:position`;
}

export function busOccupancyKey(busId: string) {
  return `bus:${busId}:occupancy`;
}
