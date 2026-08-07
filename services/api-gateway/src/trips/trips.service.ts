import { ConflictException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';
import { SnapshotService } from '../snapshot/snapshot.service';
import { MqttService } from '../mqtt/mqtt.service';
import { StartTripDto } from './dto/start-trip.dto';
import { EndTripDto } from './dto/end-trip.dto';
import { TallyDto } from './dto/tally.dto';

/**
 * The driver-side trip lifecycle (docs §8: `POST /api/trips`,
 * `PATCH /api/trips/:id/end`, `POST /api/trips/:id/tally`), backed by the real
 * `trips` / `buses` / `occupancy_snapshots` tables from db/migrations/0001_init.sql.
 *
 * Raw SQL rather than TypeORM entities: db/migrations owns the schema (docs §2 —
 * `synchronize: true` cannot express PostGIS geometry columns or GiST indexes, so
 * it is off). Entities would be a second, drift-prone copy of a schema that lives
 * in versioned SQL a few directories away, and these three endpoints do not need
 * an ORM's identity map. The DataSource is still TypeORM's, so there is exactly
 * one connection pool in the process.
 *
 * Identity bridging, the same problem stream-processor/src/pgPersist.ts solves for
 * the live path: everything user-facing speaks strings (`busId` = registration
 * number, `directionId` = "r" + OSM relation id), while `trips` needs integer FKs.
 * Routes resolve via `routes.osm_relation_id`; buses are upserted by
 * `registration_no` on first sight, because nothing in this system provisions a
 * fleet roster yet.
 */

interface TripRow {
  id: number;
  route_id: number;
  bus_id: number;
  driver_id: string | null;
  scheduled_start: Date | null;
  started_at: Date | null;
  ended_at: Date | null;
  status: string;
}

export interface TripResponse {
  tripId: number;
  busId: string;
  directionId: string;
  routeId: string | null;
  routeName: string | null;
  driverId: string | null;
  status: string;
  scheduledStart: string | null;
  startedAt: string | null;
  endedAt: string | null;
  stopCount: number;
}

@Injectable()
export class TripsService {
  private readonly logger = new Logger(TripsService.name);

  constructor(
    @InjectDataSource() private readonly db: DataSource,
    private readonly snapshot: SnapshotService,
    private readonly mqtt: MqttService,
  ) {}

  private get cityName(): string {
    return process.env.SNAPSHOT_LABEL ?? 'mohali-tricity';
  }

  /**
   * TypeORM's Postgres driver returns raw rows for SELECT/INSERT but `[rows, affected]`
   * for UPDATE/DELETE — including when they carry a RETURNING clause. Indexing `[0]`
   * on the latter silently yields the row *array*, so every field reads back
   * `undefined` and the response looks structurally fine while being empty. (That is
   * exactly what `PATCH /trips/:id/end` did on first test: 200 with no tripId, no
   * status and null timestamps.) Normalising in one place beats remembering which
   * verb behaves which way at each call site.
   */
  private static rows<T>(result: unknown): T[] {
    if (Array.isArray(result) && result.length === 2 && Array.isArray(result[0]) && typeof result[1] === 'number') {
      return result[0] as T[];
    }
    return (result ?? []) as T[];
  }

  private static osmRelationId(directionId: string): number {
    // Validated by StartTripDto's regex; geo-ingest's persist.py mints direction_id
    // as "r" + the OSM relation id, which is what `routes.osm_relation_id` stores.
    return Number(directionId.slice(1));
  }

  private async resolveRoutePk(directionId: string): Promise<number> {
    const rows: { id: number }[] = await this.db.query(
      `SELECT r.id FROM routes r
         JOIN cities c ON c.id = r.city_id
        WHERE c.name = $1 AND r.osm_relation_id = $2`,
      [this.cityName, TripsService.osmRelationId(directionId)],
    );
    if (rows.length === 0) {
      throw new NotFoundException(
        `route direction '${directionId}' is not in the '${this.cityName}' database — has geo-ingest been run against it?`,
      );
    }
    return rows[0].id;
  }

  private async upsertBus(registrationNo: string): Promise<number> {
    const rows: { id: number }[] = await this.db.query(
      `INSERT INTO buses (registration_no, has_vltd) VALUES ($1, false)
       ON CONFLICT (registration_no) DO UPDATE SET registration_no = EXCLUDED.registration_no
       RETURNING id`,
      [registrationNo],
    );
    return rows[0].id;
  }

  private toResponse(row: TripRow, busId: string, directionId: string): TripResponse {
    const route = this.snapshot.getRoute(directionId);
    return {
      tripId: row.id,
      busId,
      directionId,
      routeId: route?.routeId ?? null,
      routeName: route?.name ?? null,
      driverId: row.driver_id,
      status: row.status,
      scheduledStart: row.scheduled_start?.toISOString() ?? null,
      startedAt: row.started_at?.toISOString() ?? null,
      endedAt: row.ended_at?.toISOString() ?? null,
      stopCount: route?.stopCount ?? 0,
    };
  }

  /**
   * Starts a trip. A bus can only run one trip at a time, so any trip left
   * `running` for this bus is closed as `abandoned` first — a driver whose phone
   * died mid-shift and restarted the app must not end up with two open trips
   * competing for the same ping stream.
   */
  async start(dto: StartTripDto): Promise<TripResponse> {
    if (!this.snapshot.getRoute(dto.directionId)) {
      throw new NotFoundException(`unknown route direction '${dto.directionId}' (see GET /api/routes)`);
    }

    const routePk = await this.resolveRoutePk(dto.directionId);
    const busPk = await this.upsertBus(dto.busId);

    const row = await this.db.transaction(async (manager) => {
      const abandoned = TripsService.rows<{ id: number }>(
        await manager.query(
          `UPDATE trips SET ended_at = now(), status = 'abandoned'
            WHERE bus_id = $1 AND status = 'running' RETURNING id`,
          [busPk],
        ),
      );
      if (abandoned.length > 0) {
        this.logger.warn(
          `bus ${dto.busId} had ${abandoned.length} trip(s) still running (${abandoned
            .map((t) => t.id)
            .join(', ')}) — marked abandoned before starting a new one`,
        );
      }

      const trip = TripsService.rows<TripRow>(
        await manager.query(
          // COALESCE($5, now()): a normal start has no client-supplied instant and
          // gets the server's real now(); the GPS-unavailable manual-entry flow
          // supplies its own (docs: driver recorded a start the server never saw
          // live) and that value wins instead.
          `INSERT INTO trips (route_id, bus_id, driver_id, scheduled_start, started_at, status)
           VALUES ($1, $2, $3, $4, COALESCE($5, now()), 'running')
           RETURNING id, route_id, bus_id, driver_id, scheduled_start, started_at, ended_at, status`,
          [
            routePk,
            busPk,
            dto.driverId ?? null,
            dto.scheduledStart ? new Date(dto.scheduledStart) : null,
            dto.startedAt ? new Date(dto.startedAt) : null,
          ],
        ),
      )[0];

      if (dto.initialOccupancy !== undefined) {
        await manager.query(
          `INSERT INTO occupancy_snapshots (time, trip_id, occupancy, source)
           VALUES (now(), $1, $2, 'conductor_tally')`,
          [trip.id, dto.initialOccupancy],
        );
      }
      return trip;
    });

    this.mqtt.publishTripStatus({
      event: 'trip_start',
      tripId: row.id,
      busId: dto.busId,
      routeId: this.snapshot.getRoute(dto.directionId)?.routeId ?? null,
      directionId: dto.directionId,
      timestamp: Date.now(),
    });

    return this.toResponse(row, dto.busId, dto.directionId);
  }

  private async loadTrip(tripId: number): Promise<{ row: TripRow; busId: string; directionId: string }> {
    const rows: (TripRow & { registration_no: string; osm_relation_id: string | null })[] = await this.db.query(
      `SELECT t.id, t.route_id, t.bus_id, t.driver_id, t.scheduled_start, t.started_at, t.ended_at, t.status,
              b.registration_no, r.osm_relation_id
         FROM trips t
         JOIN buses b ON b.id = t.bus_id
         JOIN routes r ON r.id = t.route_id
        WHERE t.id = $1`,
      [tripId],
    );
    if (rows.length === 0) throw new NotFoundException(`trip ${tripId} not found`);
    const row = rows[0];
    return { row, busId: row.registration_no, directionId: `r${row.osm_relation_id}` };
  }

  async findOne(tripId: number): Promise<TripResponse> {
    const { row, busId, directionId } = await this.loadTrip(tripId);
    return this.toResponse(row, busId, directionId);
  }

  /** Most recent trips first, optionally scoped to one bus (driver app's "view all
   * trips" screen, after ending a trip). `limit` is clamped rather than trusted —
   * this is a query param straight from the client. */
  async findAll(busId?: string, limit = 20): Promise<TripResponse[]> {
    const rows: (TripRow & { registration_no: string; osm_relation_id: string | null })[] = await this.db.query(
      `SELECT t.id, t.route_id, t.bus_id, t.driver_id, t.scheduled_start, t.started_at, t.ended_at, t.status,
              b.registration_no, r.osm_relation_id
         FROM trips t
         JOIN buses b ON b.id = t.bus_id
         JOIN routes r ON r.id = t.route_id
        WHERE $1::text IS NULL OR b.registration_no = $1
        ORDER BY t.started_at DESC NULLS LAST
        LIMIT $2`,
      [busId ?? null, Math.min(Math.max(limit, 1), 100)],
    );
    return rows.map((row) => this.toResponse(row, row.registration_no, `r${row.osm_relation_id}`));
  }

  /** Ends a trip. Idempotent for a trip that is already ended with the same status
   * — a driver tapping "End trip" on a flaky connection must not get an error for
   * a request that in fact succeeded. */
  async end(tripId: number, dto: EndTripDto): Promise<TripResponse> {
    const { row: existing, busId, directionId } = await this.loadTrip(tripId);
    const status = dto.status ?? 'completed';

    if (existing.status !== 'running') {
      if (existing.status === status) return this.toResponse(existing, busId, directionId);
      throw new ConflictException(`trip ${tripId} is already '${existing.status}', cannot mark '${status}'`);
    }

    const rows = TripsService.rows<TripRow>(
      await this.db.query(
        `UPDATE trips SET ended_at = now(), status = $2
          WHERE id = $1
         RETURNING id, route_id, bus_id, driver_id, started_at, ended_at, status`,
        [tripId, status],
      ),
    );

    this.mqtt.publishTripStatus({
      event: 'trip_end',
      tripId,
      busId,
      routeId: this.snapshot.getRoute(directionId)?.routeId ?? null,
      directionId,
      timestamp: Date.now(),
    });

    return this.toResponse(rows[0], busId, directionId);
  }

  /**
   * Records a conductor tally as a durable `occupancy_snapshots` row.
   *
   * This is deliberately a *second* path for the same number: the driver app also
   * folds the current count into its next GPS ping, which is what drives the live
   * passenger occupancy badge through Redis. That path is lossy by design (QoS 0,
   * divergence-triggered, so a tally can wait up to the 60s heartbeat) and keeps no
   * history. This one is the durable record the crowd model trains against.
   */
  async tally(tripId: number, dto: TallyDto): Promise<{ tripId: number; occupancy: number; recordedAt: string }> {
    const { row } = await this.loadTrip(tripId);
    if (row.status !== 'running') {
      throw new ConflictException(`trip ${tripId} is '${row.status}' — cannot tally against a trip that is not running`);
    }

    const rows: { time: Date }[] = await this.db.query(
      `INSERT INTO occupancy_snapshots (time, trip_id, occupancy, source)
       VALUES (now(), $1, $2, $3) RETURNING time`,
      [tripId, dto.occupancy, dto.source ?? 'conductor_tally'],
    );

    return { tripId, occupancy: dto.occupancy, recordedAt: rows[0].time.toISOString() };
  }
}
