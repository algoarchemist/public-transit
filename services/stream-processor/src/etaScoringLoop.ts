/**
 * Scores every live bus's next few stops in one batched call to ml-service, on a
 * fixed interval — this is docs §7.3 item 3 ("One batched call to
 * /eta/predict-batch... not yet built; scoreEta() is still called per ping")
 * actually built. Runs inside consumer.ts, which already holds the Redis client,
 * Kafka producer, and (via mapMatch.ts) the loaded routeStore snapshot.
 *
 * Feature honesty, read before trusting these numbers (see train/README.md on the
 * ml-service side for the training-time half of this same gap):
 *   - segment_avg_speed_7d/30d use the segment's real OSRM free-flow baseline
 *     (routeStore's avgSpeedMps) for BOTH fields. This is a real, route-specific
 *     number, but it is NOT a rolling historical average — docs §3.3's
 *     segment_travel_stats/stop_dwell_stats aggregate tables don't exist yet (MVP
 *     scope cut, see docs §2). It's the best currently-available proxy, not the
 *     real thing, and the model was trained against genuine rolling aggregates
 *     computed from the backfill corpus — so live predictions will be less sharp
 *     than the offline metrics.json numbers suggest until that table is built.
 *   - live_traffic_factor for a bus's CURRENT segment is real: this tick's
 *     observed speed vs. that segment's OSRM baseline. This is the one feature
 *     that's honestly live. Downstream (not-yet-entered) segments get the neutral
 *     1.0 — there's no observation to base a ratio on yet.
 *   - current_delay_sec stays 0: no trip-start/schedule tracking exists to measure
 *     delay against (buses run on randomized headways, not a fixed timetable).
 *   - upcoming_stop_dwell_prior_sec uses a real per-stop/per-hour stop_dwell_stats
 *     bucket when one exists; otherwise it's derived from THIS bus's live reported
 *     occupancy (dwellPriorSecFromOccupancy below) rather than a flat constant — a
 *     fuller bus takes longer to board/alight at every stop. This is NOT the
 *     per-stop footfall_prior geo-ingest ships (that field is 0 for every stop in
 *     every snapshot — never populated by any ingestion step), it's the one real,
 *     live crowd signal every ping actually carries.
 *   - weather_bucket stays 0: nothing in this system observes or models weather.
 */
import type { Producer } from 'kafkajs';
import type Redis from 'ioredis';
import { config } from './config';
import { ACTIVE_BUSES_KEY, busOccupancyKey, busPositionKey } from './redisClient';
import { getDirection, type RouteSegmentInfo } from './routeStore';
import { predictEtaBatch, type BusEtaQuery, type SegmentEtaFeatures } from './etaBatchClient';
import { getSegmentStat, getDwellStat, lookupCounts } from './statsStore';

const BUS_STATE_TOPIC = 'bus-state-updates';
const N_UPCOMING_STOPS = 3; // docs §6.4: "the passenger UI shows the next three stops"
const FALLBACK_SPEED_MPS = 8.0; // matches services/simulator's SimRoute.average_speed_mps fallback
const DWELL_PRIOR_FALLBACK_SEC = 20; // used only when a bus has never reported occupancy at all
const LIVE_TRAFFIC_FACTOR_CLAMP: [number, number] = [0.2, 3.0]; // guards near-zero-speed blowups

// Dwell-from-occupancy: no stop_dwell_stats table (§3.3) or per-stop footfall_prior
// exists yet (geo-ingest ships that field, but every stop in every snapshot has it
// at 0 — never populated), so there is no real historical "how long do people take
// to board here" signal to fall back on. What every bus DOES report, every ping, is
// its own current occupancy — a real, live crowd signal, just never plugged into
// dwell time before. A fuller bus takes longer at each stop (more people fighting to
// get off, less room for people getting on), so scale dwell against the same 50-seat
// capacity convention app_theme.dart's occupancyColor/occupancyLabel already use for
// "Seats free"/"Standing"/"Crowded", rather than inventing a different one here.
const DWELL_CAPACITY = 50;
const DWELL_BASE_SEC = 12; // door open/close + minimum stop overhead, even near-empty
const DWELL_PER_OCCUPANCY_SEC = 18; // additional dwell climbing to a full bus
const DWELL_OCCUPANCY_RATIO_CLAMP: [number, number] = [0, 1.2]; // standing room can push "occupancy" a bit past capacity

function dwellPriorSecFromOccupancy(occupancy: number | null): number {
  if (occupancy == null) return DWELL_PRIOR_FALLBACK_SEC;
  const ratio = clamp(occupancy / DWELL_CAPACITY, DWELL_OCCUPANCY_RATIO_CLAMP);
  return DWELL_BASE_SEC + DWELL_PER_OCCUPANCY_SEC * ratio;
}

const IST_OFFSET_MS = 5.5 * 60 * 60 * 1000;

