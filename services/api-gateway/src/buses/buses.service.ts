import { Injectable } from '@nestjs/common';

// TODO: read live position/occupancy from Redis (populated by stream-processor);
// this REST path is the polling fallback, live clients should prefer the WebSocket gateway.
@Injectable()
export class BusesService {
  findAll() {
    return [];
  }

  findOne(id: string) {
    return { id, position: null, occupancy: null, lastPingAt: null };
  }

  eta(id: string) {
    return { busId: id, upcomingStops: [] };
  }
}
