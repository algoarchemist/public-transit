/**
 * The passenger-facing degradation ladder: what to show while a bus's pings have
 * stopped, instead of either freezing the marker (dishonest — looks live when it
 * isn't) or hiding it (throws away a perfectly good estimate). See
 * docs/IMPLEMENTATION_ARCHITECTURE.md §7.4.
 *
 *   0s   .. liveMaxAgeSec       -> 'live'      real last-reported position
 *   ..   .. estimatedMaxAgeSec  -> 'estimated' dead-reckoned along the real route
 *   beyond                     -> 'stale'      last known position, no number claimed
 */
import { config } from './config';
import { findSegmentAtDistance, getDirection, nextStopFrom, pointAtDistance } from './routeStore';

export type ConfidenceTier = 'live' | 'estimated' | 'stale';

export function classifyAge(ageSec: number): ConfidenceTier {
  if (ageSec <= config.liveMaxAgeSec) return 'live';
  if (ageSec <= config.estimatedMaxAgeSec) return 'estimated';
  return 'stale';
}

export interface LastKnownState {
  directionId: string;
  distAlongRouteM: number;
  speedMps: number;
  timestampMs: number;
  lastKnownLat: number;
  lastKnownLon: number;
  nextStopName?: string | null;
}

export interface EstimatedPosition {
  tier: ConfidenceTier;
  ageSec: number;
  lat: number;
  lon: number;
  distAlongRouteM: number;
  distanceToNextStopM: number;
  nextStopName: string | null;
  badge: string; // human-facing status text for the passenger UI
}

// Time over which the last observed speed is fully trusted before blending toward
// the current segment's real (OSRM-baseline) average speed — recent momentum is the
// best guide immediately after signal loss; the segment's typical pace is a better
// guide the longer a bus has been dark (docs §5.2, §5.4).
const FULL_HISTORICAL_BLEND_SEC = 90;

/**
 * Distance covered over `ageSec` when speed ramps linearly from `v0` (last observed)
 * to `vh` (historical) over `[0, rampSec]`, then holds at `vh`. This is the time
 * INTEGRAL of that ramp — NOT `blend(ageSec) * ageSec`, which evaluates the
 * instantaneous blended rate at the current instant and multiplies it by the whole
 * elapsed time. That naive version is non-monotonic: as the blend shifts toward a
 * slower historical speed, the "distance" it implies can briefly go backward even
 * though a real bus only ever moves forward. Integrating avoids that by construction
 * (v0, vh >= 0 always, so the integral is non-decreasing in ageSec).
 */
function integratedDistanceM(v0: number, vh: number, ageSec: number, rampSec: number): number {
  if (ageSec <= rampSec) {
    return v0 * ageSec + ((vh - v0) * (ageSec * ageSec)) / (2 * rampSec);
  }
  const distAtRampEnd = ((v0 + vh) / 2) * rampSec;
  return distAtRampEnd + vh * (ageSec - rampSec);
}

/**
 * Extrapolates a bus's position along its real route geometry from its last known
 * speed and position. This is what makes the marker keep advancing (then honestly
 * decaying) between pings instead of freezing.
 *
 * Known simplification: the historical speed reference is taken from the ONE
 * segment the bus was in at its last real ping, even if the blend window (90s) would
 * carry it into one or two subsequent (possibly shorter, differently-paced) segments.
 * Re-evaluating per-segment during the ramp would be more accurate but added
 * complexity not clearly worth it at these timescales — flagged here rather than
 * silently assumed away.
 */
export function estimatePosition(last: LastKnownState, nowMs: number): EstimatedPosition {
  const ageSec = Math.max(0, (nowMs - last.timestampMs) / 1000);
  const tier = classifyAge(ageSec);
  const fallbackNextStopName = last.nextStopName ?? null;

  const direction = getDirection(last.directionId);
  if (!direction) {
    // Unknown direction (shouldn't happen if this bus was ever map-matched) — fail
    // to the honest last-known point rather than guessing a position with no map.
    return {
      tier: 'stale',
      ageSec,
      lat: last.lastKnownLat,
      lon: last.lastKnownLon,
      distAlongRouteM: last.distAlongRouteM,
      distanceToNextStopM: 0,
      nextStopName: fallbackNextStopName,
      badge: badgeFor('stale', ageSec, fallbackNextStopName),
    };
  }

  const segment = findSegmentAtDistance(direction, last.distAlongRouteM);
  const historicalSpeedMps = segment?.avgSpeedMps ?? last.speedMps;
  const traveledM = integratedDistanceM(last.speedMps, historicalSpeedMps, ageSec, FULL_HISTORICAL_BLEND_SEC);

  const predictedDistM = Math.min(last.distAlongRouteM + traveledM, direction.totalLengthM);
  const point = pointAtDistance(last.directionId, predictedDistM) ?? {
    lat: last.lastKnownLat,
    lon: last.lastKnownLon,
  };
  const { stop, distanceToStopM } = nextStopFrom(direction, predictedDistM);
  const nextStopName = stop?.name ?? fallbackNextStopName;

  return {
    tier,
    ageSec,
    lat: point.lat,
    lon: point.lon,
    distAlongRouteM: predictedDistM,
    distanceToNextStopM: distanceToStopM,
    nextStopName,
    badge: badgeFor(tier, ageSec, nextStopName),
  };
}

function badgeFor(tier: ConfidenceTier, ageSec: number, nextStopName: string | null): string {
  if (tier === 'live') return 'live';
  if (tier === 'estimated') {
    return nextStopName
      ? `estimated position — signal lost ${Math.round(ageSec)}s ago, heading to ${nextStopName}`
      : `estimated position — signal lost ${Math.round(ageSec)}s ago`;
  }
  const minutes = Math.round(ageSec / 60);
  return `last seen ${minutes} min ago${nextStopName ? ` near ${nextStopName}` : ''} — estimate may be stale`;
}
