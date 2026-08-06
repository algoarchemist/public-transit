/**
 * Loads segment_travel_stats / stop_dwell_stats (db/migrations/0003_derived_stats.sql,
 * docs §3.3) into memory once at startup and periodically reloads, mirroring
 * routeStore.ts's pattern for the (much larger, mostly-static) geo-ingest snapshot.
 * A 1-second-tick hot loop (etaScoringLoop.ts) querying Postgres per bus per tick
 * would add real DB load and latency for no benefit — these tables are refreshed
 * by an offline batch script (services/ml-service/train/refresh_stats.py), not
 * continuously, so an in-memory cache reloaded every RELOAD_INTERVAL_MS is exactly
 * as fresh as the data actually is.
 *
 * dow lookups try the real day-of-week first, then fall back to -1 ("any day") —
 * see 0003_derived_stats.sql's header comment for why every row is currently -1
 * (too few samples per (segment, dow, hour) cell at the simulator's trip volume to
 * be a real signal). This fallback means real per-dow data can slot in later with
 * no caller-side change.
 */
import { getPgPool } from './pgPool';

const RELOAD_INTERVAL_MS = 5 * 60 * 1000;
const ANY_DOW = -1;

export interface SegmentStat {
  avgSpeedKmh: number;
  p50DurationSec: number;
  p85DurationSec: number;
  sampleCount: number;
}

export interface DwellStat {
  p50DwellSec: number;
  avgBoarding: number;
  avgAlighting: number;
  sampleCount: number;
}

let segmentStats = new Map<string, SegmentStat>(); // key: `${directionId}:${sequence}:${hour}:${dow}:${window}`
let dwellStats = new Map<string, DwellStat>(); // key: `${stopOsmNodeId}:${hour}:${dow}`

// Observability counters, logged periodically rather than per-lookup (would be far
// too noisy at one batch tick/sec x several segments/bus x several buses).
export const lookupCounts = { segmentHit: 0, segmentMiss: 0, dwellHit: 0, dwellMiss: 0 };

function segmentKey(directionId: string, sequence: number, hour: number, dow: number, window: '7d' | '30d'): string {
  return `${directionId}:${sequence}:${hour}:${dow}:${window}`;
}

function dwellKey(stopOsmNodeId: string, hour: number, dow: number): string {
  return `${stopOsmNodeId}:${hour}:${dow}`;
}

async function reload(): Promise<void> {
  const pool = getPgPool();
  const [segRes, dwellRes] = await Promise.all([
    pool.query(
      'SELECT direction_id, sequence, dow, hour_bucket, agg_window, avg_speed_kmh, p50_duration_sec, p85_duration_sec, sample_count FROM segment_travel_stats',
    ),
    pool.query(
      'SELECT stop_osm_node_id, dow, hour_bucket, p50_dwell_sec, avg_boarding, avg_alighting, sample_count FROM stop_dwell_stats',
    ),
  ]);

  const nextSegmentStats = new Map<string, SegmentStat>();
  for (const row of segRes.rows) {
    nextSegmentStats.set(
      segmentKey(row.direction_id, row.sequence, row.hour_bucket, row.dow, row.agg_window),
      {
        avgSpeedKmh: Number(row.avg_speed_kmh),
        p50DurationSec: Number(row.p50_duration_sec),
        p85DurationSec: Number(row.p85_duration_sec),
        sampleCount: Number(row.sample_count),
      },
    );
  }

  const nextDwellStats = new Map<string, DwellStat>();
  for (const row of dwellRes.rows) {
    nextDwellStats.set(dwellKey(String(row.stop_osm_node_id), row.hour_bucket, row.dow), {
      p50DwellSec: Number(row.p50_dwell_sec),
      avgBoarding: Number(row.avg_boarding),
      avgAlighting: Number(row.avg_alighting),
      sampleCount: Number(row.sample_count),
    });
  }

  segmentStats = nextSegmentStats;
  dwellStats = nextDwellStats;
  console.log(
    `[statsStore] loaded ${segmentStats.size} segment_travel_stats rows, ${dwellStats.size} stop_dwell_stats rows`,
  );
}

export async function startStatsStore(): Promise<void> {
  try {
    await reload();
  } catch (err) {
    // Missing table, unreachable DB, etc. — every lookup below just falls through
    // to its caller's OSRM-baseline/flat-constant fallback, same as an empty cache.
    console.error('[statsStore] initial load failed — falling back to proxies for all lookups', err);
  }
  setInterval(() => {
    reload().catch((err) => console.error('[statsStore] reload failed, keeping previous cache', err));
  }, RELOAD_INTERVAL_MS);
}

export function getSegmentStat(
  directionId: string,
  sequence: number,
  hour: number,
  dow: number,
  window: '7d' | '30d',
): SegmentStat | null {
  const hit =
    segmentStats.get(segmentKey(directionId, sequence, hour, dow, window)) ??
    segmentStats.get(segmentKey(directionId, sequence, hour, ANY_DOW, window));
  if (hit) lookupCounts.segmentHit++;
  else lookupCounts.segmentMiss++;
  return hit ?? null;
}

export function getDwellStat(stopOsmNodeId: string, hour: number, dow: number): DwellStat | null {
  const hit = dwellStats.get(dwellKey(stopOsmNodeId, hour, dow)) ?? dwellStats.get(dwellKey(stopOsmNodeId, hour, ANY_DOW));
  if (hit) lookupCounts.dwellHit++;
  else lookupCounts.dwellMiss++;
  return hit ?? null;
}
