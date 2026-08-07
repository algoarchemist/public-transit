import { BadRequestException, Controller, Get, Query } from '@nestjs/common';
import { SnapshotService, type AllStop, type NearbyStop } from '../snapshot/snapshot.service';

/** `GET /api/stops/nearby?lat&lon&radius_m` (docs §8) — what the passenger app's
 * "stops near me" list is built on, and the entry point to per-stop ETAs. */
@Controller('stops')
export class StopsController {
  constructor(private readonly snapshot: SnapshotService) {}

  /** Every real stop, name-sorted — backs the passenger app's origin/destination
   * search (route_search_screen.dart's stop picker), which searches by typed
   * name rather than by the phone's current location. */
  @Get()
  all(): { stops: AllStop[] } {
    return { stops: this.snapshot.listAllStops() };
  }

  @Get('nearby')
  nearby(
    @Query('lat') lat: string,
    @Query('lon') lon: string,
    @Query('radius_m') radiusM?: string,
    @Query('limit') limit?: string,
  ): { stops: NearbyStop[] } {
    const latitude = Number(lat);
    const longitude = Number(lon);
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) {
      throw new BadRequestException('lat and lon are required and must be numbers');
    }

    // 1500 m default: far enough to catch a stop on the next arterial road, close
    // enough that everything returned is genuinely walkable.
    const radius = Number(radiusM ?? 1500);
    if (!Number.isFinite(radius) || radius <= 0 || radius > 20000) {
      throw new BadRequestException('radius_m must be a positive number no greater than 20000');
    }

    const max = Number(limit ?? 25);
    return { stops: this.snapshot.stopsNear(latitude, longitude, radius).slice(0, Number.isFinite(max) ? max : 25) };
  }
}