function istHourAndDow(epochMs: number): { hour: number; dow: number } {
  const ist = new Date(epochMs + IST_OFFSET_MS);
  return { hour: ist.getUTCHours(), dow: ist.getUTCDay() };
}

function clamp(v: number, [lo, hi]: [number, number]): number {
  return Math.max(lo, Math.min(hi, v));
}

interface LiveBusRow {
  busId: string;
  routeId: string;
  directionId: string;
  lat: number;
  lon: number;
  distAlongRouteM: number;
  speedMps: number;
  updatedAt: number;
  occupancy: number | null;
}

async function loadLiveBuses(redis: Redis): Promise<LiveBusRow[]> {
  const busIds = await redis.smembers(ACTIVE_BUSES_KEY);
  const now = Date.now();
  const rows: LiveBusRow[] = [];

  for (const busId of busIds) {
    const hash = await redis.hgetall(busPositionKey(busId));
    if (!hash.updatedAt) continue;

    const updatedAt = Number(hash.updatedAt);
    const ageSec = (now - updatedAt) / 1000;
    if (ageSec > config.liveMaxAgeSec) continue; // dead-reckoning watchdog (gateway.ts) covers these

    const occupancy = await redis.get(busOccupancyKey(busId));
    rows.push({
      busId,
      routeId: hash.routeId,
      directionId: hash.directionId,
      lat: Number(hash.lat),
      lon: Number(hash.lon),
      distAlongRouteM: Number(hash.distAlongRouteM ?? 0),
      speedMps: Number(hash.speedMps ?? 0),
      updatedAt,
      occupancy: occupancy ? Number(occupancy) : null,
    });
  }
  return rows;
}

/** A built query plus the exact segment objects it was built from, kept around
 * so the response can be matched back to a stop NAME by position rather than by
 * re-deriving `stop_id` (see the module-level note on [buildQuery]'s return). */
interface BuiltQuery {
  query: BusEtaQuery;
  upcoming: RouteSegmentInfo[];
}

/** Builds one bus's upcoming-segment feature list, or null if its route/segments
 * aren't resolvable (unmatched direction, or already past the last stop).
 *
 * Returns the source `upcoming` segments alongside the query rather than making
 * the caller re-find them from `stop_id` afterwards: a segment whose real
 * `toStopId` is null (segments.geojson has gaps — not every OSRM-matched segment
 * boundary lands on a real GTFS/OSM stop) falls back to a synthetic
 * `directionId:sequence` id for the ml-service query below, and re-deriving the
 * name via `String(seg.toStopId) === stop_id` can never match that synthetic
 * string back to anything (`String(null/undefined)` is `"null"`/`"undefined"`) —
 * silently producing a null stop name (and, since etaScoringLoop's own
 * `nextStopName` is sourced from this same list, a nameless "Heading to" card
 * too) even though the ETA number itself was computed correctly the whole time.
 */
function buildQuery(row: LiveBusRow): BuiltQuery | null {
  const direction = getDirection(row.directionId);
  if (!direction || direction.segments.length === 0) return null;

  const currentIdx = direction.segments.findIndex((s) => row.distAlongRouteM <= s.toDistAlongRouteM);
  if (currentIdx === -1) return null; // bus has completed the route — nothing upcoming to score

  const upcoming = direction.segments.slice(currentIdx, currentIdx + N_UPCOMING_STOPS);
  const { hour, dow } = istHourAndDow(row.updatedAt);

  const segments: SegmentEtaFeatures[] = upcoming.map((seg: RouteSegmentInfo, i: number) => {
    const isCurrent = i === 0;
    const stopId = String(seg.toStopId ?? `${row.directionId}:${seg.sequence}`);
    const baselineSpeedMps = seg.avgSpeedMps ?? FALLBACK_SPEED_MPS;

    // segment_travel_stats (db/migrations/0003_derived_stats.sql) if a real bucket
    // exists for this (direction, segment, hour); otherwise the OSRM free-flow
    // baseline — a real, route-specific number, but not a rolling historical
    // average (see this module's docstring).
    const stat30d = getSegmentStat(row.directionId, seg.sequence, hour, dow, '30d');
    const stat7d = getSegmentStat(row.directionId, seg.sequence, hour, dow, '7d');
    const speed30dMps = stat30d ? stat30d.avgSpeedKmh / 3.6 : baselineSpeedMps;
    const speed7dMps = stat7d ? stat7d.avgSpeedKmh / 3.6 : baselineSpeedMps;

    // A real per-stop/per-hour dwell stat wins when one exists; otherwise fall
    // back to THIS bus's live occupancy rather than a flat constant — see the
    // module-level note above dwellPriorSecFromOccupancy for why occupancy,
    // not footfall_prior, is the honest crowd signal available today.
    const dwellStat = getDwellStat(stopId, hour, dow);
    const dwellPriorSec = dwellStat ? dwellStat.p50DwellSec : dwellPriorSecFromOccupancy(row.occupancy);

    const distanceToStopM = isCurrent
      ? Math.max(seg.toDistAlongRouteM - row.distAlongRouteM, 0)
      : seg.lengthM;
    const liveTrafficFactor = isCurrent && row.speedMps > 0
      ? clamp(row.speedMps / baselineSpeedMps, LIVE_TRAFFIC_FACTOR_CLAMP)
      : 1.0; // no observation yet for a segment the bus hasn't entered

    return {
      stop_id: stopId,
      segment_avg_speed_7d: speed7dMps,
      segment_avg_speed_30d: speed30dMps,
      time_of_day_bucket: hour,
      day_of_week: dow,
      distance_to_stop_m: distanceToStopM,
      current_delay_sec: 0, // no schedule to measure delay against — see module docstring
      weather_bucket: 0,
      upcoming_stop_dwell_prior_sec: dwellPriorSec,
      live_traffic_factor: liveTrafficFactor,
    };
  });

  return { query: { bus_id: row.busId, route_id: row.routeId, segments }, upcoming };
}

