/**
 * Persists real GPS pings and derived stop-arrival/dwell events to Postgres
 * (docs §3.2's gps_pings/stop_events) — the gap flagged in 0003_derived_stats.sql's
 * header comment and repeated in the last commit's docs: segment_travel_stats/
 * stop_dwell_stats are populated from the offline backfill corpus because nothing
 * writes real-time traffic here. This is that write path.
 *
 * Identity resolution: gps_pings/stop_events need Postgres integer FKs
 * (trip_id -> trips.id, bus_id -> buses.id, stop_id -> stops.id), but the live
 * pipeline only ever knows string ids (busId, direction_id, each stop's real
 * osm_node_id) — routeStore.ts never queries Postgres. This module is the one
 * place that bridges the two: routes/stops are resolved once at startup into
 * in-memory maps (city_id from cities.name = config.snapshotLabel, routes by
 * osm_relation_id — the same number direction_id is "r" + — see
 * services/geo-ingest/app/persist.py's _direction_id/_upsert_route); buses/trips
 * are upserted/created lazily on first sight of a busId, since nothing else in
 * this system provisions a fleet roster yet (api-gateway's buses/trips endpoints
 * are still stubs).
 *
 * Trip lifecycle is inferred, not signaled: there is no MQTT "trip start/end"
 * message today (docs §7.2's `bus/{busId}/status` topic is unpublished/
 * unsubscribed) — a trip is created the first time a busId is seen, and closed
 * only if that busId's directionId later changes (defensive; the simulator's
 * live mode runs exactly one trip per bus per process, so this doesn't fire in
 * practice today). A trip is never marked 'completed' at its real end for the
 * same reason — this is a known, honest gap, not silently pretended away.
 *
 * Stop-event detection is inferred from map-matching, not a real arrival sensor:
 * mapMatch.ts's `nextStopId` is the stop the bus hasn't reached yet. When it
 * changes from A to B, the bus has passed A sometime between the previous ping
 * and this one — `arrived_at` uses the previous ping's timestamp (a lower-bound
 * proxy; the real arrival instant is unknowable at ping granularity) and
 * `departed_at` uses this ping's timestamp, so `dwell_sec` is the ping interval
 * that straddled the crossing — correctly spans a real dwell too, since
 * `nextStopId` stays constant across every ping taken while parked (see
 * simulator's PARKED_TICK_INTERVAL_SEC). `boarding_count`/`alighting_count` come
 * from the occupancy delta between those same two pings (a real signal — the
 * ping payload's own `occupancy` field — not fabricated, but an approximation:
 * it's a net delta, not an actual boarding+alighting tally).
 *
 * One real, unclosed limitation: a route's FINAL stop never gets a stop_event
 * here. `nextStopId` simply stops changing once the bus reaches the last stop
 * (routeStore.nextStopFrom's own fallback), so the transition this module
 * watches for never fires for it. Closing that needs a real trip-end signal
 * this system doesn't have yet — flagged, not silently worked around.
 */
import { getPgPool } from './pgPool';
import { config } from './config';
import { getDirection } from './routeStore';
import type { RawGpsPing, MapMatchedPosition } from './mapMatch';

interface TripState {
  pgBusId: number;
  pgTripId: number;
  pgRouteId: number;
  directionId: string;
  lastNextStopOsmNodeId: number | null;
  lastStopChangeAtMs: number;
  lastOccupancy: number;
}

let cityId: number | null = null;
let routeIdByOsmRelationId = new Map<number, number>();
let stopIdByOsmNodeId = new Map<number, number>();
const tripStateByBusId = new Map<string, TripState>();
const warnedMissingRoute = new Set<string>();

function parseOsmRelationId(directionId: string): number | null {
  const match = /^r(\d+)$/.exec(directionId);
  return match ? Number(match[1]) : null;
}

/** Loads city_id and the route/stop id-resolution maps once. Routes/stops are
 * effectively static for the lifetime of a running demo (geo-ingest is a
 * separate manual step) — unlike statsStore.ts's derived stats, there's no
 * periodic reload here; re-run geo-ingest then restart this process if that
 * ever needs to change. */
export async function startPgPersist(): Promise<void> {
  const pool = getPgPool();
  try {
    const cityRes = await pool.query('SELECT id FROM cities WHERE name = $1', [config.snapshotLabel]);
    if (cityRes.rows.length === 0) {
      console.error(
        `[pgPersist] no cities row for '${config.snapshotLabel}' — has geo-ingest been run against this DB? Persistence disabled.`,
      );
      return;
    }
    cityId = cityRes.rows[0].id;

    const routesRes = await pool.query(
      'SELECT id, osm_relation_id FROM routes WHERE city_id = $1 AND osm_relation_id IS NOT NULL',
      [cityId],
    );
    routeIdByOsmRelationId = new Map(routesRes.rows.map((r) => [Number(r.osm_relation_id), Number(r.id)]));

    const stopsRes = await pool.query('SELECT id, osm_node_id FROM stops WHERE city_id = $1', [cityId]);
    stopIdByOsmNodeId = new Map(stopsRes.rows.map((r) => [Number(r.osm_node_id), Number(r.id)]));

    console.log(
      `[pgPersist] resolved city_id=${cityId}, ${routeIdByOsmRelationId.size} routes, ${stopIdByOsmNodeId.size} stops`,
    );
  } catch (err) {
    console.error('[pgPersist] startup failed — gps_pings/stop_events will not be persisted', err);
  }
}

async function upsertBus(registrationNo: string): Promise<number> {
  const pool = getPgPool();
  const res = await pool.query(
    `INSERT INTO buses (registration_no, has_vltd) VALUES ($1, false)
     ON CONFLICT (registration_no) DO UPDATE SET registration_no = EXCLUDED.registration_no
     RETURNING id`,
    [registrationNo],
  );
  return res.rows[0].id;
}

