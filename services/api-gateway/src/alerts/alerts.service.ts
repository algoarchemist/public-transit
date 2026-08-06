import { Injectable, Logger } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';
import { CreateAlertDto } from './dto/create-alert.dto';

/**
 * Driver-raised incidents (docs §8's `/api/alerts/*`), written to the real `alerts`
 * table. `db/migrations/0004_driver_alert_types.sql` widened the type constraint to
 * cover what a driver actually reports from the road — traffic, diversions,
 * accidents — alongside the SOS/breakdown pair that was already scoped.
 *
 * Recording an alert must be about as reliable as anything in this system gets: a
 * driver hitting SOS is the one interaction where losing the write is genuinely
 * bad. So the bus/trip lookups are best-effort (a missing `buses` row nulls the FK
 * rather than rejecting the alert) and the row goes in regardless. An alert with a
 * position and no bus id is still actionable; a rejected alert is not.
 */
@Injectable()
export class AlertsService {
  private readonly logger = new Logger(AlertsService.name);

  constructor(@InjectDataSource() private readonly db: DataSource) {}

  private static rows<T>(result: unknown): T[] {
    // TypeORM's pg driver returns `[rows, affected]` for UPDATE/DELETE and raw rows
    // otherwise — same normalisation as TripsService, same reason.
    if (Array.isArray(result) && result.length === 2 && Array.isArray(result[0]) && typeof result[1] === 'number') {
      return result[0] as T[];
    }
    return (result ?? []) as T[];
  }

  private async resolveBusPk(busId?: string): Promise<number | null> {
    if (!busId) return null;
    try {
      const rows = AlertsService.rows<{ id: number }>(
        await this.db.query('SELECT id FROM buses WHERE registration_no = $1', [busId]),
      );
      return rows[0]?.id ?? null;
    } catch (err) {
      this.logger.warn(`could not resolve bus '${busId}' for alert: ${err}`);
      return null;
    }
  }

  async create(dto: CreateAlertDto) {
    const busPk = await this.resolveBusPk(dto.busId);
    const hasPoint = dto.lat !== undefined && dto.lon !== undefined;

    const rows = AlertsService.rows<{ id: number; raised_at: Date }>(
      await this.db.query(
        `INSERT INTO alerts (type, trip_id, bus_id, geom, notes, source)
         VALUES ($1, $2, $3, ${hasPoint ? 'ST_SetSRID(ST_MakePoint($4, $5), 4326)' : 'NULL'}, $${hasPoint ? 6 : 4}, 'driver')
         RETURNING id, raised_at`,
        hasPoint
          ? [dto.type, dto.tripId ?? null, busPk, dto.lon, dto.lat, dto.notes ?? null]
          : [dto.type, dto.tripId ?? null, busPk, dto.notes ?? null],
      ),
    );

    this.logger.log(`alert '${dto.type}' raised by bus ${dto.busId ?? 'unknown'} (trip ${dto.tripId ?? '—'})`);

    return {
      alertId: rows[0].id,
      type: dto.type,
      busId: dto.busId ?? null,
      tripId: dto.tripId ?? null,
      raisedAt: rows[0].raised_at.toISOString(),
      resolvedAt: null,
    };
  }

  /** Open alerts, newest first — the admin "what is happening now" feed. */
  async listOpen(limit = 50) {
    const rows = AlertsService.rows<{
      id: number;
      type: string;
      notes: string | null;
      raised_at: Date;
      registration_no: string | null;
      trip_id: number | null;
    }>(
      await this.db.query(
        `SELECT a.id, a.type, a.notes, a.raised_at, a.trip_id, b.registration_no
           FROM alerts a
           LEFT JOIN buses b ON b.id = a.bus_id
          WHERE a.resolved_at IS NULL
          ORDER BY a.raised_at DESC
          LIMIT $1`,
        [limit],
      ),
    );

    return {
      alerts: rows.map((r) => ({
        alertId: r.id,
        type: r.type,
        busId: r.registration_no,
        tripId: r.trip_id,
        notes: r.notes,
        raisedAt: r.raised_at.toISOString(),
      })),
    };
  }

  async resolve(alertId: number) {
    const rows = AlertsService.rows<{ id: number; resolved_at: Date }>(
      await this.db.query(
        `UPDATE alerts SET resolved_at = now() WHERE id = $1 AND resolved_at IS NULL
         RETURNING id, resolved_at`,
        [alertId],
      ),
    );
    // Already-resolved is not an error — a double tap must not fail.
    return { alertId, resolvedAt: rows[0]?.resolved_at?.toISOString() ?? null };
  }
}