/** Latest scored ETAs per bus, so consumer.ts's per-ping handler can attach a
 * best-effort (possibly up to one tick stale) upcomingStops to every position
 * update between batch ticks, instead of shipping position with no ETA at all. */
export const latestEtaCache = new Map<string, { stopId: string; stopName: string | null; etaSeconds: number }[]>();

const LOOKUP_LOG_INTERVAL_TICKS = 60; // ~once/minute at the default 1s tick
let tickCount = 0;

export function startEtaScoringLoop(redis: Redis, producer: Producer): NodeJS.Timeout {
  return setInterval(async () => {
    try {
      tickCount++;
      if (tickCount % LOOKUP_LOG_INTERVAL_TICKS === 0) {
        // Observability for the segment_travel_stats/stop_dwell_stats fallback rate —
        // same honesty principle as ml-service's dataset.py fallback_counts. A
        // consistently high miss rate means the stats tables need a re-run of
        // refresh_stats.py (stale/missing), not that anything here is broken.
        console.log(`[etaScoringLoop] stats lookup rates since start: ${JSON.stringify(lookupCounts)}`);
      }

      const liveBuses = await loadLiveBuses(redis);
      if (liveBuses.length === 0) return;

      const byBusId = new Map(liveBuses.map((r) => [r.busId, r]));
      const built = liveBuses.map(buildQuery).filter((b): b is BuiltQuery => b !== null);
      if (built.length === 0) return;

      const queries = built.map((b) => b.query);
      const upcomingByBusId = new Map(built.map((b) => [b.query.bus_id, b.upcoming]));
      const results = await predictEtaBatch(queries);

      const messages = [];
      for (const [busId, stops] of results) {
        const row = byBusId.get(busId);
        if (!row) continue;

        // Matched by position against the SAME segment list buildQuery scored,
        // not re-derived from stop_id — see buildQuery's docstring for why that
        // re-derivation silently loses the name whenever a segment's real
        // toStopId was null and a synthetic id had to stand in for it.
        const upcoming = upcomingByBusId.get(busId) ?? [];
        const query = queries.find((q) => q.bus_id === busId);
        const upcomingStops = stops.map((s, i) => ({
          stopId: s.stop_id,
          stopName: upcoming[i]?.toStopName ?? null,
          etaSeconds: s.eta_seconds,
        }));
        latestEtaCache.set(busId, upcomingStops);

        messages.push({
          key: busId,
          value: JSON.stringify({
            busId,
            routeId: row.routeId,
            directionId: row.directionId,
            lat: row.lat,
            lon: row.lon,
            occupancy: row.occupancy,
            etaSeconds: upcomingStops[0]?.etaSeconds,
            upcomingStops,
            nextStopId: upcomingStops[0]?.stopId ?? null,
            nextStopName: upcomingStops[0]?.stopName ?? null,
            distanceToNextStopM: query?.segments[0]?.distance_to_stop_m ?? 0,
            confidenceTier: 'live',
            badge: 'live',
            // The REAL last-ping time, not this tick's `now` — preserves the
            // degradation ladder's honesty invariant (docs §7.4): a bus scored
            // here but not pinged in a while must still age out into 'estimated'
            // on the frontend/watchdog, not look artificially fresh.
            updatedAt: row.updatedAt,
          }),
        });
      }

      if (messages.length > 0) {
        await producer.send({ topic: BUS_STATE_TOPIC, messages });
      }
    } catch (err) {
      // One tick's worth of stale ETAs is fine — positions keep flowing via
      // handlePing regardless, and this self-heals next tick.
      console.error('[etaScoringLoop] batch scoring tick failed', err);
    }
  }, config.etaBatchIntervalMs);
}