async function ensureTrip(ping: RawGpsPing): Promise<TripState | null> {
  const existing = tripStateByBusId.get(ping.busId);
  if (existing && existing.directionId === ping.directionId) return existing;

  const osmRelationId = parseOsmRelationId(ping.directionId);
  const pgRouteId = osmRelationId !== null ? routeIdByOsmRelationId.get(osmRelationId) : undefined;
  if (pgRouteId === undefined) {
    if (!warnedMissingRoute.has(ping.directionId)) {
      warnedMissingRoute.add(ping.directionId);
      console.warn(`[pgPersist] direction ${ping.directionId} not found in Postgres routes — skipping persistence for it`);
    }
    return null;
  }

  const pool = getPgPool();

  if (existing) {
    // Defensive: the simulator's live mode never actually changes a bus's
    // direction mid-process, but a real driver app could start a new trip.
    await pool.query(`UPDATE trips SET ended_at = now(), status = 'completed' WHERE id = $1`, [existing.pgTripId]);
  }

  const pgBusId = existing?.pgBusId ?? (await upsertBus(ping.busId));
  const tripRes = await pool.query(
    `INSERT INTO trips (route_id, bus_id, started_at, status) VALUES ($1, $2, to_timestamp($3 / 1000.0), 'running') RETURNING id`,
    [pgRouteId, pgBusId, ping.timestamp],
  );

  const state: TripState = {
    pgBusId,
    pgTripId: tripRes.rows[0].id,
    pgRouteId,
    directionId: ping.directionId,
    lastNextStopOsmNodeId: null,
    lastStopChangeAtMs: ping.timestamp,
    lastOccupancy: ping.occupancy,
  };
  tripStateByBusId.set(ping.busId, state);
  return state;
}

async function insertGpsPing(state: TripState, ping: RawGpsPing): Promise<void> {
  await getPgPool().query(
    `INSERT INTO gps_pings (time, trip_id, bus_id, geom, speed_kmh, source)
     VALUES (to_timestamp($1 / 1000.0), $2, $3, ST_SetSRID(ST_MakePoint($4, $5), 4326), $6, 'sim')`,
    [ping.timestamp, state.pgTripId, state.pgBusId, ping.lon, ping.lat, ping.speedKmh],
  );
  // heading/accuracy_m stay NULL — not part of today's wire format (docs §7.1's
  // not-yet-built protobuf schema is the natural place to add them). `source` is
  // hardcoded 'sim' since every real caller today is the simulator; once the
  // driver app or real VLTD hardware publish, the wire format needs its own
  // source tag threaded through rather than assuming one constant value.
}

async function maybeRecordStopEvent(
  state: TripState,
  ping: RawGpsPing,
  matched: MapMatchedPosition,
): Promise<void> {
  const newNextStopOsmNodeId = matched.nextStopId;

  if (state.lastNextStopOsmNodeId === null) {
    // First ping of this trip — nothing to compare against yet, just baseline.
    state.lastNextStopOsmNodeId = newNextStopOsmNodeId;
    state.lastStopChangeAtMs = ping.timestamp;
    state.lastOccupancy = ping.occupancy;
    return;
  }

  if (newNextStopOsmNodeId === null || newNextStopOsmNodeId === state.lastNextStopOsmNodeId) {
    return; // still approaching (or dwelling at) the same upcoming stop
  }

  // nextStopId changed -> the bus has passed/reached state.lastNextStopOsmNodeId
  // sometime between the previous ping and this one.
  const reachedStopOsmNodeId = state.lastNextStopOsmNodeId;
  const pgStopId = stopIdByOsmNodeId.get(reachedStopOsmNodeId);
  const direction = getDirection(state.directionId);
  const sequence = direction?.stops.find((s) => s.osmNodeId === reachedStopOsmNodeId)?.sequence ?? null;

  if (pgStopId !== undefined && sequence !== null) {
    // dwell_sec is `integer` in the schema (0001_init.sql) — round, don't truncate,
    // so a sub-second span still records as 1s rather than silently 0.
    const dwellSec = Math.max(1, Math.round((ping.timestamp - state.lastStopChangeAtMs) / 1000));
    const boarding = Math.max(Math.round(ping.occupancy - state.lastOccupancy), 0);
    const alighting = Math.max(Math.round(state.lastOccupancy - ping.occupancy), 0);

    await getPgPool().query(
      `INSERT INTO stop_events (trip_id, stop_id, sequence, arrived_at, departed_at, dwell_sec, boarding_count, alighting_count)
       VALUES ($1, $2, $3, to_timestamp($4 / 1000.0), to_timestamp($5 / 1000.0), $6, $7, $8)`,
      [state.pgTripId, pgStopId, sequence, state.lastStopChangeAtMs, ping.timestamp, dwellSec, boarding, alighting],
    );
  }

  state.lastNextStopOsmNodeId = newNextStopOsmNodeId;
  state.lastStopChangeAtMs = ping.timestamp;
  state.lastOccupancy = ping.occupancy;
}

/** Best-effort, fire-and-forget from consumer.ts's handlePing — a slow or down
 * Postgres must never add latency to (or break) the live Redis/Kafka path that
 * actually drives the map. Errors are logged, not thrown. */
export function persistPingAsync(ping: RawGpsPing, matched: MapMatchedPosition): void {
  if (cityId === null) return; // startPgPersist() never resolved a city — nothing to persist against

  ensureTrip(ping)
    .then(async (state) => {
      if (!state) return;
      await insertGpsPing(state, ping);
      await maybeRecordStopEvent(state, ping, matched);
    })
    .catch((err) => console.error('[pgPersist] failed to persist ping', err));
}
