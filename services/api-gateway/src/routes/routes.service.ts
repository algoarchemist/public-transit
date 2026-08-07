import { BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import {
  SnapshotService,
  type GeoJsonCollection,
  type GeoJsonFeature,
  type JourneyOption,
  type RouteSummary,
  type StopSummary,
} from '../snapshot/snapshot.service';

@Injectable()
export class RoutesService {
  constructor(private readonly snapshot: SnapshotService) {}

  /** Every real ingested route direction. This is what the driver app's route
   * selection screen lists — see apps/mobile-app/lib/driver/route_selection_screen.dart. */
  findAll(): RouteSummary[] {
    return this.snapshot.listRoutes();
  }

  /** `id` is a `direction_id` ("r" + OSM relation id) — the identifier the whole
   * live pipeline speaks, not a Postgres `routes.id`. See SnapshotService's docstring. */
  findOne(id: string): RouteSummary & { stops: StopSummary[] } {
    const route = this.snapshot.getRoute(id);
    if (!route) throw new NotFoundException(`unknown route direction '${id}'`);
    return { ...route, stops: this.snapshot.stopsFor(id) };
  }

  stops(id: string): { directionId: string; stops: StopSummary[] } {
    if (!this.snapshot.getRoute(id)) throw new NotFoundException(`unknown route direction '${id}'`);
    return { directionId: id, stops: this.snapshot.stopsFor(id) };
  }

  // TODO: real on-time/delay aggregates off segment_travel_stats + stop_events
  // (docs §3.3). Left a stub deliberately — the admin analytics pages it feeds are
  // still stubs themselves, and inventing numbers here would be worse than nothing.
  performance(id: string) {
    return { routeId: id, onTimePercent: null, avgDelaySec: null, problemSegments: [] };
  }

  /** GeoJSON FeatureCollection of every route direction's real polyline (one
   * LineString per direction) — for the admin dashboard's live fleet map overlay. */
  geometry(): GeoJsonCollection {
    return this.snapshot.geometry();
  }

  /** One direction's polyline, for the passenger app's single-route map. */
  routeGeometry(id: string): GeoJsonFeature {
    const feature = this.snapshot.routeGeometry(id);
    if (!feature) throw new NotFoundException(`unknown route direction '${id}'`);
    return feature;
  }

  /** The passenger app's "Find Routes" search (route_search_screen.dart) —
   * real direct (no-transfer) matches between two real stops, real distance,
   * and a real duration only where every covered segment has an OSRM baseline.
   * See SnapshotService.findJourneys for what's honest about this and what isn't
   * (no fare, no schedule/frequency — none of that data exists in this system). */
  journeys(fromStopId: string, toStopId: string): { journeys: JourneyOption[] } {
    const from = Number(fromStopId);
    const to = Number(toStopId);
    if (!Number.isFinite(from) || !Number.isFinite(to)) {
      throw new BadRequestException('from and to must be real stop osm_node_ids (see GET /api/stops)');
    }
    return { journeys: this.snapshot.findJourneys(from, to) };
  }
}
