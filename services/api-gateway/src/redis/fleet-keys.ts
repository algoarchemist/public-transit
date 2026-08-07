// Mirrors services/stream-processor/src/redisClient.ts's key shapes exactly —
// api-gateway is a second reader of state that service writes, not a second
// writer, so these must stay byte-for-byte in sync with that file.
export const ACTIVE_BUSES_KEY = 'active-buses';

export function busPositionKey(busId: string) {
  return `bus:${busId}:position`;
}

export function busOccupancyKey(busId: string) {
  return `bus:${busId}:occupancy`;
}

// Same thresholds as stream-processor/src/config.ts's liveMaxAgeSec/
// estimatedMaxAgeSec (docs §7.4's degradation ladder) — duplicated rather than
// imported since these are two separate npm workspaces/deployables.
export const LIVE_MAX_AGE_SEC = Number(process.env.LIVE_MAX_AGE_SEC ?? 60);
export const ESTIMATED_MAX_AGE_SEC = Number(process.env.ESTIMATED_MAX_AGE_SEC ?? 180);

export type ConfidenceTier = 'live' | 'estimated' | 'stale' | 'unknown';

export function tierForAge(ageSec: number | null): ConfidenceTier {
  if (ageSec === null) return 'unknown';
  if (ageSec <= LIVE_MAX_AGE_SEC) return 'live';
  if (ageSec <= ESTIMATED_MAX_AGE_SEC) return 'estimated';
  return 'stale';
}
