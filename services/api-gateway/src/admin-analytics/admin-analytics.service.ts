import { Injectable, Logger } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';
import { BusesService } from '../buses/buses.service';

/**
 * Backs the admin dashboard's three analytics pages (docs §8:
 * `GET /api/admin/analytics/ridership | /demand-supply | /model-health`).
 *
 * Ridership and model-health read real data end to end: `stop_events` is filled
 * by stream-processor's real-time persistence (docs §7.3 — boarding/alighting
 * deltas from genuine map-matched arrivals), and model-health's ETA numbers are
 * the actual last training run's metrics (ml-service's artifacts/metrics.json).
 *
 * Demand-supply's "predicted demand" is a historical-average proxy — real
 * summed `boarding_count` per route divided by real trip count — not a live
 * call into the crowd model. `services/ml-service/app/routers/crowd.py` scores
 * one bus/stop at a time and there is no batch "predict demand for every route"
 * endpoint yet (that would need the same batching treatment `/eta/predict-batch`
 * got, docs §6.4). This proxy is still built entirely from real `stop_events`
 * and `trips` rows — nothing here is a random or invented number, but it is a
 * simpler statistic than "the trained crowd model's prediction," and the field
 * names say so rather than implying otherwise.
 */
@Injectable()
export class AdminAnalyticsService {
  private readonly logger = new Logger(AdminAnalyticsService.name);

  constructor(
    @InjectDataSource() private readonly db: DataSource,
    private readonly buses: BusesService,
  ) {}

  private get mlServiceUrl(): string {
    return process.env.ML_SERVICE_URL ?? 'http://localhost:8000';
  }

  async ridership() {
    const byHour: { hour: number; boardings: number; alightings: number; events: number }[] = await this.db.query(
      `SELECT extract(hour from arrived_at)::int AS hour,
              COALESCE(SUM(boarding_count), 0)::int AS boardings,
              COALESCE(SUM(alighting_count), 0)::int AS alightings,
              COUNT(*)::int AS events
         FROM stop_events
        WHERE arrived_at IS NOT NULL
        GROUP BY 1
        ORDER BY 1`,
    );

    const byDayType: { day_type: string; boardings: number; alightings: number }[] = await this.db.query(
      `SELECT CASE WHEN extract(dow from arrived_at) IN (0, 6) THEN 'weekend' ELSE 'weekday' END AS day_type,
              COALESCE(SUM(boarding_count), 0)::int AS boardings,
              COALESCE(SUM(alighting_count), 0)::int AS alightings
         FROM stop_events
        WHERE arrived_at IS NOT NULL
        GROUP BY 1`,
    );

    const [{ count: sampleStopEvents }]: { count: string }[] = await this.db.query(
      `SELECT COUNT(*) FROM stop_events WHERE arrived_at IS NOT NULL`,
    );

    return {
      byHour,
      byDayType: byDayType.map((r) => ({
        dayType: r.day_type,
        boardings: r.boardings,
        alightings: r.alightings,
      })),
      sampleStopEvents: Number(sampleStopEvents),
      source:
        'live stop_events (real boarding/alighting deltas from map-matched arrivals) accumulated since this stack came up — not the 90-day simulator backfill corpus',
    };
  }

  async demandSupply() {
    const totals: {
      route_pk: number;
      osm_relation_id: string | null;
      name: string | null;
      ref: string | null;
      total_boardings: number;
      trip_count: number;
    }[] = await this.db.query(
      `SELECT r.id AS route_pk, r.osm_relation_id, r.name, r.ref,
              COALESCE(SUM(se.boarding_count), 0)::int AS total_boardings,
              COUNT(DISTINCT t.id)::int AS trip_count
         FROM routes r
         JOIN trips t ON t.route_id = r.id
         LEFT JOIN stop_events se ON se.trip_id = t.id
        GROUP BY r.id, r.osm_relation_id, r.name, r.ref
        HAVING COUNT(DISTINCT t.id) > 0
        ORDER BY total_boardings DESC`,
    );

    const running: { route_id: number; running_trips: number }[] = await this.db.query(
      `SELECT route_id, COUNT(*)::int AS running_trips FROM trips WHERE status = 'running' GROUP BY route_id`,
    );
    const runningByRoute = new Map(running.map((r) => [r.route_id, r.running_trips]));

    const routes = totals.map((r) => {
      const avgBoardingsPerTrip = r.trip_count > 0 ? r.total_boardings / r.trip_count : 0;
      const runningTrips = runningByRoute.get(r.route_pk) ?? 0;
      const demandPerRunningBus = runningTrips > 0 ? avgBoardingsPerTrip / runningTrips : null;

      let status: 'under-supplied' | 'over-supplied' | 'balanced' | 'no-active-service';
      if (runningTrips === 0) {
        status = avgBoardingsPerTrip > 0 ? 'under-supplied' : 'no-active-service';
      } else if (demandPerRunningBus !== null && demandPerRunningBus < 1) {
        status = 'over-supplied';
      } else {
        status = 'balanced';
      }

      return {
        directionId: r.osm_relation_id ? `r${r.osm_relation_id}` : null,
        name: r.name ?? r.ref ?? (r.osm_relation_id ? `r${r.osm_relation_id}` : `route ${r.route_pk}`),
        avgBoardingsPerTrip: Math.round(avgBoardingsPerTrip * 10) / 10,
        tripCount: r.trip_count,
        runningTrips,
        status,
      };
    });

    return {
      routes,
      flagged: routes.filter((r) => r.status === 'under-supplied' || r.status === 'over-supplied'),
      source:
        'avg real boardings/trip (stop_events) vs. currently-running trips (trips.status) — a historical-average proxy for demand, not a live crowd-model batch score (see ml-service/app/routers/crowd.py)',
    };
  }

  async modelHealth() {
    let model: unknown = null;
    let modelError: string | null = null;
    try {
      const res = await fetch(`${this.mlServiceUrl}/health/metrics`, { signal: AbortSignal.timeout(3000) });
      if (res.ok) {
        model = await res.json();
      } else {
        modelError = `ml-service returned ${res.status}`;
      }
    } catch (err) {
      modelError = err instanceof Error ? err.message : 'ml-service unreachable';
      this.logger.warn(`could not reach ml-service for /health/metrics: ${modelError}`);
    }

    const buses = await this.buses.findAll();
    const tierCounts = { live: 0, estimated: 0, stale: 0, unknown: 0 };
    for (const b of buses) tierCounts[b.confidenceTier]++;

    return {
      model,
      modelError,
      fleet: {
        busesTracked: buses.length,
        tierCounts,
        buses: buses
          .slice()
          .sort((a, b) => (a.ageSec ?? Infinity) - (b.ageSec ?? Infinity))
          .map((b) => ({
            busId: b.busId,
            directionId: b.directionId,
            ageSec: b.ageSec,
            confidenceTier: b.confidenceTier,
            lastPingAt: b.lastPingAt,
          })),
      },
    };
  }
}
