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
 * Trip lifecycle: api-gateway's trips.service.ts now mints the real trips.id and
 * publishes it on `bus/{busId}/status` (QoS 1, retained — see its mqtt.service.ts)
 * on `POST /api/trips` / `PATCH /api/trips/:id/end`. `handleTripStatus` below,
 * wired from consumer.ts's `bus/+/status` subscription, adopts that real tripId
 * into `tripStateByBusId` on `trip_start` and retires it on `trip_end` — closing
 * the gap this comment used to describe. The retained flag means a
 * stream-processor that restarts mid-trip re-receives the last status per bus and
 * re-adopts the running trip rather than starting cold.
 *
 * `ensureTrip`'s lazy create-on-first-ping path stays as the fallback for buses
 * whose trip_start message never arrived or was lost (broker down at start time,
 * a real VLTD bus with no app-side trip lifecycle at all) — inferred trips are
 * still never marked 'completed' at their real end, same as before, because there
 * is by definition no end signal for one. That gap is now the exception rather
 * than the default.
 *
 * Stop-event detection is inferred from map-matching, not a real arrival sensor:
 * mapMatch.ts's `nextStopId` is the stop the bus hasn't reached yet. When it
 * changes from A to B, the bus has passed A sometime between the previous ping
 * and this one, so `arrived_at` is recorded as this ping's timestamp (a
 * best-available confirmation instant, not the true arrival moment — that's
 * somewhere in the gap since the previous ping). `departed_at`/`dwell_sec` are
 * left NULL rather than fabricated: map-matching gives exactly one coarse
 * "passed" signal per stop, not separate arrival/departure instants, so real
 * dwell isn't observable this way — it would need a speed-based
 * approaching/stationary/departed state machine, which isn't built. (An earlier
 * version reused the confirmation instant as both "departed the previous stop"
 * and "arrived this stop" — every derived segment duration came out to exactly
 * zero as a result, caught via train/refresh_stats.py --source live against
 * real data.) `boarding_count`/`alighting_count` come from the occupancy delta
 * between consecutive confirmations (a real signal — the ping payload's own
 * `occupancy` field — but a net delta, not an actual boarding+alighting tally).
 *
 * The FINAL stop's stop_event — previously an unclosed gap, because
 * `nextStopId` simply stops changing once the bus reaches the last stop
 * (routeStore.nextStopFrom's own fallback), so `maybeRecordStopEvent`'s
 * change-detection never fires for it. Now that a real trip_end signal exists,
 * `handleTripStatus` records it directly: whatever stop `lastNextStopOsmNodeId`
 * was pointing at when the trip ended (the last stop the state machine was
 * still "approaching") is recorded as reached, at the trip_end message's
 * timestamp. `boarding_count`/`alighting_count` are left NULL rather than
 * guessed — trip_end carries no occupancy figure to diff against, and the same
 * no-fabrication rule applies here as everywhere else in this module. A trip
 * that ends via the `ensureTrip` fallback path (inferred, no real trip_end)
 * still doesn't get this — there's no signal to record it against, same as
 * before.
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
  // sometime between the previous ping and this one. `ping.timestamp` is the
  // confirmation instant, not the true arrival instant (map-matching only gives
  // one coarse "passed" signal per stop, not separate arrival/departure events —
  // see this module's docstring). departed_at/dwell_sec are honestly NULL, not
  // fabricated: an earlier version reused this same confirmation instant as both
  // "departed previous stop" and "arrived this stop", which made every computed
  // segment duration exactly zero (caught via train/refresh_stats.py --source
  // live returning zero traversals against real data — every stop_event's
  // departed_at was byte-identical to the next one's arrived_at by construction).
  // Real dwell requires watching speed for a near-stop stationary period, which
  // isn't built — see docs §7.3's "Real-time persistence" section.
  const reachedStopOsmNodeId = state.lastNextStopOsmNodeId;
  const pgStopId = stopIdByOsmNodeId.get(reachedStopOsmNodeId);
  const direction = getDirection(state.directionId);
  const sequence = direction?.stops.find((s) => s.osmNodeId === reachedStopOsmNodeId)?.sequence ?? null;

  if (pgStopId !== undefined && sequence !== null) {
    const boarding = Math.max(Math.round(ping.occupancy - state.lastOccupancy), 0);
    const alighting = Math.max(Math.round(state.lastOccupancy - ping.occupancy), 0);

    await getPgPool().query(
      `INSERT INTO stop_events (trip_id, stop_id, sequence, arrived_at, departed_at, dwell_sec, boarding_count, alighting_count)
       VALUES ($1, $2, $3, to_timestamp($4 / 1000.0), NULL, NULL, $5, $6)`,
      [state.pgTripId, pgStopId, sequence, ping.timestamp, boarding, alighting],
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

/** Mirrors api-gateway's mqtt.service.ts `TripStatusMessage` — the two services
 * are separate deployables connected only by this wire contract, same as
 * `RawGpsPing`/`MapMatchedPosition` above have no shared-package type either. */
export interface TripStatusMessage {
  event: 'trip_start' | 'trip_end';
  tripId: number;
  busId: string;
  routeId: string | null;
  directionId: string;
  timestamp: number;
}

/** Records the trip's real final stop_event — see this module's docstring.
 * `lastNextStopOsmNodeId` is whatever stop the state machine was still
 * "approaching" when the trip ended; for a trip that reached the end of its
 * route that's the real final stop, since nextStopId stops advancing there. */
async function recordFinalStopEvent(state: TripState, endedAtMs: number): Promise<void> {
  const reachedStopOsmNodeId = state.lastNextStopOsmNodeId;
  if (reachedStopOsmNodeId === null) return; // no ping ever established an upcoming stop for this trip

  const pgStopId = stopIdByOsmNodeId.get(reachedStopOsmNodeId);
  const direction = getDirection(state.directionId);
  const sequence = direction?.stops.find((s) => s.osmNodeId === reachedStopOsmNodeId)?.sequence ?? null;
  if (pgStopId === undefined || sequence === null) return;

  await getPgPool().query(
    `INSERT INTO stop_events (trip_id, stop_id, sequence, arrived_at, departed_at, dwell_sec, boarding_count, alighting_count)
     VALUES ($1, $2, $3, to_timestamp($4 / 1000.0), NULL, NULL, NULL, NULL)`,
    [state.pgTripId, pgStopId, sequence, endedAtMs],
  );
}

/**
 * Handles a real `bus/{busId}/status` message (docs §7.2/§7.3), wired from
 * consumer.ts's `bus/+/status` subscription. `trip_start` adopts the gateway's
 * real `trips.id` into `tripStateByBusId` so every subsequent `gps_pings`/
 * `stop_events` row for this bus attaches to the trip the driver actually
 * started, not an inferred one. `trip_end` retires that cache entry and records
 * the real final stop_event — api-gateway has already closed the `trips` row
 * itself (trips.service.ts's `end()`), so this never touches `trips` directly.
 */
export async function handleTripStatus(message: TripStatusMessage): Promise<void> {
  if (cityId === null) return; // startPgPersist() never resolved a city — same guard as persistPingAsync

  if (message.event === 'trip_end') {
    const existing = tripStateByBusId.get(message.busId);
    if (existing?.pgTripId !== message.tripId) return; // stale/duplicate/unknown — nothing cached to retire
    await recordFinalStopEvent(existing, message.timestamp).catch((err) =>
      console.error('[pgPersist] failed to record final stop_event', err),
    );
    tripStateByBusId.delete(message.busId);
    console.log(`[pgPersist] trip ${message.tripId} for bus ${message.busId} ended (real signal)`);
    return;
  }

  // trip_start
  const osmRelationId = parseOsmRelationId(message.directionId);
  const pgRouteId = osmRelationId !== null ? routeIdByOsmRelationId.get(osmRelationId) : undefined;
  if (pgRouteId === undefined) {
    console.warn(
      `[pgPersist] trip_start for bus ${message.busId}: direction ${message.directionId} not found in Postgres routes — ignoring, falling back to per-ping inference`,
    );
    return;
  }

  const existing = tripStateByBusId.get(message.busId);
  if (existing && existing.pgTripId !== message.tripId) {
    // A previous (real or inferred) trip was still cached for this bus. api-gateway's
    // own start() already closes any 'running' trip for this bus before minting a new
    // one, but an *inferred* trip (created by ensureTrip's fallback, never signaled to
    // the gateway) wouldn't have gone through that path — close it here so it doesn't
    // stay 'running' forever alongside the new real one.
    try {
      await getPgPool().query(`UPDATE trips SET ended_at = now(), status = 'completed' WHERE id = $1 AND status = 'running'`, [
        existing.pgTripId,
      ]);
    } catch (err) {
      console.error('[pgPersist] failed to close superseded trip', err);
    }
  }

  const pgBusId = existing?.pgBusId ?? (await upsertBus(message.busId));
  tripStateByBusId.set(message.busId, {
    pgBusId,
    pgTripId: message.tripId,
    pgRouteId,
    directionId: message.directionId,
    lastNextStopOsmNodeId: null,
    lastStopChangeAtMs: message.timestamp,
    lastOccupancy: 0,
  });
  console.log(`[pgPersist] adopted real trip ${message.tripId} for bus ${message.busId} (${message.directionId})`);
}
