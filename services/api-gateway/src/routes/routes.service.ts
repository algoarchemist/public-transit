import { Injectable } from '@nestjs/common';

// TODO: back with PostGIS-backed Route/Stop entities (geometry columns,
// ST_LineLocatePoint for map-matching) instead of in-memory stubs.
@Injectable()
export class RoutesService {
  findAll() {
    return [];
  }

  findOne(id: string) {
    return { id, name: null, stops: [] };
  }

  stops(id: string) {
    return { routeId: id, stops: [] };
  }

  performance(id: string) {
    return { routeId: id, onTimePercent: null, avgDelaySec: null, problemSegments: [] };
  }
}
