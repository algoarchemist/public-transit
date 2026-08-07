import { Injectable } from '@nestjs/common';
import { SnapshotService, type RouteSummary, type StopSummary } from '../snapshot/snapshot.service';
import { BusesService } from '../buses/buses.service';

export interface BusMatch {
  directionId: string;
  routeId: string | null;
  ref: string | null;
  routeName: string | null;
}

export interface StopMatch {
  osmNodeId: number;
  name: string;
  lat: number;
  lon: number;
  sequence: number;
}

export interface SearchResult {
  matched: boolean;
  reason?: 'bus_not_found' | 'location_not_found';
  bus?: BusMatch;
  stop?: StopMatch;
  /** From BusesService.eta() — currently always [] until that reads live position
   * off Redis (see buses.service.ts). Wired here so the voice search flow doesn't
   * need a second round-trip once it isn't a stub anymore. */
  upcomingStops?: unknown[];
}

/**
 * Resolves free-text bus/route and stop names — as pulled out of a spoken
 * transcript by the mobile app's voice search (apps/mobile-app/lib/passenger/voice/),
 * or typed directly — against the snapshot data SnapshotService already loads.
 *
 * `bus` is matched against the route `ref`/`routeId` (e.g. "42", "2A"), which is
 * how routes are actually numbered in this system (see the "Bus 1: ...",
 * "Bus 2A: ..." names in the snapshot) — not a specific vehicle id. That's a
 * different identifier from BusesController's `:id` (a physical bus/vehicle),
 * which is why this lives in its own module rather than extending BusesService.
 */
@Injectable()
export class SearchService {
  constructor(
    private readonly snapshot: SnapshotService,
    private readonly buses: BusesService,
  ) {}

  search(busQuery: string, locationQuery: string): SearchResult {
    const routeMatches = this.matchRoutes(busQuery);
    if (routeMatches.length === 0) {
      return { matched: false, reason: 'bus_not_found' };
    }

    const stopMatch = this.matchStop(routeMatches, locationQuery);
    if (!stopMatch) {
      return { matched: false, reason: 'location_not_found', bus: toBusMatch(routeMatches[0]) };
    }

    const { route, stop } = stopMatch;
    const eta = this.buses.eta(route.routeId ?? route.directionId);

    return {
      matched: true,
      bus: toBusMatch(route),
      stop: { osmNodeId: stop.osmNodeId, name: stop.name!, lat: stop.lat, lon: stop.lon, sequence: stop.sequence },
      upcomingStops: eta.upcomingStops,
    };
  }

  /** Exact ref/routeId match wins outright (so "42" doesn't also drag in "142");
   * otherwise falls back to substring match on ref or name. */
  private matchRoutes(busQuery: string): RouteSummary[] {
    const q = busQuery.trim().toLowerCase();
    const all = this.snapshot.listRoutes();

    const exact = all.filter((r) => r.ref?.toLowerCase() === q || r.routeId?.toLowerCase() === q);
    if (exact.length > 0) return exact;

    return all.filter((r) => r.ref?.toLowerCase().includes(q) || r.name?.toLowerCase().includes(q));
  }

  /** Many snapshot stops have no name (unnamed OSM nodes) and are skipped. An
   * exact (case-insensitive) stop-name match returns immediately; otherwise the
   * first substring match found is used. */
  private matchStop(routes: RouteSummary[], locationQuery: string): { route: RouteSummary; stop: StopSummary } | null {
    const q = locationQuery.trim().toLowerCase();
    let best: { route: RouteSummary; stop: StopSummary } | null = null;

    for (const route of routes) {
      for (const stop of this.snapshot.stopsFor(route.directionId)) {
        if (!stop.name) continue;
        const name = stop.name.toLowerCase();
        if (name === q) return { route, stop };
        if (!best && name.includes(q)) best = { route, stop };
      }
    }

    return best;
  }
}

function toBusMatch(route: RouteSummary): BusMatch {
  return { directionId: route.directionId, routeId: route.routeId, ref: route.ref, routeName: route.name };
}
